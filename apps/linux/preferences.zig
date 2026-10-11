//! Settings: a page of eight tabs. General holds startup, notifications,
//! sorting and the keyboard summary; Library the folders, maintenance and
//! AcoustID; Playback volume leveling, transitions, the output and resume;
//! Sound the equalizer, per-device presets and crossfeed; Listening ListenBrainz, lyrics and artist
//! info and history; Appearance the window's look; Advanced the audio
//! engine, data sources, storage, logs and resets; About the version, the
//! system and the diagnostics Copy Diagnostics puts on the clipboard.
//! The tabs are built fresh each time the page is shown, from the engine's
//! current state, and destroyed when it is left. The search field filters
//! their rows by title and subtitle.

const std = @import("std");
const builtin = @import("builtin");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const settings = @import("settings.zig");
const secret = @import("secret.zig");
const transport = @import("transport.zig");
const matches = @import("matches.zig");
const watching = @import("watching.zig");
const maintenance = @import("maintenance.zig");
const submissions = @import("submissions.zig");
const lyrics = @import("lyrics.zig");
const page_ui = @import("page.zig");
const main_window = @import("window.zig");
const signal_path = @import("signal_path.zig");
const albums = @import("albums.zig");
const appearance = @import("appearance.zig");
const parametric = @import("parametric.zig");
const artists = @import("artists.zig");
const browse = @import("browse.zig");
const autostart = @import("autostart.zig");
const activity = @import("activity.zig");
const details = @import("details.zig");
const logging = @import("logging.zig");
const libraries = @import("libraries.zig");
const radio = @import("radio.zig");
const home_page = @import("home.zig");

const App = app.App;

const listenbrainz_token_service = liborca.listenbrainz_token_service;
const listenbrainz_token_account = liborca.listenbrainz_token_account;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const Card = struct {
    widget: *gtk.Widget,
    header: *gtk.Widget,
    body: *gtk.Widget,
    group: *gtk.Widget,
    title: *gtk.Widget,
    meta: *gtk.Widget,

    fn add(self: Card, row: *gtk.Widget) void {
        adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, self.group), row);
    }
};

fn card(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) Card {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(box, "settings-card");
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    const image = gtk.gtk_image_new_from_icon_name(icon);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), 22);
    gtk.gtk_widget_set_valign(image, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(image, "settings-card-icon");
    gtk.g_object_set_data(box, card_title_key, @constCast(title));
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    const heading = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(heading, "settings-card-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0);
    const meta = gtk.gtk_label_new(description);
    gtk.gtk_widget_add_css_class(meta, "meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, meta), gtk.true_);
    gtk.gtk_widget_set_visible(meta, @intFromBool(description[0] != 0));
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), meta);
    const body = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_set_hexpand(body, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), image);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), body);
    const rows = adw.adw_preferences_group_new();
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), rows);
    return .{ .widget = box, .header = header, .body = body, .group = rows, .title = heading, .meta = meta };
}

const card_title_key = "orca-settings-card-title";

fn flatCard(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) Card {
    const section = card(icon, title, description);
    gtk.gtk_widget_add_css_class(section.widget, "settings-flat");
    return section;
}

fn actionRow(title: [*:0]const u8, subtitle: [*:0]const u8) *gtk.Widget {
    const row = adw.adw_action_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title);
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), subtitle);
    return row;
}

fn suffixButton(row: *gtk.Widget, label: ?[*:0]const u8, icon: ?[*:0]const u8, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const button = if (label) |text| gtk.gtk_button_new_with_label(text) else gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(button, if (label == null) "flat" else "settings-action");
    _ = gtk.signalConnect(button, "clicked", handler, data);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), button);
    return button;
}

const PendingRemoval = struct {
    self: *App,
    root_id: i64,
};

fn rootPath(self: *App, root_id: i64, buffer: []u8) ?[:0]const u8 {
    const library = self.library orelse return null;
    var roots = self.runtime.libraryRootPage(library, app.page_size, 0) catch return null;
    defer roots.deinit();
    for (roots.items) |root| {
        if (root.id == root_id) return strings.printZ(buffer, "{s}", .{root.path}) catch null;
    }
    return null;
}

pub fn rescanFolder(self: *App, root_id: i64) void {
    jobs.rescanRoot(self, root_id);
}

fn folderOpened(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_file_launcher_launch_finish(gtk.cast(gtk.FileLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open the file manager");
}

pub fn revealFolder(self: *App, root_id: i64) void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = rootPath(self, root_id, &buffer) orelse return;
    const file = gtk.g_file_new_for_path(path.ptr);
    defer gtk.g_object_unref(file);
    if (gtk.g_file_query_exists(file, null) == 0) return self.toast("Folder not found");
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_launch(launcher, self.window, null, folderOpened, self);
    gtk.g_object_unref(launcher);
}

pub fn confirmRemoveFolder(self: *App, root_id: i64) void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = rootPath(self, root_id, &path_buffer) orelse return self.toast("Could not remove that folder");
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const folder = if (slash) |index| trimmed[index + 1 ..] else trimmed;
    var buffer: [1024]u8 = undefined;
    const heading = strings.printZ(&buffer, "Remove “{s}”?", .{if (folder.len == 0) path else folder}) catch "Remove this folder?";
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Its tracks leave the library with their loves, ratings, play counts and playlist entries. The files on disk are not touched.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "remove", "Remove");
    adw.adw_alert_dialog_set_response_appearance(alert, "remove", adw.RESPONSE_DESTRUCTIVE);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    const pending = self.allocator.create(PendingRemoval) catch return;
    pending.* = .{ .self = self, .root_id = root_id };
    _ = gtk.signalConnect(dialog, "response", gtk.callback(removeRootResponse), pending);
    adw.adw_dialog_present(dialog, if (self.window) |window| gtk.cast(gtk.Widget, window) else null);
}

fn removeRootResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const pending: *PendingRemoval = @ptrCast(@alignCast(data.?));
    const self = pending.self;
    defer self.allocator.destroy(pending);
    if (!std.mem.eql(u8, std.mem.span(response), "remove")) return;
    const library = self.library orelse return;
    const removed = self.runtime.libraryRemoveRoot(library, pending.root_id) catch |err| return self.toast(switch (err) {
        error.LibraryJobRunning => "Wait for the running job to finish, then remove the folder",
        else => "Could not remove that folder",
    });
    var buffer: [64]u8 = undefined;
    self.toast(strings.format(&buffer, "Removed {d} {s}", .{
        removed.tracks_removed,
        if (removed.tracks_removed == 1) "track" else "tracks",
    }));
    jobs.reloadLibraryViews(self);
    self.requestTick();
}

fn addFolderActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.chooseFolder(state(data));
}

fn rescanActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.rescan(state(data));
}

fn watchSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.watch_folders) return;
    self.watch_folders = enabled;
    if (watching.apply(self) == .failed) {
        self.watch_folders = !enabled;
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), if (self.watch_folders) gtk.true_ else gtk.false_);
        self.toast(if (enabled) "Could not watch the music folders" else "Could not stop watching the music folders");
        return;
    }
    settings.save(self);
    showWatchStatus(self);
    self.requestTick();
}

const watch_subtitle = "Scan automatically for new or changed files";

fn watchStatusText(buffer: []u8, self: *App) [:0]const u8 {
    if (!self.watch_folders) return watch_subtitle;
    const library = self.library orelse return watch_subtitle;
    const status = self.runtime.libraryWatchStatus(library) catch return watch_subtitle;
    if (status.state == .off) return "The music folders could not be watched";
    if (status.state == .watching and status.roots_unavailable == 0 and !status.watch_limit_reached) return watch_subtitle;
    return watching.statusText(buffer, status);
}

fn showWatchStatus(self: *App) void {
    const row = self.watch_row orelse return;
    var buffer: [320]u8 = undefined;
    const text = watchStatusText(&buffer, self);
    if (std.mem.eql(u8, text, self.watch_status_text[0..self.watch_status_len])) return;
    @memcpy(self.watch_status_text[0..text.len], text);
    self.watch_status_len = text.len;
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), text.ptr);
}

fn maintenanceSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.idle_maintenance) return;
    self.idle_maintenance = enabled;
    maintenance.apply(self) catch {
        self.idle_maintenance = !enabled;
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), if (self.idle_maintenance) gtk.true_ else gtk.false_);
        self.toast(if (enabled) "Could not turn on idle maintenance" else "Could not turn off idle maintenance");
        return;
    };
    settings.save(self);
    showMaintenanceStatus(self);
    self.requestTick();
}

fn maintenanceStatusText(buffer: []u8, self: *App) [:0]const u8 {
    if (!self.match_fingerprints) return "Needs Match by audio fingerprint";
    const status = maintenance.status(self) orelse return "";
    return maintenance.statusText(buffer, status);
}

fn showMaintenanceStatus(self: *App) void {
    const row = self.maintenance_row orelse return;
    gtk.gtk_widget_set_sensitive(row, if (self.match_fingerprints) gtk.true_ else gtk.false_);
    var buffer: [128]u8 = undefined;
    const text = maintenanceStatusText(&buffer, self);
    if (std.mem.eql(u8, text, self.maintenance_status_text[0..self.maintenance_status_len])) return;
    @memcpy(self.maintenance_status_text[0..text.len], text);
    self.maintenance_status_len = text.len;
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), text.ptr);
}

fn measureClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startAnalysis(state(data));
}

fn stepButton(icon: [*:0]const u8, label: [*:0]const u8, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_add_css_class(button, "circular");
    gtk.gtk_widget_add_css_class(button, "settings-step");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, label);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
    _ = gtk.signalConnect(button, "clicked", handler, data);
    return button;
}

fn stepperRow(
    stepper: *app.Stepper,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    decrease: gtk.GCallback,
    increase: gtk.GCallback,
    data: ?*anyopaque,
) *gtk.Widget {
    const row = actionRow(title, subtitle);
    const value = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(value, "settings-value");
    gtk.gtk_widget_add_css_class(value, "numeric");
    gtk.gtk_widget_set_valign(value, gtk.ALIGN_CENTER);
    const minus = stepButton("orca-minus-symbolic", "Decrease", decrease, data);
    const plus = stepButton("orca-plus-symbolic", "Increase", increase, data);
    const row_widget = gtk.cast(adw.ActionRow, row);
    adw.adw_action_row_add_suffix(row_widget, value);
    adw.adw_action_row_add_suffix(row_widget, minus);
    adw.adw_action_row_add_suffix(row_widget, plus);
    stepper.* = .{ .value = gtk.cast(gtk.Label, value), .decrease = minus, .increase = plus };
    return row;
}

fn showStepper(stepper: app.Stepper, text: [:0]const u8, value: u16, range: [2]u16) void {
    if (stepper.value) |label| gtk.gtk_label_set_text(label, text.ptr);
    if (stepper.decrease) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(value > range[0]));
    if (stepper.increase) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(value < range[1]));
}

fn threadRange() [2]u16 {
    return .{ 1, liborca.analysisAvailableThreads() };
}

fn shownThreads(self: *App) u16 {
    return std.math.clamp(self.analysis_threads orelse liborca.analysisDefaultThreads(), 1, threadRange()[1]);
}

fn showThreads(self: *App) void {
    const threads = shownThreads(self);
    var buffer: [16]u8 = undefined;
    showStepper(self.settings_page.threads, strings.format(&buffer, "{d}", .{threads}), threads, threadRange());
}

fn stepThreads(self: *App, delta: i32) void {
    const range = threadRange();
    const current: i32 = shownThreads(self);
    const threads: u16 = @intCast(std.math.clamp(current + delta, range[0], range[1]));
    if (threads == current) return;
    self.analysis_threads = threads;
    settings.save(self);
    showThreads(self);
}

fn threadsDecreased(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    stepThreads(state(data), -1);
}

fn threadsIncreased(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    stepThreads(state(data), 1);
}

fn duplicatesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startDuplicates(state(data));
}

fn showThreshold(self: *App) void {
    const percent = self.match_threshold_percent;
    var buffer: [16]u8 = undefined;
    showStepper(self.settings_page.threshold, strings.format(&buffer, "{d}%", .{percent}), percent, .{ settings.threshold_range[0], settings.threshold_range[1] });
}

fn stepThreshold(self: *App, delta: i32) void {
    const range = settings.threshold_range;
    const current: i32 = self.match_threshold_percent;
    const percent: u8 = @intCast(std.math.clamp(current + delta, range[0], range[1]));
    if (percent == current) return;
    self.match_threshold_percent = percent;
    settings.save(self);
    matches.invalidate(self);
    showThreshold(self);
}

fn thresholdDecreased(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    stepThreshold(state(data), -1);
}

fn thresholdIncreased(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    stepThreshold(state(data), 1);
}

fn fingerprintsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.match_fingerprints) return;
    self.match_fingerprints = enabled;
    settings.save(self);
    matches.invalidate(self);
    maintenance.apply(self) catch self.toast("Could not change idle maintenance");
    showMaintenanceStatus(self);
    self.requestTick();
}

fn contributeSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.contribute_acoustid) return;
    self.contribute_acoustid = enabled;
    settings.save(self);
    submissions.autoStart(self);
    self.requestTick();
}

fn submitNowClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startSubmission(state(data));
}

const contribute_subtitle = "Sends the recording IDs you confirm, with their fingerprints";
const contribute_needs_key = "Needs your AcoustID key";

pub fn showSubmission(self: *App) void {
    const keyed: gtk.gboolean = if (self.acoustid_key_stored) gtk.true_ else gtk.false_;
    if (self.contribute_row) |row| {
        gtk.gtk_widget_set_sensitive(row, keyed);
        adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), if (self.acoustid_key_stored) contribute_subtitle else contribute_needs_key);
    }
    const row = self.submission_row orelse return;
    gtk.gtk_widget_set_sensitive(row, keyed);
    const count = submissions.waiting(self);
    var buffer: [48]u8 = undefined;
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), if (count == 0)
        "Nothing waiting"
    else
        strings.format(&buffer, "{f} {s} waiting", .{ strings.grouped(count), if (count == 1) "file" else "files" }));
    const sent = submissions.submitted(self);
    var sent_buffer: [48]u8 = undefined;
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), if (sent == 0)
        ""
    else
        strings.format(&sent_buffer, "{f} {s} submitted", .{ strings.grouped(sent), if (sent == 1) "file" else "files" }));
    if (self.submission_button) |button| gtk.gtk_widget_set_visible(button, @intFromBool(count != 0));
}

fn submissionRows(self: *App, target: Card) void {
    const contribute = switchRow("Contribute to AcoustID", contribute_subtitle, self.contribute_acoustid, gtk.callback(contributeSwitched), self);
    self.contribute_row = contribute;
    target.add(contribute);
    const status = actionRow("Nothing waiting", "");
    self.submission_button = suffixButton(status, "Submit Now", null, gtk.callback(submitNowClicked), self);
    self.submission_row = status;
    target.add(status);
    showSubmission(self);
}

const acoustid_key_url = "https://acoustid.org/api-key";
const acoustid_key_link = "<a href=\"" ++ acoustid_key_url ++ "\">acoustid.org↗</a>";

fn externalLink(uri: [*:0]const u8, text: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_link_button_new_with_label(uri, text);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(text));
    const icon = gtk.gtk_image_new_from_icon_name("adw-external-link-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 12);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon);
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(button, "settings-link");
    return button;
}

fn identificationCard(self: *App) *gtk.Widget {
    const identification = flatCard(
        "orca-matches-symbolic",
        "Identification",
        "MusicBrainz and AcoustID help Orca match and tag your music.",
    );
    identification.add(fixedRow("MusicBrainz", "Look up release metadata"));
    identification.add(switchRow("Match by audio fingerprint", "Sends fingerprints to AcoustID", self.match_fingerprints, gtk.callback(fingerprintsSwitched), self));
    AcoustIdKey.add(self, identification);
    submissionRows(self, identification);
    identification.add(stepperRow(
        &self.settings_page.threshold,
        "Accept confident matches at",
        "Lower scores wait in Matches for your review",
        gtk.callback(thresholdDecreased),
        gtk.callback(thresholdIncreased),
        self,
    ));
    showThreshold(self);
    AcoustIdKey.checkOnce(self);
    return identification.widget;
}

fn writingCard() *gtk.Widget {
    const writing = flatCard("orca-pen-symbolic", "Writing to Files", "Edits stay in Orca's database until you choose Write to Files.");
    writing.add(fixedRow("Always preview before writing tags", ""));
    return writing.widget;
}

const folder_rows_shown = 6;
const folder_row_height = 55;

fn folderMenu(root_id: i64) *gtk.GMenu {
    const entries = [_]struct { label: [*:0]const u8, action: []const u8 }{
        .{ .label = "Rescan", .action = "settings-folder-rescan" },
        .{ .label = "Show in Files", .action = "settings-folder-reveal" },
        .{ .label = "Remove", .action = "settings-folder-remove" },
    };
    const model = gtk.g_menu_new();
    for (entries) |entry| {
        var buffer: [64]u8 = undefined;
        const detailed = strings.printZ(&buffer, "app.{s}(int64 {d})", .{ entry.action, root_id }) catch continue;
        gtk.g_menu_append(model, entry.label, detailed.ptr);
    }
    return model;
}

fn folderSubtitle(root: liborca.LibraryRoot) [*:0]const u8 {
    if (!root.enabled) return "Paused";
    if (!root.available) return "Unavailable";
    return "";
}

fn folderRows(self: *App, library: liborca.LibraryHandle) *gtk.Widget {
    const rows = adw.adw_preferences_group_new();
    gtk.gtk_widget_add_css_class(rows, "settings-folder-list");
    var roots = self.runtime.libraryRootPage(library, app.page_size, 0) catch return rows;
    defer roots.deinit();
    var buffer: [1024]u8 = undefined;
    for (roots.items) |root| {
        const row = actionRow(strings.terminated(&buffer, root.path).ptr, folderSubtitle(root));
        gtk.gtk_widget_add_css_class(row, "settings-folder-row");
        adw.adw_action_row_add_prefix(gtk.cast(adw.ActionRow, row), gtk.gtk_image_new_from_icon_name("orca-folders-symbolic"));
        gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, row), gtk.false_);
        gtk.gtk_widget_set_focusable(row, gtk.false_);
        const actions = gtk.gtk_menu_button_new();
        gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, actions), "orca-more-symbolic");
        gtk.gtk_widget_add_css_class(actions, "flat");
        gtk.gtk_widget_set_valign(actions, gtk.ALIGN_CENTER);
        gtk.gtk_widget_set_tooltip_text(actions, "Folder actions");
        const model = folderMenu(root.id);
        gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, actions), gtk.cast(gtk.GMenuModel, model));
        gtk.g_object_unref(model);
        adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), actions);
        adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, rows), row);
    }
    if (roots.items.len <= folder_rows_shown) return rows;
    const scroller = gtk.gtk_scrolled_window_new();
    const window = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(window, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_min_content_height(window, folder_rows_shown * folder_row_height);
    gtk.gtk_scrolled_window_set_max_content_height(window, folder_rows_shown * folder_row_height);
    gtk.gtk_scrolled_window_set_child(window, rows);
    return scroller;
}

fn labelledButton(label: [*:0]const u8, icon: [*:0]const u8, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const button = gtk.gtk_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_image_new_from_icon_name(icon));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(label));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    _ = gtk.signalConnect(button, "clicked", handler, data);
    return button;
}

fn showMeasure(self: *App) void {
    const page = &self.settings_page;
    const button = page.measure_button orelse return;
    const library = self.library orelse return;
    const unmeasured = self.runtime.libraryUnanalyzedCount(library) catch 0;
    var buffer: [256]u8 = undefined;
    const tooltip: [:0]const u8 = if (unmeasured == 0)
        "Every track is analyzed"
    else
        strings.format(&buffer, "{f} {s} need analysis; this decodes each file, so it can take a while", .{
            strings.grouped(unmeasured),
            plural(unmeasured, "track", "tracks"),
        });
    gtk.gtk_widget_set_tooltip_text(button, tooltip.ptr);
    gtk.gtk_widget_set_sensitive(button, if (unmeasured != 0) gtk.true_ else gtk.false_);
}

fn duplicatesSubtitle(buffer: []u8, self: *App) [:0]const u8 {
    const library = self.library orelse return "Compares audio";
    const stats = self.runtime.libraryStats(library) catch return "Compares audio";
    const scanned = stats.last_duplicate_scan_at orelse return "Compares audio · never run";
    var ago_buffer: [32]u8 = undefined;
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    return strings.format(buffer, "Compares audio · last scan {s}", .{activity.agoText(&ago_buffer, now, scanned)});
}

fn showDuplicates(self: *App) void {
    const row = self.settings_page.duplicates_row orelse return;
    var buffer: [96]u8 = undefined;
    setSubtitle(row, duplicatesSubtitle(&buffer, self));
}

pub fn refreshLibrary(self: *App) void {
    if (self.current_page != .settings) return;
    showMeasure(self);
    const slot = self.settings_page.folder_slot orelse return;
    const library = self.library orelse return;
    if (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, slot))) |old| gtk.gtk_box_remove(slot, old);
    gtk.gtk_box_append(slot, folderRows(self, library));
}

fn foldersCard(self: *App, library: liborca.LibraryHandle) *gtk.Widget {
    const folders = flatCard(
        "orca-folders-symbolic",
        "Music Folders",
        "Orca reads these folders. It never changes a file unless you write tags to it.",
    );
    const slot = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, slot), folderRows(self, library));
    gtk.gtk_box_insert_child_after(gtk.cast(gtk.Box, folders.widget), slot, folders.header);
    self.settings_page.folder_slot = gtk.cast(gtk.Box, slot);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(actions, "settings-folder-actions");
    const add = labelledButton("Add Folder…", "orca-plus-symbolic", gtk.callback(addFolderActivated), self);
    gtk.gtk_widget_add_css_class(add, "settings-add-folder");
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), add);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), labelledButton("Rescan All Folders", "orca-refresh-symbolic", gtk.callback(rescanActivated), self));
    gtk.gtk_box_insert_child_after(gtk.cast(gtk.Box, folders.widget), actions, slot);

    if (watching.supported(self)) {
        const watch = switchRow("Watch folders for changes", watch_subtitle, self.watch_folders, gtk.callback(watchSwitched), self);
        folders.add(watch);
        self.watch_row = watch;
        self.watch_status_len = 0;
        showWatchStatus(self);
    }
    return folders.widget;
}

fn maintenanceCard(self: *App) *gtk.Widget {
    const maintenance_card = flatCard("orca-pulse-symbolic", "Maintenance", "Keep your library healthy and consistent.");
    const measure = actionRow("Analyze music", jobs.analysis_summary);
    const measure_button = suffixButton(measure, "Analyze", null, gtk.callback(measureClicked), self);
    self.settings_page.measure_button = measure_button;
    showMeasure(self);
    maintenance_card.add(measure);

    var buffer: [64]u8 = undefined;
    const threads_subtitle = strings.format(&buffer, "Parallel workers (default {d})", .{liborca.analysisDefaultThreads()});
    maintenance_card.add(stepperRow(
        &self.settings_page.threads,
        "Analysis threads",
        threads_subtitle.ptr,
        gtk.callback(threadsDecreased),
        gtk.callback(threadsIncreased),
        self,
    ));
    showThreads(self);

    const duplicates = actionRow("Find duplicates", "");
    _ = suffixButton(duplicates, "Find", null, gtk.callback(duplicatesClicked), self);
    self.settings_page.duplicates_row = duplicates;
    showDuplicates(self);
    maintenance_card.add(duplicates);

    const idle = switchRow("Idle maintenance", "", self.idle_maintenance, gtk.callback(maintenanceSwitched), self);
    maintenance_card.add(idle);
    self.maintenance_row = idle;
    self.maintenance_status_len = 0;
    showMaintenanceStatus(self);
    return maintenance_card.widget;
}

fn genreFillSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const switch_row = gtk.cast(adw.SwitchRow, row);
    const enabled = adw.adw_switch_row_get_active(switch_row) != 0;
    const current = self.runtime.libraryGenreFill(library) catch liborca.GenreFill{};
    if (current.musicbrainz == enabled) return;
    self.runtime.setGenreFill(library, .{ .musicbrainz = enabled }) catch {
        adw.adw_switch_row_set_active(switch_row, @intFromBool(!enabled));
        self.toast("Could not change genre filling");
        return;
    };
    showGenreSource(self, enabled);
}

fn showGenreSource(self: *App, genre_fill_on: bool) void {
    const row = self.settings_page.genre_source_row orelse return;
    gtk.gtk_widget_set_visible(row, @intFromBool(genre_fill_on));
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(byte),
    };
}

fn sourceSubtitle(buffer: []u8, source: liborca.ProviderSource) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeSourceSubtitle(&writer, source) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn writeSourceSubtitle(writer: *std.Io.Writer, source: liborca.ProviderSource) std.Io.Writer.Error!void {
    try writeEscaped(writer, source.supplies);
    try writer.writeByte('\n');
    if (source.licence_url) |licence_url| {
        try writer.writeAll("<a href=\"");
        try writeEscaped(writer, licence_url);
        try writer.writeAll("\">");
        try writeEscaped(writer, source.licence);
        try writer.writeAll("</a>");
    } else try writeEscaped(writer, source.licence);
}

fn sourceRow(source: liborca.ProviderSource) *gtk.Widget {
    var name_buffer: [64]u8 = undefined;
    var subtitle_buffer: [1024]u8 = undefined;
    const name = strings.printZ(&name_buffer, "{s}", .{source.name}) catch "";
    const row = actionRow(name.ptr, sourceSubtitle(&subtitle_buffer, source).ptr);
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, row), 0);
    var url_buffer: [160]u8 = undefined;
    const url = strings.printZ(&url_buffer, "{s}", .{source.url}) catch "";
    const site = std.mem.cutPrefix(u8, source.url, "https://") orelse source.url;
    var site_buffer: [96]u8 = undefined;
    const site_text = strings.printZ(&site_buffer, "{s}", .{site}) catch "";
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), externalLink(url.ptr, site_text.ptr));
    return row;
}

fn sourcesCard(self: *App) *gtk.Widget {
    const sources = flatCard("orca-info-symbolic", "Data sources", "Where Orca's online information comes from, and the terms it comes under.");
    const genre_fill_on = if (self.library) |library|
        (self.runtime.libraryGenreFill(library) catch liborca.GenreFill{}).musicbrainz
    else
        false;
    if (self.library != null) sources.add(switchRow(
        "Fill missing genres from MusicBrainz",
        "When artist or album info is fetched, tracks with no genre from a file or an edit take MusicBrainz's",
        genre_fill_on,
        gtk.callback(genreFillSwitched),
        self,
    ));
    self.settings_page.genre_source_row = null;
    for (self.runtime.providerSources()) |source| {
        const row = sourceRow(source);
        sources.add(row);
        if (source.id == .musicbrainz_genres) {
            self.settings_page.genre_source_row = row;
            showGenreSource(self, genre_fill_on);
        }
    }
    return sources.widget;
}

fn libraryTab(self: *App) *gtk.Widget {
    const library = self.library orelse return tab(self, .library, null, &.{}, &.{ identificationCard(self), writingCard() });
    return tab(self, .library, null, &.{ foldersCard(self, library), maintenanceCard(self) }, &.{ identificationCard(self), writingCard() });
}

fn generalTab(self: *App) *gtk.Widget {
    const general = self.general;
    const startup = flatCard("orca-play-symbolic", "Startup", "What happens when Orca opens.");
    startup.add(switchRow("Open Orca at login", "", general.launch_at_login, gtk.callback(loginSwitched), self));
    startup.add(selectRow(
        "Default page",
        "Queue and resume behavior live in Playback",
        &.{ "Home", "Albums", "Artists", "Tracks", "Now Playing", null },
        @backingInt(general.start_page),
        gtk.callback(startPagePicked),
        self,
    ));

    const notifications = flatCard("orca-info-symbolic", "Notifications", "Shown by your desktop's notification system.");
    notifications.add(switchRow("Track changes", "", general.notify_tracks, gtk.callback(trackNotificationsSwitched), self));
    notifications.add(switchRow("Library tasks", "Scans, analysis and file writes", general.notify_tasks, gtk.callback(taskNotificationsSwitched), self));

    const sorting = flatCard("orca-genres-symbolic", "Language & Sorting", "");
    sorting.add(selectRow(
        "Sort artist names",
        "Ignore leading articles",
        &.{ "Ignore The, A, An", "Sort as written", null },
        @backingInt(general.name_order),
        gtk.callback(nameOrderPicked),
        self,
    ));

    const keyboard = flatCard("input-keyboard-symbolic", "Keyboard", "Space, Ctrl K, Ctrl I, Ctrl F, L, 1–5 and more");
    const shortcuts = adw.adw_expander_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, shortcuts), "Shortcuts");
    for (shortcut_summary) |shortcut| {
        const row = actionRow(shortcut.action, "");
        gtk.gtk_widget_add_css_class(row, "settings-shortcut");
        const chip = gtk.gtk_label_new(shortcut.keys);
        gtk.gtk_widget_add_css_class(chip, "settings-key");
        gtk.gtk_widget_set_valign(chip, gtk.ALIGN_CENTER);
        adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), chip);
        adw.adw_expander_row_add_row(gtk.cast(adw.ExpanderRow, shortcuts), row);
    }
    keyboard.add(shortcuts);
    return tab(self, .general, null, &.{ startup.widget, notifications.widget }, &.{ sorting.widget, keyboard.widget });
}

const Shortcut = struct { keys: [*:0]const u8, action: [*:0]const u8 };

const shortcut_summary = [_]Shortcut{
    .{ .keys = "Space", .action = "Play or pause" },
    .{ .keys = "Ctrl K", .action = "Command palette" },
    .{ .keys = "Ctrl F", .action = "Filter the current page" },
    .{ .keys = "Alt ← / Alt →", .action = "Back / Forward" },
    .{ .keys = "L", .action = "Love the selected or playing track" },
    .{ .keys = "Delete", .action = "Remove the selected queue or playlist entry" },
    .{ .keys = "Shift Enter", .action = "Play next" },
    .{ .keys = "Ctrl I", .action = "Toggle the inspector" },
    .{ .keys = "1–5", .action = "Rate the selected or playing track" },
    .{ .keys = "Ctrl Enter", .action = "Play now" },
    .{ .keys = "Ctrl Shift R", .action = "Scan library" },
    .{ .keys = "Ctrl → / Ctrl ←", .action = "Next / previous track" },
};

fn loginSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    const switch_row = gtk.cast(adw.SwitchRow, row);
    const enabled = adw.adw_switch_row_get_active(switch_row) != 0;
    if (!autostart.set(enabled)) {
        self.settings_page.syncing = true;
        defer self.settings_page.syncing = false;
        adw.adw_switch_row_set_active(switch_row, @intFromBool(!enabled));
        return self.toast(if (enabled) "Could not add Orca to the login items" else "Could not remove Orca from the login items");
    }
    self.general.launch_at_login = enabled;
    settings.save(self);
}

fn startPagePicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    self.general.start_page = std.enums.fromInt(app.StartPage, selected) orelse return;
    settings.save(self);
}

fn trackNotificationsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.general.notify_tracks = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    settings.save(self);
}

fn taskNotificationsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.general.notify_tasks = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    settings.save(self);
}

fn nameOrderPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    const order = std.enums.fromInt(liborca.NameOrder, selected) orelse return;
    if (order == self.general.name_order) return;
    self.general.name_order = order;
    settings.save(self);
    artists.reload(self);
    albums.reload(self);
    browse.reload(self);
}

fn selectRow(title: [*:0]const u8, subtitle: [*:0]const u8, labels: []const ?[*:0]const u8, selected: c_uint, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const row = actionRow(title, subtitle);
    const drop_down = gtk.gtk_drop_down_new_from_strings(labels.ptr);
    gtk.gtk_widget_add_css_class(drop_down, "settings-select");
    gtk.gtk_widget_set_valign(drop_down, gtk.ALIGN_CENTER);
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, drop_down), selected);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, drop_down), gtk.ACCESSIBLE_PROPERTY_LABEL, title, @as(c_int, -1));
    _ = gtk.signalConnect(drop_down, "notify::selected", handler, data);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), drop_down);
    adw.adw_action_row_set_activatable_widget(gtk.cast(adw.ActionRow, row), drop_down);
    return row;
}

const segment_key = "orca-settings-segment";

fn segmentedRow(title: [*:0]const u8, subtitle: [*:0]const u8, labels: []const [*:0]const u8, selected: usize, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const row = actionRow(title, subtitle);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "settings-segmented");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, box), gtk.ACCESSIBLE_PROPERTY_LABEL, title, @as(c_int, -1));
    var group: ?*gtk.ToggleButton = null;
    for (labels, 0..) |label, index| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), label);
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        if (index == selected) gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
        gtk.g_object_set_data(button, segment_key, @ptrFromInt(index + 1));
        _ = gtk.signalConnect(button, "toggled", handler, data);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), box);
    return row;
}

fn chosenSegment(button: ?*anyopaque) ?usize {
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return null;
    return @intFromPtr(gtk.g_object_get_data(button.?, segment_key)) - 1;
}

fn artistInfoCard(self: *App) *gtk.Widget {
    const info = flatCard(
        "orca-artists-symbolic",
        "Artist Info",
        "Photos, biographies, links and related artists come from MusicBrainz, Wikidata, Wikimedia Commons, Wikipedia and ListenBrainz, and stay in your library.",
    );
    const fetch = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, fetch), "Fetch artist info");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, fetch), "Looks an artist up the first time you open their page, when the library has their MusicBrainz ID");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, fetch), if (self.fetch_artist_info) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(fetch, "notify::active", gtk.callback(artistInfoSwitched), self);
    info.add(fetch);
    return info.widget;
}

fn artistInfoSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.fetch_artist_info = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    settings.save(self);
}

const replay_gain_modes = [_]liborca.ReplayGainMode{ .off, .track, .album, .smart };
const replay_gain_preamp_range = [2]f64{ -15, 15 };

fn replayGainPicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenSegment(button) orelse return;
    self.runtime.playerSetReplayGainMode(self.player, replay_gain_modes[index]) catch
        return self.toast("Could not change ReplayGain");
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn replayGainPreampChanged(spin: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const value: f32 = @floatCast(gtk.gtk_spin_button_get_value(gtk.cast(gtk.SpinButton, spin)));
    self.runtime.playerSetReplayGainPreamp(self.player, value) catch
        return self.toast("Could not change the preamp");
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn clippingSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    self.runtime.playerSetPeakProtection(self.player, enabled) catch
        return self.toast("Could not change clipping protection");
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn untaggedPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    const fallback: liborca.UntaggedFallback = if (selected == 0) .minus_6_db else .as_is;
    self.runtime.playerSetReplayGainFallback(self.player, fallback) catch
        return self.toast("Could not change how untagged tracks play");
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn stopAfterSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    self.runtime.playerSetStopAfterCurrent(self.player, enabled) catch
        return self.toast("Could not change stop after current track");
    self.requestTick();
}

fn queueEndPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    const mode: liborca.RepeatMode = if (selected == 1) .all else .off;
    self.runtime.playerSetRepeat(self.player, mode) catch
        return self.toast("Could not change what happens when the queue ends");
    self.repeat_mode = mode;
    transport.showRepeat(self, mode);
    settings.save(self);
}

fn rememberPositionSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.playback.remember_long_position = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    transport.applyLongTrackMemory(self);
    settings.save(self);
}

fn onLaunchPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    self.playback.on_launch = std.enums.fromInt(app.OnLaunch, selected) orelse return;
    settings.save(self);
}

fn outputPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    transport.selectDevice(self, gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down)));
}

fn fillDeviceNames(self: *App, names: *gtk.StringList) void {
    const count = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, names));
    gtk.gtk_string_list_splice(names, 0, count, null);
    for (self.device_names.items) |name| gtk.gtk_string_list_append(names, name.ptr);
}

pub fn showOutputDevice(self: *App) void {
    showDevicePresets(self);
    const page = &self.settings_page;
    const drop_down = page.device_drop_down orelse return;
    page.syncing = true;
    defer page.syncing = false;
    if (page.device_drop_down_names) |names| fillDeviceNames(self, names);
    gtk.gtk_drop_down_set_selected(drop_down, @intCast(self.device_index));
}

fn deviceNames(self: *App) *gtk.StringList {
    const names = gtk.gtk_string_list_new(null);
    for (self.device_names.items) |name| gtk.gtk_string_list_append(names, name.ptr);
    return names;
}

fn fixedRow(title: [*:0]const u8, subtitle: [*:0]const u8) *gtk.Widget {
    const row = actionRow(title, subtitle);
    const toggle = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, toggle), gtk.true_);
    gtk.gtk_widget_set_sensitive(toggle, gtk.false_);
    gtk.gtk_widget_add_css_class(toggle, "settings-fixed");
    gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, toggle), gtk.ACCESSIBLE_PROPERTY_LABEL, title, @as(c_int, -1));
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), toggle);
    return row;
}

fn valueRow(title: [*:0]const u8, subtitle: [*:0]const u8, value: [*:0]const u8) *gtk.Widget {
    const row = actionRow(title, subtitle);
    _ = addValue(row, value);
    return row;
}

fn addValue(row: *gtk.Widget, value: [*:0]const u8) *gtk.Label {
    const label = gtk.gtk_label_new(value);
    gtk.gtk_widget_add_css_class(label, "settings-value");
    gtk.gtk_widget_set_valign(label, gtk.ALIGN_CENTER);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), label);
    return gtk.cast(gtk.Label, label);
}

fn queueEndIndex(mode: liborca.RepeatMode) c_uint {
    return if (mode == .off) 0 else 1;
}

fn playbackTab(self: *App) *gtk.Widget {
    const controls = &self.sound_controls;
    const gain = self.runtime.playerReplayGainSettings(self.player) catch liborca.ReplayGainSettings{};
    const leveling = flatCard("orca-gain-symbolic", "Volume Leveling", "Even out loudness without touching your files.");
    leveling.add(segmentedRow(
        "ReplayGain",
        "Smart uses album gain for albums, track gain in shuffle",
        &.{ "Off", "Track", "Album", "Smart" },
        std.mem.indexOfScalar(liborca.ReplayGainMode, &replay_gain_modes, gain.mode) orelse 0,
        gtk.callback(replayGainPicked),
        self,
    ));
    const preamp = actionRow("Preamp", "Applied after ReplayGain");
    const preamp_entry = parametric.decibelEntry(replay_gain_preamp_range, strings.withoutNegativeZero(gain.preamp_db), "Preamp");
    gtk.gtk_widget_add_css_class(preamp_entry, "settings-number");
    _ = gtk.signalConnect(preamp_entry, "value-changed", gtk.callback(replayGainPreampChanged), self);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, preamp), preamp_entry);
    leveling.add(preamp);
    leveling.add(switchRow("Prevent clipping", "Lowers gain when peaks would pass 0 dBFS", gain.peak_protection, gtk.callback(clippingSwitched), self));
    leveling.add(selectRow(
        "Untagged tracks",
        "Tracks without loudness analysis",
        &.{ "Use −6 dB", "Play as is", null },
        if (gain.fallback == .minus_6_db) 0 else 1,
        gtk.callback(untaggedPicked),
        self,
    ));

    const transitions = flatCard("orca-shuffle-symbolic", "Transitions", "");
    transitions.add(fixedRow("Gapless playback", ""));
    const stop_after = switchRow(
        "Stop after current track",
        "",
        self.runtime.playerStopAfterCurrent(self.player) catch false,
        gtk.callback(stopAfterSwitched),
        self,
    );
    controls.stop_after_current = stop_after;
    transitions.add(stop_after);
    const queue_end = selectRow(
        "When the queue ends",
        "",
        &.{ "Stop", "Repeat queue", null },
        queueEndIndex(self.repeat_mode),
        gtk.callback(queueEndPicked),
        self,
    );
    controls.queue_end = gtk.cast(gtk.DropDown, adw.adw_action_row_get_activatable_widget(gtk.cast(adw.ActionRow, queue_end)).?);
    transitions.add(queue_end);

    const output = flatCard("audio-headphones-symbolic", "Output", "Where Orca plays and how it talks to the device.");
    transport.refreshDevices(self);
    const device = actionRow("Output device", "");
    const names = deviceNames(self);
    const drop_down = gtk.gtk_drop_down_new(gtk.cast(gtk.ListModel, names), null);
    gtk.gtk_widget_add_css_class(drop_down, "settings-select");
    gtk.gtk_widget_set_valign(drop_down, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, drop_down), gtk.ACCESSIBLE_PROPERTY_LABEL, "Output device", @as(c_int, -1));
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, drop_down), @intCast(self.device_index));
    _ = gtk.signalConnect(drop_down, "notify::selected", gtk.callback(outputPicked), self);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, device), drop_down);
    adw.adw_action_row_set_activatable_widget(gtk.cast(adw.ActionRow, device), drop_down);
    self.settings_page.device_drop_down = gtk.cast(gtk.DropDown, drop_down);
    self.settings_page.device_drop_down_names = names;
    output.add(device);
    output.add(fixedRow("Match source sample rate", "Switches the device to each track's native rate"));
    output.add(valueRow("Audio backend", "Change in Advanced", "PipeWire"));

    const playback = self.playback;
    const resuming = flatCard("orca-clock-symbolic", "Resume", "");
    resuming.add(switchRow(
        "Remember position in long tracks",
        "Mixes, podcasts and anything over 20 minutes",
        playback.remember_long_position,
        gtk.callback(rememberPositionSwitched),
        self,
    ));
    resuming.add(selectRow(
        "On launch",
        "",
        &.{ "Restore queue, paused", "Restore and play", "Start empty", null },
        @backingInt(playback.on_launch),
        gtk.callback(onLaunchPicked),
        self,
    ));
    return tab(self, .playback, null, &.{ leveling.widget, transitions.widget }, &.{ output.widget, resuming.widget });
}

/// Brings the rows that show live player state in line with it: stop after
/// current clears itself once the track ends, and the player bar cycles repeat.
fn showTransitions(self: *App) void {
    const controls = &self.sound_controls;
    const page = &self.settings_page;
    page.syncing = true;
    defer page.syncing = false;
    if (controls.stop_after_current) |row| {
        const active = self.runtime.playerStopAfterCurrent(self.player) catch false;
        const switch_row = gtk.cast(adw.SwitchRow, row);
        if ((adw.adw_switch_row_get_active(switch_row) != 0) != active)
            adw.adw_switch_row_set_active(switch_row, @intFromBool(active));
    }
    if (controls.queue_end) |drop_down| {
        const index = queueEndIndex(self.repeat_mode);
        if (gtk.gtk_drop_down_get_selected(drop_down) != index) gtk.gtk_drop_down_set_selected(drop_down, index);
    }
}

const band_count = app.equalizer_band_count;
const equalizer_settle_ms: c_uint = 60;
const band_range_db: f64 = 12;
const preamp_range_db = [2]f64{ -24, 12 };

const Band = struct { label: [*:0]const u8, tooltip: [*:0]const u8 };

const band_labels = [band_count]Band{
    .{ .label = "31", .tooltip = "31 Hz" },
    .{ .label = "62", .tooltip = "62 Hz" },
    .{ .label = "125", .tooltip = "125 Hz" },
    .{ .label = "250", .tooltip = "250 Hz" },
    .{ .label = "500", .tooltip = "500 Hz" },
    .{ .label = "1k", .tooltip = "1 kHz" },
    .{ .label = "2k", .tooltip = "2 kHz" },
    .{ .label = "4k", .tooltip = "4 kHz" },
    .{ .label = "8k", .tooltip = "8 kHz" },
    .{ .label = "16k", .tooltip = "16 kHz" },
};

const preset_labels = [_]?[*:0]const u8{ "Flat", "Bass", "Treble", "Vocal", "Loudness", null };
const preset_count: c_uint = preset_labels.len - 1;
const amount_labels = [_]?[*:0]const u8{ "Low", "Medium", "High", null };

comptime {
    std.debug.assert(preset_count == std.enums.values(liborca.EqualizerPreset).len);
    std.debug.assert(amount_labels.len - 1 == app.crossfeed_amounts.len);
}

fn matchingPreset(curve: liborca.Equalizer) ?liborca.EqualizerPreset {
    for (std.enums.values(liborca.EqualizerPreset)) |preset| {
        const candidate = liborca.Equalizer.preset(preset);
        if (std.mem.eql(f32, &candidate.gains_db, &curve.gains_db) and
            candidate.preamp_db == curve.preamp_db) return preset;
    }
    return null;
}

fn nearestAmountIndex(amount: f32) c_uint {
    var nearest: usize = 0;
    for (app.crossfeed_amounts, 0..) |candidate, index| {
        if (@abs(candidate - amount) < @abs(app.crossfeed_amounts[nearest] - amount)) nearest = index;
    }
    return @intCast(nearest);
}

fn halfDecibels(value: f64) f32 {
    return strings.withoutNegativeZero(@floatCast(@round(value * 2) / 2));
}

/// The curve the sliders and the preamp show. A drag reports any value, and the
/// sliders are steps of half a decibel, so the value is snapped here rather
/// than by moving the slider under the pointer.
fn editedCurve(self: *App) liborca.Equalizer {
    var curve = self.equalizer_curve;
    for (self.sound_controls.band_scales, 0..) |maybe_scale, index| {
        const scale = maybe_scale orelse continue;
        curve.gains_db[index] = halfDecibels(gtk.gtk_range_get_value(gtk.cast(gtk.Range, scale)));
    }
    if (self.sound_controls.preamp_row) |row|
        curve.preamp_db = @floatCast(adw.adw_spin_row_get_value(gtk.cast(adw.SpinRow, row)));
    return curve;
}

fn showCurve(self: *App, curve: liborca.Equalizer) void {
    const previous = self.suppress_sound_signals;
    self.suppress_sound_signals = true;
    defer self.suppress_sound_signals = previous;
    for (self.sound_controls.band_scales, curve.gains_db) |maybe_scale, gain_db| {
        const scale = maybe_scale orelse continue;
        gtk.gtk_range_set_value(gtk.cast(gtk.Range, scale), gain_db);
    }
    if (self.sound_controls.preamp_row) |row|
        adw.adw_spin_row_set_value(gtk.cast(adw.SpinRow, row), strings.withoutNegativeZero(curve.preamp_db));
}

/// Selects `preset` in the Preset row, or "Custom" for null. Custom is in the
/// list only while it is the selection.
fn showPreset(self: *App, preset: ?liborca.EqualizerPreset) void {
    const row = self.sound_controls.preset_row orelse return;
    const names = self.sound_controls.preset_names orelse return;
    const previous = self.suppress_sound_signals;
    self.suppress_sound_signals = true;
    defer self.suppress_sound_signals = previous;
    const has_custom = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, names)) > preset_count;
    if (preset) |chosen| {
        adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, row), @backingInt(chosen));
        if (has_custom) gtk.gtk_string_list_splice(names, preset_count, 1, null);
    } else {
        if (!has_custom) gtk.gtk_string_list_append(names, "Custom");
        adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, row), preset_count);
    }
}

fn showEqualizerEnabled(self: *App, enabled: bool) void {
    const controls = &self.sound_controls;
    for ([_]?*gtk.Widget{ controls.preset_row, controls.bands, controls.preamp_row }) |maybe_widget| {
        const widget = maybe_widget orelse continue;
        gtk.gtk_widget_set_sensitive(widget, if (enabled) gtk.true_ else gtk.false_);
    }
}

fn equalizerIsOn(self: *App) bool {
    return (self.runtime.playerEqualizer(self.player) catch null) != null;
}

fn cancelEqualizerTimer(self: *App) void {
    if (self.equalizer_apply_timer == 0) return;
    _ = gtk.g_source_remove(self.equalizer_apply_timer);
    self.equalizer_apply_timer = 0;
}

fn applyEqualizer(self: *App, enabled: bool) void {
    cancelEqualizerTimer(self);
    self.runtime.playerSetEqualizer(self.player, if (enabled) self.equalizer_curve else null) catch
        return self.toast("Could not apply the equalizer");
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn equalizerSettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.equalizer_apply_timer = 0;
    applyEqualizer(self, equalizerIsOn(self));
    return gtk.SOURCE_REMOVE;
}

fn scheduleEqualizer(self: *App) void {
    cancelEqualizerTimer(self);
    self.equalizer_apply_timer = gtk.g_timeout_add(equalizer_settle_ms, equalizerSettled, self);
}

fn curveEdited(self: *App) void {
    if (self.suppress_sound_signals) return;
    self.equalizer_curve = editedCurve(self);
    showPreset(self, matchingPreset(self.equalizer_curve));
    scheduleEqualizer(self);
}

fn bandMoved(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    curveEdited(state(data));
}

fn preampChanged(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    curveEdited(state(data));
}

fn presetChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_sound_signals) return;
    const selected = adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row));
    const preset = std.enums.fromInt(liborca.EqualizerPreset, selected) orelse return;
    self.equalizer_curve = liborca.Equalizer.preset(preset);
    showCurve(self, self.equalizer_curve);
    showPreset(self, preset);
    applyEqualizer(self, true);
}

fn applyCrossfeed(self: *App, enabled: bool) void {
    self.runtime.playerSetCrossfeed(self.player, if (enabled) self.crossfeed_amount else null) catch
        return self.toast("Could not apply crossfeed");
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn crossfeedSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (self.sound_controls.crossfeed_amount_row) |amount|
        gtk.gtk_widget_set_sensitive(amount, if (enabled) gtk.true_ else gtk.false_);
    applyCrossfeed(self, enabled);
}

fn crossfeedAmountPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= app.crossfeed_amounts.len) return;
    self.crossfeed_amount = app.crossfeed_amounts[selected];
    applyCrossfeed(self, true);
}

fn comboRow(title: [*:0]const u8, labels: []const ?[*:0]const u8) struct { row: *gtk.Widget, names: *gtk.StringList } {
    const row = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title);
    const names = gtk.gtk_string_list_new(labels.ptr);
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, row), gtk.cast(gtk.ListModel, names));
    gtk.g_object_unref(names);
    return .{ .row = row, .names = names };
}

fn bandSliders(self: *App, curve: liborca.Equalizer) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, box), gtk.true_);
    gtk.gtk_widget_add_css_class(box, "card");
    gtk.gtk_widget_add_css_class(box, "eq-bands");
    for (band_labels, curve.gains_db, 0..) |band, gain_db, index| {
        const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
        const adjustment = gtk.gtk_adjustment_new(gain_db, -band_range_db, band_range_db, 0.5, 2, 0);
        const scale = gtk.gtk_scale_new(gtk.ORIENTATION_VERTICAL, adjustment);
        gtk.gtk_range_set_inverted(gtk.cast(gtk.Range, scale), gtk.true_);
        gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, scale), gtk.false_);
        gtk.gtk_scale_add_mark(gtk.cast(gtk.Scale, scale), 0, gtk.POS_RIGHT, null);
        gtk.gtk_widget_set_vexpand(scale, gtk.true_);
        gtk.gtk_widget_set_size_request(scale, -1, 150);
        gtk.gtk_widget_set_tooltip_text(scale, band.tooltip);
        _ = gtk.signalConnect(scale, "value-changed", gtk.callback(bandMoved), self);
        const label = gtk.gtk_label_new(band.label);
        gtk.gtk_widget_add_css_class(label, "caption");
        gtk.gtk_widget_add_css_class(label, "dim-label");
        gtk.gtk_box_append(gtk.cast(gtk.Box, column), scale);
        gtk.gtk_box_append(gtk.cast(gtk.Box, column), label);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), column);
        self.sound_controls.band_scales[index] = scale;
    }
    return box;
}

/// Shows the editor of `mode`, or the last one shown when the equalizer is
/// off, so its controls stay where they were, insensitive.
fn showEqualizerMode(self: *App, mode: parametric.Mode) void {
    const controls = &self.sound_controls;
    switch (mode) {
        .graphic => self.parametric.view = .graphic,
        .parametric => self.parametric.view = .parametric,
        .off => {},
    }
    const view = self.parametric.view;
    if (controls.graphic) |group| gtk.gtk_widget_set_visible(group, @intFromBool(view == .graphic));
    if (self.parametric.controls.root) |root| {
        gtk.gtk_widget_set_visible(root, @intFromBool(view == .parametric));
        gtk.gtk_widget_set_sensitive(root, @intFromBool(mode == .parametric));
    }
    showEqualizerEnabled(self, mode == .graphic);
}

/// Brings the Equalizer card in line with an equalizer changed elsewhere, as
/// a device's preset does when the output changes.
pub fn showEqualizer(self: *App) void {
    const mode = parametric.currentMode(self);
    const previous = self.suppress_sound_signals;
    self.suppress_sound_signals = true;
    defer self.suppress_sound_signals = previous;
    for (self.sound_controls.mode_buttons, std.enums.values(parametric.Mode)) |maybe_button, candidate| {
        const button = maybe_button orelse continue;
        if (candidate == mode) gtk.gtk_toggle_button_set_active(button, gtk.true_);
    }
    showEqualizerMode(self, mode);
}

fn modeToggled(self: *App, toggle: ?*anyopaque, mode: parametric.Mode) void {
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, toggle)) == 0) return;
    if (self.suppress_sound_signals) return;
    cancelEqualizerTimer(self);
    showEqualizerMode(self, mode);
    parametric.setMode(self, mode, self.equalizer_curve);
}

fn offToggled(toggle: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    modeToggled(state(data), toggle, .off);
}

fn graphicToggled(toggle: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    modeToggled(state(data), toggle, .graphic);
}

fn parametricToggled(toggle: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    modeToggled(state(data), toggle, .parametric);
}

fn modeControl(self: *App, mode: parametric.Mode) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "settings-segmented");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_START);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, box), gtk.ACCESSIBLE_PROPERTY_LABEL, "Equalizer", @as(c_int, -1));
    var first: ?*gtk.ToggleButton = null;
    for ([_]struct { [*:0]const u8, parametric.Mode, gtk.GCallback }{
        .{ "Off", .off, gtk.callback(offToggled) },
        .{ "Graphic", .graphic, gtk.callback(graphicToggled) },
        .{ "Parametric", .parametric, gtk.callback(parametricToggled) },
    }) |choice| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), choice[0]);
        const toggle = gtk.cast(gtk.ToggleButton, button);
        if (first) |group| gtk.gtk_toggle_button_set_group(toggle, group) else first = toggle;
        gtk.gtk_toggle_button_set_active(toggle, @intFromBool(choice[1] == mode));
        self.sound_controls.mode_buttons[@backingInt(choice[1])] = toggle;
        _ = gtk.signalConnect(button, "toggled", choice[2], self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
}

fn soundTab(self: *App) *gtk.Widget {
    const controls = &self.sound_controls;

    const current = self.runtime.playerEqualizer(self.player) catch null;
    if (current) |curve| self.equalizer_curve = curve;
    if (self.runtime.playerParametricEqualizer(self.player) catch null) |curve| self.parametric.curve = curve;
    const curve = self.equalizer_curve;
    const mode = parametric.currentMode(self);

    const equalizer = flatCard("orca-pulse-symbolic", "Equalizer", "Runs in 32-bit float before output. Shows up in Signal Path.");
    gtk.gtk_widget_add_css_class(equalizer.widget, "eq-card");
    controls.graphic = equalizer.group;
    gtk.gtk_box_append(gtk.cast(gtk.Box, equalizer.body), modeControl(self, mode));
    controls.equalizer_header = equalizer.body;
    stackEqualizerHeader(self);

    const preset = comboRow("Preset", &preset_labels);
    controls.preset_row = preset.row;
    controls.preset_names = preset.names;
    showPreset(self, matchingPreset(curve));
    equalizer.add(preset.row);

    controls.bands = bandSliders(self, curve);
    equalizer.add(controls.bands.?);

    const preamp = adw.adw_spin_row_new_with_range(preamp_range_db[0], preamp_range_db[1], 0.5);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, preamp), "Preamp");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, preamp), "Decibels. Lower it if boosted bands distort");
    adw.adw_spin_row_set_digits(gtk.cast(adw.SpinRow, preamp), 1);
    controls.preamp_row = preamp;
    showCurve(self, curve);
    equalizer.add(preamp);

    gtk.gtk_box_append(gtk.cast(gtk.Box, equalizer.widget), parametric.build(self));
    showEqualizerMode(self, mode);

    _ = gtk.signalConnect(preset.row, "notify::selected", gtk.callback(presetChanged), self);
    _ = gtk.signalConnect(preamp, "notify::value", gtk.callback(preampChanged), self);

    const view = tab(self, .sound, null, &.{equalizer.widget}, &.{ devicePresetsCard(self), crossfeedCard(self) });
    _ = gtk.signalConnect(view, "map", gtk.callback(soundMapped), self);
    return view;
}

fn soundMapped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    transport.refreshDevices(state(data));
}

const device_index_key = "orca-settings-device";

fn devicePresetPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    const index = @intFromPtr(gtk.g_object_get_data(drop_down.?, device_index_key)) - 1;
    if (index >= self.device_names.items.len) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (!parametric.setDevicePreset(self, self.device_names.items[index], parametric.devicePresetChoice(self, selected)))
        return self.toast("Could not keep a preset for this device");
    settings.save(self);
}

fn switchPresetSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.parametric.switch_with_device = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    settings.save(self);
}

fn forgetHidden(page: *app.SettingsPage, widget: *gtk.Widget) void {
    var index: usize = 0;
    while (index < page.filter_hidden_len) {
        if (page.filter_hidden[index] == widget) {
            page.filter_hidden_len -= 1;
            page.filter_hidden[index] = page.filter_hidden[page.filter_hidden_len];
        } else index += 1;
    }
}

fn devicePresetDevices(self: *App, buffer: *[app.max_device_preset_rows]usize) []usize {
    const names = self.device_names.items;
    var count: usize = 0;
    for (names, 0..) |name, index| {
        if (count == buffer.len) break;
        const shown = index == self.device_index or index == 0 or parametric.devicePreset(self, name) != null;
        if (!shown) continue;
        buffer[count] = index;
        count += 1;
    }
    const devices = buffer[0..count];
    if (self.device_index < names.len) {
        for (devices, 0..) |device, position| {
            if (device != self.device_index) continue;
            std.mem.copyBackwards(usize, devices[1 .. position + 1], devices[0..position]);
            devices[0] = device;
            break;
        }
    }
    return devices;
}

fn devicePresetRowsCurrent(self: *App, devices: []const usize) bool {
    const controls = &self.sound_controls;
    if (controls.device_switch_row == null) return false;
    if (controls.device_preset_row_count != devices.len) return false;
    for (controls.device_preset_rows[0..devices.len], devices) |maybe_row, device| {
        const row = maybe_row orelse return false;
        const title = adw.adw_preferences_row_get_title(gtk.cast(adw.PreferencesRow, row));
        if (!std.mem.eql(u8, std.mem.span(title), self.device_names.items[device])) return false;
    }
    return true;
}

/// Rows for the current output, System default and every device with a
/// preset, then the switch; rebuilt when the output or the devices change.
fn showDevicePresets(self: *App) void {
    const controls = &self.sound_controls;
    const group = gtk.cast(adw.PreferencesGroup, controls.device_presets orelse return);
    var device_buffer: [app.max_device_preset_rows]usize = undefined;
    const devices = devicePresetDevices(self, &device_buffer);
    if (devicePresetRowsCurrent(self, devices)) return;
    const page = &self.settings_page;
    page.syncing = true;
    defer page.syncing = false;
    for (controls.device_preset_rows[0..controls.device_preset_row_count]) |maybe_row| {
        const row = maybe_row orelse continue;
        forgetHidden(page, row);
        adw.adw_preferences_group_remove(group, row);
    }
    controls.device_preset_rows = @splat(null);
    controls.device_preset_row_count = 0;
    if (controls.device_switch_row) |row| {
        forgetHidden(page, row);
        adw.adw_preferences_group_remove(group, row);
    }

    var labels: [parametric.max_presets + 4]?[*:0]const u8 = undefined;
    var name_storage: [parametric.max_presets][parametric.max_name_bytes + 1]u8 = undefined;
    const choices = parametric.devicePresetLabels(self, &labels, &name_storage);
    for (devices, 0..) |device, position| {
        const name = self.device_names.items[device];
        const row = selectRow(
            name.ptr,
            "",
            choices,
            parametric.devicePresetIndex(self, parametric.devicePreset(self, name)),
            gtk.callback(devicePresetPicked),
            self,
        );
        const drop_down = adw.adw_action_row_get_activatable_widget(gtk.cast(adw.ActionRow, row)).?;
        gtk.g_object_set_data(drop_down, device_index_key, @ptrFromInt(device + 1));
        adw.adw_preferences_group_add(group, row);
        controls.device_preset_rows[position] = row;
        controls.device_preset_row_count = position + 1;
    }
    const switch_row = switchRow("Switch preset with device", "", self.parametric.switch_with_device, gtk.callback(switchPresetSwitched), self);
    adw.adw_preferences_group_add(group, switch_row);
    controls.device_switch_row = switch_row;
}

fn devicePresetsCard(self: *App) *gtk.Widget {
    const presets = flatCard("audio-headphones-symbolic", "Per-Device Presets", "Orca switches EQ when the output changes.");
    self.sound_controls.device_presets = presets.group;
    showDevicePresets(self);
    return presets.widget;
}

fn crossfeedCard(self: *App) *gtk.Widget {
    const controls = &self.sound_controls;
    const crossfeed_amount = self.runtime.playerCrossfeed(self.player) catch null;
    if (crossfeed_amount) |amount| self.crossfeed_amount = amount;
    const crossfeed = flatCard("orca-wave-symbolic", "Crossfeed", "Blends a little of each channel into the other for headphones.");
    crossfeed.add(switchRow("Crossfeed", "", crossfeed_amount != null, gtk.callback(crossfeedSwitched), self));
    const amount = selectRow("Amount", "", &amount_labels, nearestAmountIndex(self.crossfeed_amount), gtk.callback(crossfeedAmountPicked), self);
    gtk.gtk_widget_set_sensitive(amount, @intFromBool(crossfeed_amount != null));
    controls.crossfeed_amount_row = amount;
    crossfeed.add(amount);
    return crossfeed.widget;
}

pub fn showAudioInformation(self: *App, maybe_path: ?liborca.SignalPath) void {
    parametric.showRate(self, maybe_path);
}

const token_settings_url = "https://listenbrainz.org/settings/";
const secret_capacity = 256;

fn scrobblingSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.scrobbling) return;
    self.runtime.librarySetScrobbling(library, enabled, false, self.announce_now_playing) catch {
        self.toast("Could not change listen submission");
        const previous = if (self.scrobbling) gtk.true_ else gtk.false_;
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), previous);
        return;
    };
    self.scrobbling = enabled;
    if (self.listening_controls.now_playing_row) |now_playing|
        gtk.gtk_widget_set_sensitive(now_playing, if (enabled) gtk.true_ else gtk.false_);
    settings.save(self);
    self.requestTick();
}

fn lyricsFetchSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    lyrics.setFetch(state(data), adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0);
}

fn nowPlayingSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.announce_now_playing) return;
    self.runtime.librarySetScrobbling(library, self.scrobbling, false, enabled) catch {
        self.toast("Could not change what is shared while playing");
        const previous = if (self.announce_now_playing) gtk.true_ else gtk.false_;
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), previous);
        return;
    };
    self.announce_now_playing = enabled;
    settings.save(self);
    self.requestTick();
}

const Credential = struct {
    service: [:0]const u8,
    account: [:0]const u8,
    keyring_label: [:0]const u8,
    row_title: [*:0]const u8,
    open_label: [*:0]const u8,
    replace_label: ?[*:0]const u8,
    remove_label: [*:0]const u8,
    stored_subtitle: [*:0]const u8,
    title: [*:0]const u8,
    replace_title: [*:0]const u8,
    locked_subtitle: [*:0]const u8,
    too_long: [:0]const u8,
    saved: [:0]const u8,
    removed: [:0]const u8,
    store_failed: [:0]const u8,
    remove_failed: [:0]const u8,
    first_check: secret.LockedItems,
    controls: *const fn (*App) *app.CredentialControls,
    changed: *const fn (*App) void,
    checked: *const fn (*App, secret.Presence) void,
    add_title: [*:0]const u8,
    absent_subtitle: [*:0]const u8,
    hint: [*:0]const u8,
    reveal_label: [*:0]const u8,
};

fn listenBrainzControls(self: *App) *app.CredentialControls {
    return &self.listening_controls.token;
}

fn listenBrainzTokenChanged(self: *App) void {
    if (self.library) |library| self.runtime.libraryScrobblerCredentialsChanged(library) catch {};
    self.requestTick();
}

fn listenBrainzChecked(self: *App, _: secret.Presence) void {
    showAccount(self);
}

const listenbrainz_token: Credential = .{
    .service = listenbrainz_token_service,
    .account = listenbrainz_token_account,
    .keyring_label = "Orca ListenBrainz user token",
    .row_title = "Account",
    .open_label = "Connect…",
    .replace_label = null,
    .remove_label = "Disconnect",
    .stored_subtitle = "Saved in your keyring",
    .title = "User token",
    .replace_title = "Replace token",
    .add_title = "Paste your user token",
    .absent_subtitle = "Not connected · token from <a href=\"" ++ token_settings_url ++ "\">listenbrainz.org↗</a>",
    .hint = "Paste a new token and click Save",
    .reveal_label = "Show token",
    .locked_subtitle = "Keyring locked — unlock it to use your saved token",
    .too_long = "That is too long to be a ListenBrainz token",
    .saved = "Token saved",
    .removed = "Token removed",
    .store_failed = "Could not store the token in the system keyring",
    .remove_failed = "Could not remove the token from the system keyring",
    .first_check = .unlock,
    .controls = listenBrainzControls,
    .changed = listenBrainzTokenChanged,
    .checked = listenBrainzChecked,
};

fn acoustIdControls(self: *App) *app.CredentialControls {
    return &self.acoustid_controls;
}

fn acoustIdKeyChanged(_: *App) void {}

const acoustid_user_key: Credential = .{
    .service = liborca.acoustid_credential_service,
    .account = liborca.acoustid_user_key_account,
    .keyring_label = "Orca AcoustID user key",
    .row_title = "AcoustID key",
    .open_label = "Add…",
    .replace_label = "Replace…",
    .remove_label = "Remove",
    .stored_subtitle = "Saved in your keyring · " ++ acoustid_key_link,
    .title = "Your AcoustID key",
    .replace_title = "Replace key",
    .add_title = "Add key",
    .absent_subtitle = "No key saved · " ++ acoustid_key_link,
    .hint = "Paste a new key and click Save",
    .reveal_label = "Show key",
    .locked_subtitle = "Keyring locked — unlock it to use your saved key",
    .too_long = "That is too long to be an AcoustID key",
    .saved = "Key saved",
    .removed = "Key removed",
    .store_failed = "Could not store the key in the system keyring",
    .remove_failed = "Could not remove the key from the system keyring",
    .first_check = .report,
    .controls = acoustIdControls,
    .changed = acoustIdKeyChanged,
    .checked = submissions.keyChecked,
};

fn CredentialRows(comptime credential: Credential) type {
    return struct {
        fn typed(controls: *const app.CredentialControls) []const u8 {
            const row = controls.entry_row orelse return "";
            const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, row)));
            return std.mem.trim(u8, text, " \t\r\n");
        }

        fn showSaveSensitivity(self: *App) void {
            const controls = credential.controls(self);
            const save_button = controls.save_button orelse return;
            const ready = !controls.saving and typed(controls).len != 0;
            gtk.gtk_widget_set_sensitive(save_button, if (ready) gtk.true_ else gtk.false_);
        }

        fn setSaving(self: *App, saving: bool) void {
            const controls = credential.controls(self);
            controls.saving = saving;
            if (controls.entry_row) |row| gtk.gtk_widget_set_sensitive(row, if (saving) gtk.false_ else gtk.true_);
            showSaveSensitivity(self);
        }

        fn showPresence(self: *App, presence: secret.Presence) void {
            const controls = credential.controls(self);
            const stored_row = controls.stored_row orelse return;
            const is_stored = presence == .stored;
            controls.stored = is_stored;
            const subtitle: [*:0]const u8 = switch (presence) {
                .absent => credential.absent_subtitle,
                .stored => credential.stored_subtitle,
                .locked => credential.locked_subtitle,
                .unavailable => "Could not reach the system keyring",
            };
            adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, stored_row), subtitle);
            if (controls.remove_button) |button| {
                gtk.gtk_widget_set_visible(button, @intFromBool(is_stored));
                gtk.gtk_widget_set_sensitive(button, gtk.true_);
            }
            if (controls.unlock_button) |button|
                gtk.gtk_widget_set_visible(button, @intFromBool(presence == .locked));
            if (controls.open_button) |button| {
                const label = if (is_stored) credential.replace_label else credential.open_label;
                gtk.gtk_widget_set_visible(button, @intFromBool(label != null and (presence == .absent or is_stored)));
                if (label) |text| gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), text);
            }
            if (controls.entry_box) |box| if (presence != .absent and !is_stored) gtk.gtk_widget_set_visible(box, gtk.false_);
            const entry_title = if (is_stored) credential.replace_title else credential.add_title;
            if (controls.entry_title) |label| gtk.gtk_label_set_text(label, entry_title);
        }

        fn presenceFound(presence: secret.Presence, data: ?*anyopaque) void {
            const self = state(data);
            showPresence(self, presence);
            credential.checked(self, presence);
        }

        fn check(self: *App, locked_items: secret.LockedItems) void {
            secret.check(credential.service, credential.account, locked_items, presenceFound, self) catch
                self.toast("Could not check the system keyring");
        }

        fn stored(succeeded: bool, data: ?*anyopaque) void {
            const self = state(data);
            setSaving(self, false);
            if (!succeeded) return self.toast(credential.store_failed);
            const controls = credential.controls(self);
            if (controls.reveal_button) |button| gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), gtk.false_);
            if (controls.entry_row) |row| gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, row), "");
            if (controls.entry_box) |box| gtk.gtk_widget_set_visible(box, gtk.false_);
            credential.changed(self);
            self.toast(credential.saved);
            check(self, credential.first_check);
        }

        fn removed(succeeded: bool, data: ?*anyopaque) void {
            const self = state(data);
            if (!succeeded) {
                if (credential.controls(self).remove_button) |button| gtk.gtk_widget_set_sensitive(button, gtk.true_);
                return self.toast(credential.remove_failed);
            }
            credential.changed(self);
            self.toast(credential.removed);
            check(self, credential.first_check);
        }

        fn save(self: *App) void {
            const controls = credential.controls(self);
            if (controls.saving) return;
            var buffer: [secret_capacity:0]u8 = undefined;
            defer std.crypto.secureZero(u8, &buffer);
            const text = typed(controls);
            if (text.len == 0) return;
            if (text.len >= buffer.len) return self.toast(credential.too_long);
            @memcpy(buffer[0..text.len], text);
            buffer[text.len] = 0;
            secret.save(credential.service, credential.account, credential.keyring_label, &buffer, stored, self) catch
                return self.toast("Out of memory");
            setSaving(self, true);
        }

        fn saveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            save(state(data));
        }

        fn entryActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            save(state(data));
        }

        fn entryTyped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            showSaveSensitivity(state(data));
        }

        fn removeClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            const self = state(data);
            secret.clear(credential.service, credential.account, removed, self) catch
                return self.toast("Out of memory");
            gtk.gtk_widget_set_sensitive(gtk.cast(gtk.Widget, button), gtk.false_);
        }

        fn unlockClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            check(state(data), .unlock);
        }

        fn openClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            const controls = credential.controls(state(data));
            const box = controls.entry_box orelse return;
            const shown = gtk.gtk_widget_get_visible(box) == gtk.false_;
            gtk.gtk_widget_set_visible(box, @intFromBool(shown));
            if (shown) if (controls.entry_row) |entry| {
                _ = gtk.gtk_widget_grab_focus(entry);
            };
        }

        fn checkOnce(self: *App) void {
            const controls = credential.controls(self);
            if (controls.checked) return;
            controls.checked = true;
            check(self, credential.first_check);
        }

        fn forget(self: *App) void {
            const controls = credential.controls(self);
            controls.checked = false;
            if (controls.reveal_button) |button| gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), gtk.false_);
            if (controls.entry_row) |row| gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, row), "");
            if (controls.entry_box) |box| gtk.gtk_widget_set_visible(box, gtk.false_);
        }

        fn add(self: *App, target: Card) void {
            const stored_row = actionRow(credential.row_title, credential.absent_subtitle);
            const open_button = suffixButton(stored_row, credential.open_label, null, gtk.callback(openClicked), self);
            const remove_button = suffixButton(stored_row, credential.remove_label, null, gtk.callback(removeClicked), self);
            gtk.gtk_widget_set_visible(remove_button, gtk.false_);
            const unlock_button = suffixButton(stored_row, "Unlock", null, gtk.callback(unlockClicked), self);
            gtk.gtk_widget_set_visible(unlock_button, gtk.false_);
            target.add(stored_row);
            addEntry(self, target, stored_row, open_button, remove_button, unlock_button);
        }

        fn revealToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            const self = state(data);
            const entry = credential.controls(self).entry_row orelse return;
            const shown = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button));
            gtk.gtk_entry_set_visibility(gtk.cast(gtk.Entry, entry), shown);
            gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), if (shown != 0) "view-conceal-symbolic" else "view-reveal-symbolic");
        }

        fn addEntry(self: *App, target: Card, stored_row: *gtk.Widget, open_button: *gtk.Widget, remove_button: *gtk.Widget, unlock_button: *gtk.Widget) void {
            const row = gtk.gtk_list_box_row_new();
            gtk.gtk_widget_set_visible(row, gtk.false_);
            gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, row), gtk.false_);
            gtk.gtk_widget_set_focusable(row, gtk.false_);
            gtk.gtk_widget_add_css_class(row, "settings-entry-row");
            const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
            const title = gtk.gtk_label_new(credential.add_title);
            gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0);
            gtk.gtk_widget_add_css_class(title, "settings-entry-title");
            const hint = gtk.gtk_label_new(credential.hint);
            gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, hint), 0);
            gtk.gtk_widget_add_css_class(hint, "dim-label");
            gtk.gtk_widget_add_css_class(hint, "caption");
            const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
            const entry = gtk.gtk_entry_new();
            gtk.gtk_entry_set_visibility(gtk.cast(gtk.Entry, entry), gtk.false_);
            gtk.gtk_widget_set_hexpand(entry, gtk.true_);
            gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, entry), gtk.ACCESSIBLE_PROPERTY_LABEL, credential.title, @as(c_int, -1));
            _ = gtk.signalConnect(entry, "activate", gtk.callback(entryActivated), self);
            _ = gtk.signalConnect(entry, "changed", gtk.callback(entryTyped), self);
            const reveal = gtk.gtk_toggle_button_new();
            gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, reveal), "view-reveal-symbolic");
            gtk.gtk_widget_set_tooltip_text(reveal, credential.reveal_label);
            gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, reveal), gtk.ACCESSIBLE_PROPERTY_LABEL, credential.reveal_label, @as(c_int, -1));
            _ = gtk.signalConnect(reveal, "toggled", gtk.callback(revealToggled), self);
            const save_button = gtk.gtk_button_new_with_label("Save");
            gtk.gtk_widget_add_css_class(save_button, "suggested-action");
            gtk.gtk_widget_set_sensitive(save_button, gtk.false_);
            _ = gtk.signalConnect(save_button, "clicked", gtk.callback(saveClicked), self);
            gtk.gtk_box_append(gtk.cast(gtk.Box, line), entry);
            gtk.gtk_box_append(gtk.cast(gtk.Box, line), reveal);
            gtk.gtk_box_append(gtk.cast(gtk.Box, line), save_button);
            gtk.gtk_box_append(gtk.cast(gtk.Box, content), title);
            gtk.gtk_box_append(gtk.cast(gtk.Box, content), hint);
            gtk.gtk_box_append(gtk.cast(gtk.Box, content), line);
            gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), content);
            target.add(row);

            credential.controls(self).* = .{
                .entry_row = entry,
                .entry_box = row,
                .open_button = open_button,
                .entry_title = gtk.cast(gtk.Label, title),
                .reveal_button = reveal,
                .save_button = save_button,
                .stored_row = stored_row,
                .remove_button = remove_button,
                .unlock_button = unlock_button,
            };
        }
    };
}

const ListenBrainzToken = CredentialRows(listenbrainz_token);
const AcoustIdKey = CredentialRows(acoustid_user_key);

fn listeningMapped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    ListenBrainzToken.checkOnce(state(data));
}

fn plural(count: u64, comptime singular: []const u8, comptime many: []const u8) []const u8 {
    return if (count == 1) singular else many;
}

fn setSubtitle(row: *gtk.Widget, text: [:0]const u8) void {
    const action_row = gtk.cast(adw.ActionRow, row);
    if (adw.adw_action_row_get_subtitle(action_row)) |current|
        if (std.mem.eql(u8, std.mem.span(current), text)) return;
    adw.adw_action_row_set_subtitle(action_row, text.ptr);
}

fn pendingSubtitle(buffer: []u8, status: liborca.ScrobblerStatus) [:0]const u8 {
    const waiting: []const u8 = switch (status.state) {
        .rate_limited => "Waiting — ListenBrainz asked us to slow down",
        .backing_off => "Waiting — ListenBrainz could not be reached",
        .busy => "Waiting — another Orca process is sending",
        .offline => "Offline",
        .invalid_token => "Waiting for a working token",
        else => "Queued while offline",
    };
    if (status.feedback_pending == 0) return strings.terminated(buffer, waiting);
    return strings.format(buffer, "{s} · {d} {s} to sync", .{
        waiting,
        status.feedback_pending,
        plural(status.feedback_pending, "love or dislike", "loves and dislikes"),
    });
}

fn showAccount(self: *App) void {
    const controls = &self.listening_controls.token;
    if (!controls.stored) return;
    const row = controls.stored_row orelse return;
    const library = self.library orelse return;
    const status = self.runtime.libraryScrobblerStatus(library) catch return;
    var buffer: [256]u8 = undefined;
    const user = status.user_name.slice();
    const text: [:0]const u8 = if (status.state == .invalid_token)
        "Token rejected"
    else if (user.len != 0) text: {
        var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        writer.writeAll("Connected as ") catch {};
        writeEscaped(&writer, user) catch {};
        buffer[writer.end] = 0;
        break :text buffer[0..writer.end :0];
    } else "Saved in your keyring";
    setSubtitle(row, text);
}

fn showListeningStatus(self: *App) void {
    showAccount(self);
    const row = self.listening_controls.pending_row orelse return;
    const library = self.library orelse return;
    const status = self.runtime.libraryScrobblerStatus(library) catch return;
    var buffer: [192]u8 = undefined;
    setSubtitle(row, pendingSubtitle(&buffer, status));
    if (self.listening_controls.pending_value) |label| {
        var value_buffer: [48]u8 = undefined;
        const value = strings.format(&value_buffer, "{f} {s}", .{ strings.grouped(status.pending), plural(status.pending, "listen", "listens") });
        if (!std.mem.eql(u8, std.mem.span(gtk.gtk_label_get_text(label)), value)) gtk.gtk_label_set_text(label, value.ptr);
    }
}

pub fn tick(self: *App) void {
    if (self.settings_page.tabs == null or self.current_page != .settings) return;
    showListeningStatus(self);
    showWatchStatus(self);
    showMaintenanceStatus(self);
    showTransitions(self);
}

const listen_policies = [_]liborca.ListenPolicy{ .half_or_four_minutes, .thirty_seconds, .full_track };

fn recordingSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    self.runtime.librarySetListenRecording(library, enabled) catch {
        self.toast("Could not change listening history");
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), @intFromBool(!enabled));
    };
    home_page.reload(self);
}

fn policyPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= listen_policies.len) return;
    self.runtime.librarySetListenPolicy(library, listen_policies[selected]) catch
        self.toast("Could not change when a play counts");
}

fn clearHistory(self: *App) void {
    const library = self.library orelse return;
    const cleared = self.runtime.libraryClearListens(library) catch return self.toast("Could not clear the listening history");
    var buffer: [64]u8 = undefined;
    self.toast(strings.format(&buffer, "Cleared {f} {s}", .{ strings.grouped(cleared), plural(cleared, "listen", "listens") }));
    jobs.reloadLibraryViews(self);
    self.requestTick();
}

fn clearHistoryClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    confirm(state(data), "Clear listening history?", "Ratings, loves and playlists are kept.", "Clear", clearHistory);
}

fn historyCard(self: *App) *gtk.Widget {
    const history = flatCard("orca-clock-symbolic", "Listening History", "Kept locally in Orca's database. Powers plays, last played and smart playlists.");
    const library = self.library;
    const recording = if (library) |handle| self.runtime.libraryListenRecording(handle) catch true else true;
    const keep = switchRow("Keep listening history", "", recording, gtk.callback(recordingSwitched), self);
    gtk.gtk_widget_set_sensitive(keep, @intFromBool(library != null));
    history.add(keep);
    const policy = if (library) |handle| self.runtime.libraryListenPolicy(handle) catch .half_or_four_minutes else .half_or_four_minutes;
    const count = selectRow(
        "Count a play after",
        "",
        &.{ "50% or 4 minutes", "30 seconds", "The full track", null },
        @intCast(std.mem.indexOfScalar(liborca.ListenPolicy, &listen_policies, policy) orelse 0),
        gtk.callback(policyPicked),
        self,
    );
    gtk.gtk_widget_set_sensitive(count, @intFromBool(library != null));
    history.add(count);
    history.add(valueRow("Keep history for", "", "Forever"));
    const clear = actionRow("Clear history", "Resets play counts and last played");
    const clear_button = suffixButton(clear, "Clear…", null, gtk.callback(clearHistoryClicked), self);
    gtk.gtk_widget_set_sensitive(clear_button, @intFromBool(library != null));
    history.add(clear);
    return history.widget;
}

const avoid_choices = [_]liborca.DiscoveryAvoidDays{ .three_days, .one_day, .seven_days, .none };
const mix_choices = [_]liborca.DailyMixCount{ .six, .four, .off };

fn discoverySettings(self: *App) liborca.DiscoverySettings {
    const library = self.library orelse return .{};
    return self.runtime.libraryDiscoverySettings(library) catch .{};
}

fn saveDiscoverySettings(self: *App, discovery: liborca.DiscoverySettings) void {
    const library = self.library orelse return;
    self.runtime.setLibraryDiscoverySettings(library, discovery) catch return self.toast("Could not change the Radio settings");
    radio.invalidate(self);
}

fn radioContinueSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var discovery = discoverySettings(self);
    discovery.radio_continue = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    saveDiscoverySettings(self, discovery);
}

fn radioUnplayedSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var discovery = discoverySettings(self);
    discovery.include_unplayed = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    saveDiscoverySettings(self, discovery);
}

fn radioFamiliarityChanged(scale: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const value = gtk.gtk_range_get_value(gtk.cast(gtk.Range, scale));
    var discovery = discoverySettings(self);
    const familiarity: u8 = @intFromFloat(std.math.clamp(@round(value), 0, 100));
    if (discovery.familiarity == familiarity) return;
    discovery.familiarity = familiarity;
    saveDiscoverySettings(self, discovery);
}

fn avoidPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= avoid_choices.len) return;
    var discovery = discoverySettings(self);
    discovery.avoid_days = avoid_choices[selected];
    saveDiscoverySettings(self, discovery);
}

fn mixesPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= mix_choices.len) return;
    var discovery = discoverySettings(self);
    if (discovery.mix_count == mix_choices[selected]) return;
    discovery.mix_count = mix_choices[selected];
    saveDiscoverySettings(self, discovery);
    home_page.startMixes(self, true);
}

fn homeStatsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.home_stats = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    settings.save(self);
    home_page.reload(self);
}

fn resetRecommendations(self: *App) void {
    const library = self.library orelse return;
    self.runtime.libraryResetRecommendations(library) catch return self.toast("Could not reset recommendations");
    radio.invalidate(self);
    home_page.reload(self);
    self.toast("Recommendations reset");
}

fn resetRecommendationsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    confirm(
        state(data),
        "Reset recommendations?",
        "Radio and Daily Mixes forget every “Not for me” and “Less like this”. Listening history is kept.",
        "Reset",
        resetRecommendations,
    );
}

fn radioCard(self: *App) *gtk.Widget {
    const radio_card = flatCard(
        "orca-radio-symbolic",
        "Radio & Daily Mixes",
        "Built on this computer from your library, listening history and audio analysis. Nothing is sent anywhere.",
    );
    const discovery = discoverySettings(self);
    const has_library = @intFromBool(self.library != null);
    const familiarity_row = actionRow("Play history", "How much your listening steers picks");
    const familiarity_adjustment = gtk.gtk_adjustment_new(@floatFromInt(discovery.familiarity), 0, 100, 1, 10, 0);
    const familiarity_scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, familiarity_adjustment);
    gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, familiarity_scale), gtk.false_);
    gtk.gtk_widget_set_size_request(familiarity_scale, 160, -1);
    gtk.gtk_widget_set_valign(familiarity_scale, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(familiarity_scale, "settings-scale");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, familiarity_scale), gtk.ACCESSIBLE_PROPERTY_LABEL, "Play history", @as(c_int, -1));
    _ = gtk.signalConnect(familiarity_scale, "value-changed", gtk.callback(radioFamiliarityChanged), self);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, familiarity_row), familiarity_scale);
    const library_rows = [_]*gtk.Widget{
        switchRow("Continue with Radio when the queue ends", "", discovery.radio_continue, gtk.callback(radioContinueSwitched), self),
        switchRow("Include tracks you've never played", "How often they come up follows the Play history dial", discovery.include_unplayed, gtk.callback(radioUnplayedSwitched), self),
        familiarity_row,
        selectRow(
            "Avoid tracks played in the last",
            "",
            &.{ "3 days", "1 day", "7 days", "Don't avoid", null },
            @intCast(std.mem.indexOfScalar(liborca.DiscoveryAvoidDays, &avoid_choices, discovery.avoid_days) orelse 0),
            gtk.callback(avoidPicked),
            self,
        ),
        selectRow(
            "Daily Mixes",
            "New mixes each morning",
            &.{ "6 mixes", "4 mixes", "Off", null },
            @intCast(std.mem.indexOfScalar(liborca.DailyMixCount, &mix_choices, discovery.mix_count) orelse 0),
            gtk.callback(mixesPicked),
            self,
        ),
    };
    for (library_rows) |row| {
        gtk.gtk_widget_set_sensitive(row, has_library);
        radio_card.add(row);
    }
    radio_card.add(switchRow("Show listening stats on Home", "", self.home_stats, gtk.callback(homeStatsSwitched), self));
    const reset = actionRow("Reset recommendations", "Forgets “Not for me” and “Less like this”");
    _ = suffixButton(reset, "Reset…", null, gtk.callback(resetRecommendationsClicked), self);
    gtk.gtk_widget_set_sensitive(reset, has_library);
    radio_card.add(reset);
    return radio_card.widget;
}

fn listeningTab(self: *App) *gtk.Widget {
    const listenbrainz = flatCard("orca-wave-symbolic", "ListenBrainz", "Share what you listen to with your ListenBrainz profile.");
    ListenBrainzToken.add(self, listenbrainz);

    const submit = switchRow("Submit listens", "Sent after a play counts", self.scrobbling, gtk.callback(scrobblingSwitched), self);
    gtk.gtk_widget_set_sensitive(submit, @intFromBool(self.library != null));
    listenbrainz.add(submit);

    const now_playing = switchRow("Send now playing", "", self.announce_now_playing, gtk.callback(nowPlayingSwitched), self);
    gtk.gtk_widget_set_sensitive(now_playing, @intFromBool(self.library != null and self.scrobbling));
    listenbrainz.add(now_playing);

    const pending = actionRow("Pending", "Queued while offline");
    const pending_value = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(pending_value, "settings-value");
    gtk.gtk_widget_add_css_class(pending_value, "numeric");
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, pending), pending_value);
    listenbrainz.add(pending);
    self.listening_controls.now_playing_row = now_playing;
    self.listening_controls.pending_row = pending;
    self.listening_controls.pending_value = gtk.cast(gtk.Label, pending_value);
    showListeningStatus(self);

    const lyrics_card = flatCard(
        "orca-type-symbolic",
        "Lyrics",
        "Lyrics come from .lrc files beside your tracks and from their tags. Orca never writes lyrics to a file.",
    );
    lyrics_card.add(switchRow(
        "Fetch lyrics from LRCLIB",
        "Looks lyrics up on lrclib.net by title, artist, album and duration when the files have none",
        self.lyrics.fetch,
        gtk.callback(lyricsFetchSwitched),
        self,
    ));

    const view = tab(self, .listening, null, &.{ listenbrainz.widget, lyrics_card.widget, artistInfoCard(self) }, &.{ radioCard(self), historyCard(self) });
    _ = gtk.signalConnect(view, "map", gtk.callback(listeningMapped), self);
    return view;
}

fn showChoices(self: *App) void {
    appearance.applyChoices(self);
    settings.save(self);
}

fn artworkChosen(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenSegment(button) orelse return;
    self.appearance.artwork = std.enums.fromInt(app.ArtworkInfluence, index) orelse return;
    showChoices(self);
}

fn densityChosen(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenSegment(button) orelse return;
    self.appearance.density = std.enums.fromInt(app.Density, index) orelse return;
    showChoices(self);
}

fn typefacePicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    self.appearance.display_typeface = std.enums.fromInt(app.DisplayTypeface, selected) orelse return;
    showChoices(self);
}

fn numeralsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.appearance.tabular_numerals = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    showChoices(self);
}

fn inspectorPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    self.appearance.inspector = std.enums.fromInt(app.InspectorMode, selected) orelse return;
    showChoices(self);
}

fn animationSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.appearance.reduce_animation = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    showChoices(self);
}

fn countsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.appearance.sidebar_counts = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    showChoices(self);
    main_window.refreshCounts(self);
}

const tile_settle_ms: c_uint = 400;

fn cancelTileTimer(self: *App) void {
    const page = &self.settings_page;
    if (page.tile_save_timer == 0) return;
    _ = gtk.g_source_remove(page.tile_save_timer);
    page.tile_save_timer = 0;
}

fn tileSettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.settings_page.tile_save_timer = 0;
    settings.save(self);
    return gtk.SOURCE_REMOVE;
}

pub fn setAlbumTile(self: *App, value: f64) void {
    const range = app.album_tile_range;
    const pixels: c_int = @intFromFloat(std.math.clamp(@round(value), @as(f64, @floatFromInt(range[0])), @as(f64, @floatFromInt(range[1]))));
    if (pixels == self.appearance.album_grid_tile) return;
    self.appearance.album_grid_tile = pixels;
    for ([_]?*gtk.Range{ self.album_cover_scale, self.settings_page.tile_scale }) |maybe_scale| {
        const scale = maybe_scale orelse continue;
        if (@round(gtk.gtk_range_get_value(scale)) != @as(f64, @floatFromInt(pixels)))
            gtk.gtk_range_set_value(scale, @floatFromInt(pixels));
    }
    albums.resizeGrid(self);
    cancelTileTimer(self);
    self.settings_page.tile_save_timer = gtk.g_timeout_add(tile_settle_ms, tileSettled, self);
}

fn tileMoved(scale: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setAlbumTile(state(data), gtk.gtk_range_get_value(gtk.cast(gtk.Range, scale)));
}

fn switchRow(title: [*:0]const u8, subtitle: [*:0]const u8, active: bool, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const row = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title);
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), subtitle);
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, row), 3);
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), @intFromBool(active));
    _ = gtk.signalConnect(row, "notify::active", handler, data);
    return row;
}

fn appearanceTab(self: *App) *gtk.Widget {
    const choices = self.appearance;
    const color = flatCard("orca-image-symbolic", "Color", "Artwork supplies most of Orca's color. The accent marks what's active.");
    color.add(segmentedRow(
        "Artwork influence",
        "How much album color tints the background",
        &.{ "Off", "Subtle", "Expressive" },
        @backingInt(choices.artwork),
        gtk.callback(artworkChosen),
        self,
    ));

    const typeface = flatCard("orca-type-symbolic", "Type", "");
    typeface.add(selectRow(
        "Display typeface",
        "Albums, artists, playlists and Now Playing titles",
        &.{ "Newsreader (serif)", "Same as interface", null },
        @backingInt(choices.display_typeface),
        gtk.callback(typefacePicked),
        self,
    ));
    typeface.add(switchRow("Tabular numerals in tables", "Keeps durations and values aligned", choices.tabular_numerals, gtk.callback(numeralsSwitched), self));

    const layout = flatCard("orca-grid-symbolic", "Layout", "");
    layout.add(segmentedRow("Density", "", &.{ "Comfortable", "Compact" }, @backingInt(choices.density), gtk.callback(densityChosen), self));
    const grid = actionRow("Album grid size", "Also adjustable from the Albums toolbar");
    const range = app.album_tile_range;
    const adjustment = gtk.gtk_adjustment_new(@floatFromInt(choices.album_grid_tile), @floatFromInt(range[0]), @floatFromInt(range[1]), 4, 16, 0);
    const scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, adjustment);
    gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, scale), gtk.false_);
    gtk.gtk_widget_set_size_request(scale, 160, -1);
    gtk.gtk_widget_set_valign(scale, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(scale, "settings-scale");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, scale), gtk.ACCESSIBLE_PROPERTY_LABEL, "Album grid size", @as(c_int, -1));
    _ = gtk.signalConnect(scale, "value-changed", gtk.callback(tileMoved), self);
    self.settings_page.tile_scale = gtk.cast(gtk.Range, scale);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, grid), scale);
    layout.add(grid);
    layout.add(switchRow("Show counts in sidebar", "", choices.sidebar_counts, gtk.callback(countsSwitched), self));
    layout.add(selectRow(
        "Inspector",
        "",
        &.{ "Open on selection", "Remember last state", "Always closed", null },
        @backingInt(choices.inspector),
        gtk.callback(inspectorPicked),
        self,
    ));

    const motion = flatCard("orca-wave-symbolic", "Motion", "");
    motion.add(switchRow("Reduce motion", "Removes artwork zoom and sliding panels", choices.reduce_animation, gtk.callback(animationSwitched), self));
    return tab(self, .appearance, null, &.{ color.widget, typeface.widget }, &.{ layout.widget, motion.widget });
}

fn copyText(self: *App, text: [*:0]const u8) void {
    const window = self.window orelse return;
    gtk.gdk_clipboard_set_text(gtk.gtk_widget_get_clipboard(gtk.cast(gtk.Widget, window)), text);
    self.toast("Copied");
}

const PendingConfirmation = struct {
    self: *App,
    action: *const fn (*App) void,
};

fn confirm(self: *App, heading: [*:0]const u8, body: [*:0]const u8, label: [*:0]const u8, action: *const fn (*App) void) void {
    const dialog = adw.adw_alert_dialog_new(heading, body);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "confirm", label);
    adw.adw_alert_dialog_set_response_appearance(alert, "confirm", adw.RESPONSE_DESTRUCTIVE);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    const pending = self.allocator.create(PendingConfirmation) catch return;
    pending.* = .{ .self = self, .action = action };
    _ = gtk.signalConnect(dialog, "response", gtk.callback(confirmResponse), pending);
    adw.adw_dialog_present(dialog, if (self.window) |window| gtk.cast(gtk.Widget, window) else null);
}

fn confirmResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const pending: *PendingConfirmation = @ptrCast(@alignCast(data.?));
    const self = pending.self;
    const action = pending.action;
    self.allocator.destroy(pending);
    if (std.mem.eql(u8, std.mem.span(response), "confirm")) action(self);
}

fn writeHomePath(writer: *std.Io.Writer, path: []const u8, redact: bool) std.Io.Writer.Error!void {
    const home = std.mem.trimEnd(u8, if (gtk.g_get_home_dir()) |dir| std.mem.span(dir) else "", "/");
    if (home.len != 0 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/')) {
        try writer.writeByte('~');
        return writer.writeAll(path[home.len..]);
    }
    if (!redact) return writer.writeAll(path);
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return writer.writeAll(trimmed);
    try writer.writeAll("…/");
    try writer.writeAll(trimmed[slash + 1 ..]);
}

pub fn homePath(buffer: []u8, path: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeHomePath(&writer, path, false) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn launchFolder(self: *App, path: [*:0]const u8, missing: [:0]const u8) void {
    const file = gtk.g_file_new_for_path(path);
    defer gtk.g_object_unref(file);
    if (gtk.g_file_query_exists(file, null) == 0) return self.toast(missing);
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_launch(launcher, self.window, null, folderOpened, self);
    gtk.g_object_unref(launcher);
}

fn databaseRevealed(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_file_launcher_open_containing_folder_finish(gtk.cast(gtk.FileLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open the file manager");
}

fn revealDatabaseClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const path = self.library_path orelse return;
    const file = gtk.g_file_new_for_path(path.ptr);
    defer gtk.g_object_unref(file);
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_open_containing_folder(launcher, self.window, null, databaseRevealed, self);
    gtk.g_object_unref(launcher);
}

fn openLogsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const logs = logging.directory(&buffer) orelse return self.toast("Could not find the logs folder");
    launchFolder(self, logs.ptr, "Could not find the logs folder");
}

fn licensesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var exe_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = std.process.executableDirPath(self.io, &exe_buffer) catch return self.toast("Could not find the licences");
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buffer, "{s}/../share/doc/orca/licenses", .{exe_buffer[0..length]}, 0) catch
        return self.toast("Could not find the licences");
    launchFolder(self, path.ptr, "The licences were not installed with this build");
}

fn cacheText(buffer: []u8, self: *App) [:0]const u8 {
    const library = self.library orelse return "";
    const size = self.runtime.libraryCacheSize(library) catch return "";
    const text = gtk.g_format_size(size.total());
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

fn showCache(self: *App) void {
    const label = self.settings_page.cache_value orelse return;
    var buffer: [64]u8 = undefined;
    gtk.gtk_label_set_text(label, cacheText(&buffer, self).ptr);
}

fn clearCache(self: *App) void {
    const library = self.library orelse return;
    const cleared = self.runtime.libraryClearCache(library) catch return self.toast("Could not clear the cache");
    const text = gtk.g_format_size(cleared.total());
    defer gtk.g_free(text);
    var buffer: [96]u8 = undefined;
    self.toast(strings.format(&buffer, "Cleared {s} of cached data", .{std.mem.span(text)}));
    showCache(self);
}

fn clearCacheClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    confirm(state(data), "Clear the cache?", "Fetched covers, photos, lyrics and artist info are deleted and fetched again when needed. Embedded and folder art and local lyrics stay.", "Clear Cache", clearCache);
}

fn historyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    main_window.goTo(state(data), .changes);
}

fn logLevelPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    const level = std.enums.fromInt(logging.Level, selected) orelse return;
    if (level == logging.level()) return;
    logging.setLevel(level);
    settings.save(self);
}

fn rebuildClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    confirm(
        state(data),
        "Rebuild the library database?",
        "Every file is read again from scratch. Ratings, loves, playlists and history are kept.",
        "Rebuild",
        jobs.rebuildLibrary,
    );
}

fn resetSettings(self: *App) void {
    const reorder = self.general.name_order != (app.General{}).name_order;
    if (self.general.launch_at_login) _ = autostart.set(false);
    self.general = .{};
    self.appearance = .{};
    self.playback = .{};
    const replay_gain: liborca.ReplayGainSettings = .{};
    self.runtime.playerSetReplayGainMode(self.player, replay_gain.mode) catch {};
    self.runtime.playerSetReplayGainPreamp(self.player, replay_gain.preamp_db) catch {};
    self.runtime.playerSetReplayGainFallback(self.player, .minus_6_db) catch {};
    self.runtime.playerSetPeakProtection(self.player, replay_gain.peak_protection) catch {};
    self.runtime.playerSetCrossfeed(self.player, null) catch {};
    self.crossfeed_amount = app.crossfeed_amounts[1];
    if (self.library) |library| {
        self.runtime.librarySetScrobbling(library, false, false, false) catch {};
        self.runtime.setGenreFill(library, .{}) catch {};
        self.runtime.librarySetListenPolicy(library, .half_or_four_minutes) catch {};
        self.runtime.librarySetListenRecording(library, true) catch {};
        self.runtime.setLibraryDiscoverySettings(library, .{}) catch {};
        radio.invalidate(self);
        home_page.startMixes(self, true);
    }
    self.scrobbling = false;
    self.announce_now_playing = false;
    self.home_stats = true;
    self.fetch_artist_info = true;
    self.match_threshold_percent = app.default_match_threshold_percent;
    self.match_fingerprints = true;
    self.analysis_threads = null;
    self.watch_folders = true;
    self.idle_maintenance = false;
    logging.setLevel(.info);
    lyrics.setFetch(self, false);
    parametric.setMode(self, .off, self.equalizer_curve);
    _ = watching.apply(self);
    maintenance.apply(self) catch {};
    matches.invalidate(self);
    appearance.applyChoices(self);
    albums.resizeGrid(self);
    if (reorder) {
        artists.reload(self);
        albums.reload(self);
        browse.reload(self);
    }
    settings.save(self);
    rebuildPage(self);
    self.requestTick();
    self.toast("Settings reset");
}

fn resetClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    confirm(
        state(data),
        "Reset all settings?",
        "Every preference returns to its default. Your library, ratings, loves, history, playlists and saved equalizer presets are kept.",
        "Reset",
        resetSettings,
    );
}

fn manageLibrariesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    libraries.manage(state(data));
}

fn libraryPicked(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected == gtk.INVALID_LIST_POSITION) return;
    libraries.requestSwitch(state(data), selected);
}

fn activeLibraryRow(self: *App) *gtk.Widget {
    const entries = self.libraries.entries.items;
    if (entries.len < 2) return valueRow("Active library", "", libraries.activeName(self).ptr);
    var labels: [libraries.max_entries + 1]?[*:0]const u8 = undefined;
    for (entries, 0..) |entry, index| labels[index] = entry.name.ptr;
    labels[entries.len] = null;
    const selected: c_uint = if (self.libraries.active) |active| @intCast(active) else gtk.INVALID_LIST_POSITION;
    return selectRow("Active library", "", labels[0 .. entries.len + 1], selected, gtk.callback(libraryPicked), self);
}

fn libraryProblemRow(problem: libraries.Problem) *gtk.Widget {
    const row = adw.adw_action_row_new();
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), problem.title.ptr);
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), problem.detail.ptr);
    const icon = gtk.gtk_image_new_from_icon_name("orca-alert-symbolic");
    adw.adw_action_row_add_prefix(gtk.cast(adw.ActionRow, row), icon);
    gtk.gtk_widget_add_css_class(row, "settings-problem");
    return row;
}

/// Builds the page again from current state, at once when it is shown and
/// on its next visit otherwise, for changes that alter which rows it has.
pub fn rebuildPage(self: *App) void {
    if (self.settings_page.tabs == null) return;
    teardown(self);
    if (self.current_page != .settings) return;
    show(self);
    page_ui.showWindowTitle(self);
}

fn signalPath(self: *App) ?liborca.SignalPath {
    return self.runtime.playerSignalPath(self.player) catch null;
}

fn bufferText(buffer: []u8, path: ?liborca.SignalPath) [:0]const u8 {
    const frames = (path orelse return "Set by PipeWire").device_quantum_frames orelse return "Set by PipeWire";
    return strings.format(buffer, "{f} frames · set by PipeWire", .{strings.grouped(frames)});
}

fn showBuffer(self: *App) void {
    const label = self.settings_page.buffer_value orelse return;
    var buffer: [64]u8 = undefined;
    gtk.gtk_label_set_text(label, bufferText(&buffer, signalPath(self)).ptr);
}

fn advancedTab(self: *App) *gtk.Widget {
    const engine = flatCard("orca-engine-symbolic", "Audio Engine", "Changes apply when playback restarts.");
    engine.add(valueRow("Backend", "", signal_path.audio_backend));
    const buffer_size = actionRow("Buffer size", "Larger is safer, smaller responds faster");
    self.settings_page.buffer_value = addValue(buffer_size, "");
    showBuffer(self);
    engine.add(buffer_size);
    engine.add(valueRow("Internal format", "", "32-bit float"));

    const collections = flatCard("orca-folders-symbolic", "Libraries", "Keep separate collections, each with its own database.");
    collections.add(activeLibraryRow(self));
    if (libraries.problem(self)) |problem| collections.add(libraryProblemRow(problem));
    const manage = actionRow("Libraries", "Add, rename or switch libraries");
    _ = suffixButton(manage, "Manage…", null, gtk.callback(manageLibrariesClicked), self);
    collections.add(manage);

    const storage = flatCard("orca-file-symbolic", "Storage & Logs", "");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const database = actionRow("Database", if (self.library_path) |path| homePath(&path_buffer, path).ptr else "No library open");
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, database), gtk.false_);
    const reveal = suffixButton(database, "Reveal", null, gtk.callback(revealDatabaseClicked), self);
    gtk.gtk_widget_set_sensitive(reveal, @intFromBool(self.library_path != null));
    storage.add(database);

    const cache = actionRow("Artwork &amp; analysis cache", "Rebuilt automatically when cleared");
    var cache_buffer: [64]u8 = undefined;
    const cache_value = gtk.gtk_label_new(cacheText(&cache_buffer, self).ptr);
    gtk.gtk_widget_add_css_class(cache_value, "settings-value");
    gtk.gtk_widget_add_css_class(cache_value, "numeric");
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, cache), cache_value);
    self.settings_page.cache_value = gtk.cast(gtk.Label, cache_value);
    const clear = suffixButton(cache, "Clear Cache…", null, gtk.callback(clearCacheClicked), self);
    gtk.gtk_widget_set_sensitive(clear, @intFromBool(self.library != null));
    storage.add(cache);

    const history = actionRow("Operation history", "Every change Orca made to your files, with undo");
    _ = suffixButton(history, "View…", null, gtk.callback(historyClicked), self);
    storage.add(history);
    storage.add(selectRow("Log level", "", &.{ "Info", "Debug", "Trace", null }, @backingInt(logging.level()), gtk.callback(logLevelPicked), self));

    const reset = flatCard("orca-refresh-symbolic", "Reset", "Ratings, loves and history are always kept.");
    const rebuild = actionRow("Rebuild library database", "Rescans every file from scratch");
    const rebuild_button = suffixButton(rebuild, "Rebuild…", null, gtk.callback(rebuildClicked), self);
    gtk.gtk_widget_set_sensitive(rebuild_button, @intFromBool(self.library != null));
    reset.add(rebuild);
    const reset_all = actionRow("Reset all settings", "Returns every preference to its default");
    _ = suffixButton(reset_all, "Reset…", null, gtk.callback(resetClicked), self);
    reset.add(reset_all);

    return tab(self, .advanced, null, &.{ engine.widget, collections.widget, sourcesCard(self) }, &.{ storage.widget, reset.widget });
}

fn osName(buffer: []u8, self: *App) []const u8 {
    for ([_][]const u8{ "/etc/os-release", "/usr/lib/os-release" }) |path| {
        const text = std.Io.Dir.cwd().readFile(self.io, path, buffer) catch continue;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const value = std.mem.cutPrefix(u8, line, "PRETTY_NAME=") orelse continue;
            const name = std.mem.trim(u8, value, "\"'");
            if (name.len != 0) return name;
        }
    }
    return "Linux";
}

fn writeOs(writer: *std.Io.Writer, self: *App) std.Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    try writer.print("{s} {t}", .{ osName(&buffer, self), builtin.cpu.arch });
}

fn writeDevice(writer: *std.Io.Writer, self: *App, path: ?liborca.SignalPath) std.Io.Writer.Error!void {
    try writer.writeAll(transport.deviceName(self));
    const output = (path orelse return).output orelse return;
    try writer.writeAll(" · ");
    try signal_path.writeBitDepth(writer, output);
    try writer.writeAll(" · ");
    try signal_path.writeRate(writer, output.sample_rate);
}

fn writeDsp(writer: *std.Io.Writer, maybe_path: ?liborca.SignalPath) std.Io.Writer.Error!void {
    const path = maybe_path orelse return writer.writeAll("unknown");
    var stages: usize = 0;
    if (path.replay_gain_db) |decibels| {
        const sign: []const u8 = if (decibels < 0) signal_path.minus else "+";
        const source: []const u8 = switch (path.replay_gain_source) {
            .none => "untagged",
            .track, .track_fallback => "track",
            .album => "album",
        };
        try writer.print("replaygain({s} {s}{d:.1} dB)", .{ source, sign, @abs(decibels) });
        stages += 1;
    }
    if (path.equalizer != null) {
        if (stages != 0) try writer.writeAll(", ");
        try writer.writeAll("eq");
        stages += 1;
    }
    if (path.parametric) |curve| {
        if (stages != 0) try writer.writeAll(", ");
        try writer.print("peq({d})", .{curve.count});
        stages += 1;
    }
    if (path.crossfeed != null) {
        if (stages != 0) try writer.writeAll(", ");
        try writer.writeAll("crossfeed");
        stages += 1;
    }
    if (stages == 0) try writer.writeAll("none");
}

fn libraryStats(self: *App) ?liborca.LibraryStats {
    const library = self.library orelse return null;
    return self.runtime.libraryStats(library) catch null;
}

fn writeDiagnostics(writer: *std.Io.Writer, self: *App, stats: ?liborca.LibraryStats) std.Io.Writer.Error!void {
    const path = signalPath(self);
    try writer.print("{s: <11}{f} (liborca {f})\n", .{ "orca", liborca.version, liborca.version });
    try writer.print("{s: <11}", .{"os"});
    try writeOs(writer, self);
    try writer.print("\n{s: <11}{s}\n{s: <11}", .{ "backend", signal_path.audio_backend, "device" });
    try writeDevice(writer, self, path);
    try writer.print("\n{s: <11}f32 · buffer ", .{"engine"});
    if (if (path) |value| value.device_quantum_frames else null) |frames| try writer.print("{d}", .{frames}) else try writer.writeAll("unknown");
    try writer.print(" · resampler off\n{s: <11}", .{"dsp"});
    try writeDsp(writer, path);
    try writer.print("\n{s: <11}", .{"library"});
    if (self.library == null) {
        try writer.writeAll("none open");
    } else if (stats) |value| {
        try writer.print("{f} tracks · {f} albums", .{ strings.grouped(value.tracks), strings.grouped(value.releases) });
    } else try writer.writeAll("unavailable");
    try writer.print("\n{s: <11}", .{"database"});
    if (self.library_path) |database| try writeHomePath(writer, database, true) else try writer.writeAll("none");
    try writer.print("\n{s: <11}redacted", .{"paths"});
}

fn diagnosticsText(buffer: []u8, self: *App, stats: ?liborca.LibraryStats) [:0]const u8 {
    var raw: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&raw);
    writeDiagnostics(&writer, self, stats) catch {};
    const text = raw[0..writer.end];
    const user = std.mem.span(gtk.g_get_user_name());
    var output = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var rest = text;
    while (user.len >= 2) {
        const index = std.mem.indexOf(u8, rest, user) orelse break;
        output.writeAll(rest[0..index]) catch break;
        output.writeAll("[user]") catch break;
        rest = rest[index + user.len ..];
    }
    output.writeAll(rest) catch {};
    buffer[output.end] = 0;
    return buffer[0..output.end :0];
}

fn copyDiagnosticsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var buffer: [4096]u8 = undefined;
    copyText(self, diagnosticsText(&buffer, self, libraryStats(self)).ptr);
}

fn aboutButton(label: [*:0]const u8, icon: ?[*:0]const u8, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const button = if (icon) |name| labelledButton(label, name, handler, data) else button: {
        const plain = gtk.gtk_button_new_with_label(label);
        _ = gtk.signalConnect(plain, "clicked", handler, data);
        break :button plain;
    };
    gtk.gtk_widget_add_css_class(button, "about-action");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

fn aboutHeader(self: *App) *gtk.Widget {
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(header, "about-header");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    const wordmark = gtk.gtk_label_new("Orca");
    gtk.gtk_widget_add_css_class(wordmark, "about-wordmark");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, wordmark), 0);
    var buffer: [128]u8 = undefined;
    const meta = gtk.gtk_label_new(strings.format(&buffer, "Version {f} · liborca {f} · Linux {t}", .{ liborca.version, liborca.version, builtin.cpu.arch }).ptr);
    gtk.gtk_widget_add_css_class(meta, "about-meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), wordmark);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), meta);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), text);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(actions, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), aboutButton("Open Logs", "orca-file-symbolic", gtk.callback(openLogsClicked), self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), aboutButton("Licenses", null, gtk.callback(licensesClicked), self));
    const copy = aboutButton("Copy Diagnostics", "edit-copy-symbolic", gtk.callback(copyDiagnosticsClicked), self);
    gtk.gtk_widget_add_css_class(copy, "suggested-action");
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), copy);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), actions);
    self.settings_page.about_header = header;
    stackAboutHeader(self);
    return header;
}

const Facts = struct {
    section: Card,
    grid: *gtk.Grid,
    rows: c_int = 0,

    fn init(icon: [*:0]const u8, title: [*:0]const u8) Facts {
        const section = flatCard(icon, title, "");
        gtk.gtk_widget_add_css_class(section.widget, "about-card");
        const grid = gtk.gtk_grid_new();
        gtk.gtk_widget_add_css_class(grid, "about-facts");
        gtk.gtk_grid_set_column_spacing(gtk.cast(gtk.Grid, grid), 24);
        gtk.gtk_grid_set_row_spacing(gtk.cast(gtk.Grid, grid), 6);
        gtk.gtk_box_append(gtk.cast(gtk.Box, section.widget), grid);
        gtk.gtk_widget_set_visible(section.group, gtk.false_);
        return .{ .section = section, .grid = gtk.cast(gtk.Grid, grid) };
    }

    fn add(facts: *Facts, key: [*:0]const u8, value: [*:0]const u8) *gtk.Label {
        const key_label = gtk.gtk_label_new(key);
        gtk.gtk_widget_add_css_class(key_label, "about-key");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, key_label), 0);
        gtk.gtk_widget_set_size_request(key_label, 140, -1);
        const value_label = gtk.gtk_label_new(value);
        gtk.gtk_widget_add_css_class(value_label, "about-value");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value_label), 0);
        gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, value_label), gtk.true_);
        gtk.gtk_label_set_selectable(gtk.cast(gtk.Label, value_label), gtk.true_);
        gtk.gtk_widget_set_hexpand(value_label, gtk.true_);
        gtk.gtk_grid_attach(facts.grid, key_label, 0, facts.rows, 1, 1);
        gtk.gtk_grid_attach(facts.grid, value_label, 1, facts.rows, 1, 1);
        facts.rows += 1;
        return gtk.cast(gtk.Label, value_label);
    }
};

fn deviceFormatsText(buffer: []u8, self: *App) [:0]const u8 {
    const capabilities = transport.deviceCapabilities(self) orelse return "Not reported by the device";
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll(signal_path.device_supports_source ++ " · ") catch {};
    const start = writer.end;
    signal_path.writeDeviceSupports(&writer, capabilities) catch {};
    if (writer.end == start) return "Not reported by the device";
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn formatsCard() *gtk.Widget {
    const section = flatCard("", "Supported formats", "");
    gtk.gtk_widget_add_css_class(section.widget, "about-card");
    if (gtk.gtk_widget_get_first_child(section.header)) |icon| gtk.gtk_widget_set_visible(icon, gtk.false_);
    gtk.gtk_widget_set_visible(section.group, gtk.false_);
    const chips = adw.adw_wrap_box_new();
    const wrap = gtk.cast(adw.WrapBox, chips);
    adw.adw_wrap_box_set_child_spacing(wrap, 8);
    adw.adw_wrap_box_set_line_spacing(wrap, 8);
    gtk.gtk_widget_add_css_class(chips, "about-formats");
    for (liborca.supported_formats) |format| {
        var buffer: [48]u8 = undefined;
        const text = if (format.planned)
            strings.format(&buffer, "{s} (planned)", .{format.name})
        else
            strings.terminated(&buffer, format.name);
        const chip = gtk.gtk_label_new(text.ptr);
        gtk.gtk_widget_add_css_class(chip, "about-chip");
        adw.adw_wrap_box_append(wrap, chip);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, section.widget), chips);
    return section.widget;
}

fn diagnosticsCard(self: *App) *gtk.Widget {
    const section = flatCard("", "Diagnostics preview", "");
    gtk.gtk_widget_add_css_class(section.widget, "about-card");
    if (gtk.gtk_widget_get_first_child(section.header)) |icon| gtk.gtk_widget_set_visible(icon, gtk.false_);
    gtk.gtk_widget_set_visible(section.group, gtk.false_);
    const aside = gtk.gtk_label_new("What Copy Diagnostics includes");
    gtk.gtk_widget_add_css_class(aside, "about-aside");
    gtk.gtk_widget_set_valign(aside, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section.body), aside);
    const preview = gtk.gtk_label_new("");
    self.settings_page.diagnostics = gtk.cast(gtk.Label, preview);
    gtk.gtk_widget_add_css_class(preview, "mono");
    gtk.gtk_widget_add_css_class(preview, "about-diagnostics");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, preview), 0);
    gtk.gtk_label_set_selectable(gtk.cast(gtk.Label, preview), gtk.true_);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, preview), gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section.widget), preview);
    const footer = gtk.gtk_label_new("File paths and account names are removed before copying.");
    gtk.gtk_widget_add_css_class(footer, "about-footnote");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, footer), 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section.widget), footer);
    return section.widget;
}

fn showAbout(self: *App) void {
    const page = &self.settings_page;
    if (page.contents[@backingInt(app.SettingsTab.about)] == null) return;
    if (page.about_device) |label| gtk.gtk_label_set_text(label, transport.deviceName(self).ptr);
    var text_buffer: [512]u8 = undefined;
    if (page.about_formats) |label| gtk.gtk_label_set_text(label, deviceFormatsText(&text_buffer, self).ptr);
    const stats = libraryStats(self);
    var count_buffer: [32]u8 = undefined;
    if (page.about_tracks) |label|
        gtk.gtk_label_set_text(label, if (stats) |value| strings.format(&count_buffer, "{f}", .{strings.grouped(value.tracks)}).ptr else "—");
    var scan_buffer: [64]u8 = undefined;
    if (page.about_scan) |label|
        gtk.gtk_label_set_text(label, details.recentMomentText(&scan_buffer, if (stats) |value| value.last_scan_finished_at else null).ptr);
    var diagnostics_buffer: [4096]u8 = undefined;
    if (page.diagnostics) |label| gtk.gtk_label_set_text(label, diagnosticsText(&diagnostics_buffer, self, stats).ptr);
}

fn aboutTab(self: *App) *gtk.Widget {
    const page = &self.settings_page;
    var audio = Facts.init("audio-headphones-symbolic", "Audio");
    _ = audio.add("Backend", signal_path.audio_backend);
    page.about_device = audio.add("Output device", "");
    page.about_formats = audio.add("Device formats", "");
    _ = audio.add("Engine", "32-bit float · no resampling");

    var library = Facts.init("orca-folders-symbolic", "Library");
    _ = library.add("Library", libraries.activeName(self).ptr);
    page.about_tracks = library.add("Tracks", "");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = library.add("Database", if (self.library_path) |database| homePath(&path_buffer, database).ptr else "No library open");
    page.about_scan = library.add("Last scan", "");

    var system = Facts.init("orca-engine-symbolic", "System");
    var os_buffer: [256]u8 = undefined;
    var os_writer = std.Io.Writer.fixed(os_buffer[0 .. os_buffer.len - 1]);
    writeOs(&os_writer, self) catch {};
    os_buffer[os_writer.end] = 0;
    _ = system.add("OS", os_buffer[0..os_writer.end :0].ptr);
    _ = system.add("Desktop portal", "Not used");
    var logs_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var logs_home: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = system.add("Logs", if (logging.directory(&logs_buffer)) |logs| homePath(&logs_home, logs).ptr else "Unavailable");
    const view = tab(self, .about, aboutHeader(self), &.{ audio.section.widget, library.section.widget, system.section.widget }, &.{ formatsCard(), diagnosticsCard(self) });
    showAbout(self);
    return view;
}

const Filter = struct {
    self: *App,
    needle: []const u8,

    fn matches(filter: Filter, text: ?[*:0]const u8) bool {
        const value = text orelse return false;
        return std.ascii.findIgnoreCase(std.mem.span(value), filter.needle) != null;
    }

    fn hide(filter: Filter, widget: *gtk.Widget) void {
        const page = &filter.self.settings_page;
        if (gtk.gtk_widget_get_visible(widget) == gtk.false_) return;
        if (page.filter_hidden_len == page.filter_hidden.len) return;
        gtk.gtk_widget_set_visible(widget, gtk.false_);
        page.filter_hidden[page.filter_hidden_len] = widget;
        page.filter_hidden_len += 1;
    }

    fn rowMatches(filter: Filter, row: *gtk.Widget) bool {
        if (filter.matches(adw.adw_preferences_row_get_title(gtk.cast(adw.PreferencesRow, row)))) return true;
        if (gtk.g_type_check_instance_is_a(row, adw.adw_action_row_get_type()) != 0)
            return filter.matches(adw.adw_action_row_get_subtitle(gtk.cast(adw.ActionRow, row)));
        if (gtk.g_type_check_instance_is_a(row, adw.adw_expander_row_get_type()) != 0)
            return filter.matches(adw.adw_expander_row_get_subtitle(gtk.cast(adw.ExpanderRow, row)));
        return false;
    }

    fn rows(filter: Filter, widget: *gtk.Widget, keep: bool) bool {
        if (gtk.g_type_check_instance_is_a(widget, adw.adw_preferences_row_get_type()) != 0) {
            if (keep or filter.rowMatches(widget)) return true;
            filter.hide(widget);
            return false;
        }
        var found = false;
        var child = gtk.gtk_widget_get_first_child(widget);
        while (child) |next| : (child = gtk.gtk_widget_get_next_sibling(next)) {
            if (filter.rows(next, keep)) found = true;
        }
        return found;
    }

    fn cards(filter: Filter, widget: *gtk.Widget) bool {
        if (gtk.gtk_widget_has_css_class(widget, "settings-card") != 0) {
            const title: ?[*:0]const u8 = @ptrCast(gtk.g_object_get_data(widget, card_title_key));
            const titled = filter.matches(title);
            if (filter.rows(widget, titled) or titled) return true;
            filter.hide(widget);
            return false;
        }
        var found = false;
        var child = gtk.gtk_widget_get_first_child(widget);
        while (child) |next| : (child = gtk.gtk_widget_get_next_sibling(next)) {
            if (filter.cards(next)) found = true;
        }
        if (!found) if (gtk.gtk_widget_get_parent(widget)) |parent| {
            if (gtk.gtk_widget_has_css_class(parent, "settings-columns") != 0) filter.hide(widget);
        };
        return found;
    }
};

pub fn setFilter(self: *App, text: []const u8) void {
    const page = &self.settings_page;
    for (page.filter_hidden[0..page.filter_hidden_len]) |widget| gtk.gtk_widget_set_visible(widget, gtk.true_);
    page.filter_hidden_len = 0;
    const needle = std.mem.trim(u8, text, " ");
    if (needle.len != 0) for (std.enums.values(app.SettingsTab)) |which| buildTab(self, which);
    var first: ?app.SettingsTab = null;
    var current_matches = false;
    for (std.enums.values(app.SettingsTab)) |which| {
        const content = page.contents[@backingInt(which)] orelse continue;
        const found = needle.len == 0 or (Filter{ .self = self, .needle = needle }).cards(content);
        if (page.tab_buttons[@backingInt(which)]) |button| gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, button), @intFromBool(found));
        if (found and first == null) first = which;
        if (found and which == page.tab) current_matches = true;
    }
    if (!current_matches) if (first) |which| selectTab(self, which);
}

fn columnSpan(which: app.SettingsTab) [2]c_int {
    return if (which == .sound) .{ 7, 4 } else .{ 1, 1 };
}

fn layOut(self: *App, which: app.SettingsTab, narrow: bool) void {
    const grid = self.settings_page.columns[@backingInt(which)] orelse return;
    const manager = gtk.gtk_widget_get_layout_manager(grid) orelse return;
    const span = columnSpan(which);
    var child = gtk.gtk_widget_get_first_child(grid);
    var index: c_int = 0;
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        const layout = gtk.cast(gtk.GridLayoutChild, gtk.gtk_layout_manager_get_layout_child(manager, widget));
        const width = span[@intCast(index)];
        if (narrow) {
            gtk.gtk_grid_layout_child_set_column(layout, 0);
            gtk.gtk_grid_layout_child_set_row(layout, index);
            gtk.gtk_grid_layout_child_set_column_span(layout, span[0] + span[1]);
        } else {
            gtk.gtk_grid_layout_child_set_column(layout, if (index == 0) 0 else span[0]);
            gtk.gtk_grid_layout_child_set_row(layout, 0);
            gtk.gtk_grid_layout_child_set_column_span(layout, width);
        }
        index += 1;
    }
}

fn narrowLayout(self: *App) bool {
    return self.window_narrow or self.header_compact or self.settings_page.fit != .wide;
}

fn iconTabs(self: *App) bool {
    return self.window_narrow or self.header_compact or self.settings_page.fit == .icons;
}

fn tab(self: *App, which: app.SettingsTab, top: ?*gtk.Widget, left: []const *gtk.Widget, right: []const *gtk.Widget) *gtk.Widget {
    const grid = gtk.gtk_grid_new();
    gtk.gtk_widget_add_css_class(grid, "settings-columns");
    gtk.gtk_grid_set_column_homogeneous(gtk.cast(gtk.Grid, grid), gtk.true_);
    gtk.gtk_grid_set_column_spacing(gtk.cast(gtk.Grid, grid), 16);
    gtk.gtk_grid_set_row_spacing(gtk.cast(gtk.Grid, grid), 16);
    const span = columnSpan(which);
    for ([_][]const *gtk.Widget{ left, right }, 0..) |cards, index| {
        const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
        gtk.gtk_widget_set_valign(column, gtk.ALIGN_START);
        gtk.gtk_widget_set_hexpand(column, gtk.true_);
        for (cards) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, column), widget);
        gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), column, if (index == 0) 0 else span[0], 0, span[index], 1);
    }
    self.settings_page.columns[@backingInt(which)] = grid;
    layOut(self, which, narrowLayout(self));

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(content, "settings-tab");
    if (top) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, content), widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), grid);
    self.settings_page.contents[@backingInt(which)] = content;
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), content);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    return scroller;
}

pub fn setNarrow(self: *App) void {
    const narrow = narrowLayout(self);
    for (std.enums.values(app.SettingsTab)) |which| layOut(self, which, narrow);
    const icons = iconTabs(self);
    for (self.settings_page.tab_labels) |maybe_label| {
        const label = maybe_label orelse continue;
        gtk.gtk_widget_set_visible(label, @intFromBool(!icons));
    }
    stackEqualizerHeader(self);
    stackAboutHeader(self);
}

fn stackAboutHeader(self: *App) void {
    const header = self.settings_page.about_header orelse return;
    const orientation = if (iconTabs(self)) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL;
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, header), orientation);
}

fn stackEqualizerHeader(self: *App) void {
    const header = self.sound_controls.equalizer_header orelse return;
    const orientation = if (iconTabs(self)) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL;
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, header), orientation);
}

pub fn build(self: *App) *gtk.Widget {
    const heading = page_ui.title("Settings");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, heading.title), "settings-title");
    gtk.gtk_label_set_text(heading.meta, default_subtitle);
    self.settings_page.subtitle = heading.meta;
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, heading.meta), "settings-subtitle");
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, heading.meta), "numeric");

    const host = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, host), heading.widget);
    self.settings_page.host = gtk.cast(gtk.Box, host);

    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), host);
    addFit(self, bin, "max-width: 1040sp", .icons);

    const view = bin;
    return view;
}

fn addFit(self: *App, bin: *gtk.Widget, condition: [*:0]const u8, fit: app.SettingsFit) void {
    const parsed = adw.adw_breakpoint_condition_parse(condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(parsed);
    gtk.g_object_set_data(breakpoint, "orca-settings-fit", @ptrFromInt(@as(usize, @backingInt(fit)) + 1));
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(fitApplied), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(fitUnapplied), self);
    adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
}

fn fitOf(breakpoint: ?*anyopaque) app.SettingsFit {
    const tag = @intFromPtr(gtk.g_object_get_data(breakpoint.?, "orca-settings-fit"));
    return @fromBackingInt(@intCast(@as(std.meta.Tag(app.SettingsFit), @intCast(tag - 1))));
}

fn fitApplied(breakpoint: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.settings_page.fit = fitOf(breakpoint);
    setNarrow(self);
}

fn fitUnapplied(breakpoint: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.fit != fitOf(breakpoint)) return;
    self.settings_page.fit = .wide;
    setNarrow(self);
}

const TabInfo = struct { name: [*:0]const u8, label: [*:0]const u8, icon: [*:0]const u8 };

const tab_info = std.EnumArray(app.SettingsTab, TabInfo).init(.{
    .general = .{ .name = "general", .label = "General", .icon = "orca-settings-symbolic" },
    .library = .{ .name = "library", .label = "Library", .icon = "orca-folders-symbolic" },
    .playback = .{ .name = "playback", .label = "Playback", .icon = "orca-play-symbolic" },
    .sound = .{ .name = "sound", .label = "Sound", .icon = "audio-headphones-symbolic" },
    .listening = .{ .name = "listening", .label = "Listening", .icon = "orca-clock-symbolic" },
    .appearance = .{ .name = "appearance", .label = "Appearance", .icon = "orca-image-symbolic" },
    .advanced = .{ .name = "advanced", .label = "Advanced", .icon = "orca-engine-symbolic" },
    .about = .{ .name = "about", .label = "About", .icon = "orca-wave-symbolic" },
});

fn syncTabs(self: *App) void {
    const page = &self.settings_page;
    buildTab(self, page.tab);
    if (page.stale[@backingInt(page.tab)] and self.current_page == .settings) {
        page.stale[@backingInt(page.tab)] = false;
        refreshTab(self, page.tab);
    }
    page.syncing = true;
    defer page.syncing = false;
    for (page.tab_buttons, 0..) |maybe, index| {
        const button = maybe orelse continue;
        const checked = index == @backingInt(page.tab);
        if (checked) gtk.gtk_toggle_button_set_active(button, gtk.true_);
        gtk.gtk_widget_set_focusable(gtk.cast(gtk.Widget, button), @intFromBool(checked));
    }
    if (page.tabs) |stack| adw.adw_view_stack_set_visible_child_name(stack, tab_info.get(page.tab).name);
    if (page.subtitle) |subtitle| gtk.gtk_label_set_text(subtitle, if (page.tab == .advanced) advanced_subtitle else default_subtitle);
}

const default_subtitle = "Configure Orca to match your music, your way.";
const advanced_subtitle = "Things most people never need. Defaults are safe.";

pub fn selectTab(self: *App, which: app.SettingsTab) void {
    self.settings_page.tab = which;
    syncTabs(self);
    page_ui.showWindowTitle(self);
}

pub fn tabLabel(which: app.SettingsTab) [*:0]const u8 {
    return tab_info.get(which).label;
}

fn tabToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    for (self.settings_page.tab_buttons, 0..) |candidate, index| {
        if (candidate == toggle) return selectTab(self, @fromBackingInt(@intCast(index)));
    }
}

fn tabKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const step: isize = switch (keyval) {
        gtk.KEY_Left => -1,
        gtk.KEY_Right => 1,
        else => return gtk.false_,
    };
    const count: isize = app.settings_tab_count;
    const next: usize = @intCast(@mod(@as(isize, @backingInt(self.settings_page.tab)) + step, count));
    selectTab(self, @fromBackingInt(@intCast(next)));
    const button = self.settings_page.tab_buttons[next] orelse return gtk.true_;
    _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, button));
    return gtk.true_;
}

fn tabBar(self: *App) *gtk.Widget {
    const page = &self.settings_page;
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 26);
    gtk.gtk_widget_add_css_class(bar, "settings-tabs");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, bar), gtk.ACCESSIBLE_PROPERTY_LABEL, "Settings sections", @as(c_int, -1));
    var group: ?*gtk.ToggleButton = null;
    const icons = iconTabs(self);
    for (std.enums.values(app.SettingsTab)) |which| {
        const info = tab_info.get(which);
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_widget_add_css_class(button, "settings-tab");
        gtk.gtk_widget_set_tooltip_text(button, info.label);
        const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_set_halign(content, gtk.ALIGN_CENTER);
        const icon = gtk.gtk_image_new_from_icon_name(info.icon);
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 16);
        const label = gtk.gtk_label_new(info.label);
        gtk.gtk_widget_set_visible(label, @intFromBool(!icons));
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon);
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), label);
        gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, info.label, @as(c_int, -1));
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        page.tab_buttons[@backingInt(which)] = toggle;
        page.tab_labels[@backingInt(which)] = label;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(tabToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, bar), button);
    }
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(tabKeyPressed), self);
    gtk.gtk_widget_add_controller(bar, keys);
    return bar;
}

fn buildTab(self: *App, which: app.SettingsTab) void {
    const page = &self.settings_page;
    const stack = page.tabs orelse return;
    if (page.contents[@backingInt(which)] != null) return;
    const content = switch (which) {
        .general => generalTab(self),
        .library => libraryTab(self),
        .playback => playbackTab(self),
        .sound => soundTab(self),
        .listening => listeningTab(self),
        .appearance => appearanceTab(self),
        .advanced => advancedTab(self),
        .about => aboutTab(self),
    };
    const info = tab_info.get(which);
    _ = adw.adw_view_stack_add_titled_with_icon(stack, content, info.name, info.label, info.icon);
    page.stale[@backingInt(which)] = false;
}

/// Brings a tab built on an earlier visit in line with what may have changed
/// while the page was away.
fn refreshTab(self: *App, which: app.SettingsTab) void {
    switch (which) {
        .library => {
            refreshLibrary(self);
            showDuplicates(self);
            if (self.watch_row) |row| adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, row), @intFromBool(self.watch_folders));
            AcoustIdKey.checkOnce(self);
            showSubmission(self);
        },
        .playback => transport.refreshDevices(self),
        .advanced => {
            showBuffer(self);
            showCache(self);
        },
        .about => showAbout(self),
        .general, .sound, .listening, .appearance => {},
    }
}

pub fn show(self: *App) void {
    const page = &self.settings_page;
    const host = page.host orelse return;
    if (page.tabs != null) {
        if (page.away_maintenance_row) |row| self.maintenance_row = row;
        page.away_maintenance_row = null;
        syncTabs(self);
        tick(self);
        return;
    }
    const views = adw.adw_view_stack_new();
    page.tabs = gtk.cast(adw.ViewStack, views);
    adw.adw_view_stack_set_hhomogeneous(page.tabs.?, gtk.false_);
    gtk.gtk_widget_set_vexpand(views, gtk.true_);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "settings-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), tabBar(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), views);
    gtk.gtk_box_append(host, body);
    page.body = body;
    syncTabs(self);
}

pub fn flushPending(self: *App) void {
    if (self.settings_page.tile_save_timer != 0) {
        cancelTileTimer(self);
        settings.save(self);
    }
}

/// After the main loop: saves every debounced setting still pending without
/// applying it, since the window and its widgets are gone.
pub fn shutdown(self: *App) void {
    var pending = self.settings_page.tile_save_timer != 0 or
        self.equalizer_apply_timer != 0 or
        self.parametric.apply_timer != 0;
    cancelTileTimer(self);
    cancelEqualizerTimer(self);
    parametric.cancelApplyTimer(self);
    if (self.volume_settle_timer != 0) {
        _ = gtk.g_source_remove(self.volume_settle_timer);
        self.volume_settle_timer = 0;
        pending = true;
    }
    if (pending) settings.save(self);
}

/// Keeps the page's widgets for the next visit; saves and applies what is
/// pending, and drops a typed secret, as closing the page did.
pub fn leave(self: *App) void {
    const page = &self.settings_page;
    if (page.tabs == null) return;
    flushPending(self);
    if (self.equalizer_apply_timer != 0) applyEqualizer(self, equalizerIsOn(self));
    if (self.parametric.apply_timer != 0) parametric.applyNow(self);
    if (self.maintenance_row) |row| page.away_maintenance_row = row;
    self.maintenance_row = null;
    page.stale = @splat(true);
    ListenBrainzToken.forget(self);
    AcoustIdKey.forget(self);
}

fn teardown(self: *App) void {
    const page = &self.settings_page;
    flushPending(self);
    if (page.host) |host| if (page.body) |body| gtk.gtk_box_remove(host, body);
    page.* = .{ .host = page.host, .subtitle = page.subtitle, .tab = page.tab, .fit = page.fit };
    self.sound_controls = .{};
    self.listening_controls = .{};
    self.acoustid_controls = .{};
    self.watch_row = null;
    self.contribute_row = null;
    self.submission_row = null;
    self.submission_button = null;
    self.maintenance_row = null;
    if (self.equalizer_apply_timer != 0) applyEqualizer(self, equalizerIsOn(self));
    parametric.leave(self);
}
