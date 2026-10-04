//! Settings: a page of eight tabs. General holds startup, notifications,
//! sorting and the keyboard summary; Library the folders, maintenance and
//! AcoustID; Playback the ReplayGain and output choices; Sound the equalizer,
//! crossfeed and what is playing; Listening ListenBrainz, lyrics and artist
//! info; Appearance the window's look; Advanced the data sources and
//! database; About the version and diagnostics.
//! The tabs are built fresh each time the page is shown, from the engine's
//! current state, and destroyed when it is left. The search field filters
//! their rows by title and subtitle.

const std = @import("std");
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

    fn addSwitch(self: Card, label: [*:0]const u8, active: bool, handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
        const toggle = gtk.gtk_switch_new();
        gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);
        gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, toggle), @intFromBool(active));
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, toggle), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
        _ = gtk.signalConnect(toggle, "notify::active", handler, data);
        gtk.gtk_box_append(gtk.cast(gtk.Box, self.body), toggle);
        return toggle;
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
    if (label == null) gtk.gtk_widget_add_css_class(button, "flat");
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
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Its tracks leave the library. The files on disk are not touched.");
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

fn watchStatusText(buffer: []u8, self: *App) [:0]const u8 {
    if (!self.watch_folders) return "Rescans a folder as soon as its files change";
    const library = self.library orelse return "";
    const status = self.runtime.libraryWatchStatus(library) catch return "";
    if (status.state == .off) return "The music folders could not be watched";
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

fn analysisThreadsSubtitle(buffer: []u8, threads: u16) [:0]const u8 {
    if (threads == liborca.analysisAvailableThreads())
        return "Uses every processor core. Playback and the rest of the system may slow down while measuring.";
    return strings.printZ(buffer, "Default: {d}", .{liborca.analysisDefaultThreads()}) catch "";
}

fn analysisThreadsChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const value = adw.adw_spin_row_get_value(gtk.cast(adw.SpinRow, row));
    const available: f64 = @floatFromInt(liborca.analysisAvailableThreads());
    const threads: u16 = @intFromFloat(std.math.clamp(@round(value), 1, available));
    var buffer: [32]u8 = undefined;
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), analysisThreadsSubtitle(&buffer, threads).ptr);
    if (self.analysis_threads == threads) return;
    self.analysis_threads = threads;
    settings.save(self);
}

fn duplicatesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startDuplicates(state(data));
}

fn thresholdChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const value = adw.adw_spin_row_get_value(gtk.cast(adw.SpinRow, row));
    const range = settings.threshold_range;
    const percent: u8 = @intFromFloat(std.math.clamp(@round(value), @as(f64, range[0]), @as(f64, range[1])));
    if (percent == self.match_threshold_percent) return;
    self.match_threshold_percent = percent;
    settings.save(self);
    matches.invalidate(self);
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

const acoustid_key_url = "https://acoustid.org/api-key";

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

fn acoustIdCard(self: *App) *gtk.Widget {
    const acoustid = card(
        "auth-fingerprint-symbolic",
        "AcoustID",
        "AcoustID identifies tracks by their sound. With your key, matches you accept can be sent back from the Matches page.",
    );
    const fingerprints = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, fingerprints), "Match by audio fingerprint");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, fingerprints), "Find Matches also sends a fingerprint of each track's audio to AcoustID");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, fingerprints), if (self.match_fingerprints) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(fingerprints, "notify::active", gtk.callback(fingerprintsSwitched), self);
    acoustid.add(fingerprints);

    AcoustIdKey.add(self, acoustid);

    const link = actionRow("Get your token", "Create an account and get your key at acoustid.org");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, link), 3);
    const link_button = externalLink(acoustid_key_url, "acoustid.org");
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, link), link_button);
    adw.adw_action_row_set_activatable_widget(gtk.cast(adw.ActionRow, link), link_button);
    acoustid.add(link);
    AcoustIdKey.checkOnce(self);
    return acoustid.widget;
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

fn folderRows(self: *App, library: liborca.LibraryHandle) *gtk.Widget {
    const rows = adw.adw_preferences_group_new();
    var roots = self.runtime.libraryRootPage(library, app.page_size, 0) catch return rows;
    defer roots.deinit();
    var buffer: [1024]u8 = undefined;
    for (roots.items) |root| {
        const row = actionRow(strings.terminated(&buffer, root.path).ptr, if (root.enabled) "" else "Paused");
        gtk.gtk_widget_add_css_class(row, "settings-folder-row");
        adw.adw_action_row_add_prefix(gtk.cast(adw.ActionRow, row), gtk.gtk_image_new_from_icon_name("folder-symbolic"));
        gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, row), gtk.false_);
        gtk.gtk_widget_set_focusable(row, gtk.false_);
        const actions = gtk.gtk_menu_button_new();
        gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, actions), "view-more-symbolic");
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
    const row = page.measure_row orelse return;
    const library = self.library orelse return;
    const unmeasured = self.runtime.libraryUnanalyzedCount(library) catch 0;
    var buffer: [256]u8 = undefined;
    const measure_text: [:0]const u8 = if (unmeasured == 0)
        "Every file is measured. ReplayGain and duplicate finding use these measurements."
    else
        strings.printZ(&buffer, "{d} files not measured yet. ReplayGain and duplicate finding need this; it decodes every file, so it takes a while and can be stopped.", .{unmeasured}) catch "";
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), measure_text.ptr);
    if (page.measure_button) |button| gtk.gtk_widget_set_sensitive(button, if (unmeasured != 0) gtk.true_ else gtk.false_);
}

pub fn refreshLibrary(self: *App) void {
    showMeasure(self);
    const slot = self.settings_page.folder_slot orelse return;
    const library = self.library orelse return;
    if (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, slot))) |old| gtk.gtk_box_remove(slot, old);
    gtk.gtk_box_append(slot, folderRows(self, library));
}

fn foldersCard(self: *App, library: liborca.LibraryHandle) *gtk.Widget {
    const folders = card(
        "folder-symbolic",
        "Music Folders",
        "Orca reads these folders for your music. It never changes a file unless you write tags to it.",
    );
    const slot = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, slot), folderRows(self, library));
    gtk.gtk_box_insert_child_after(gtk.cast(gtk.Box, folders.widget), slot, folders.header);
    self.settings_page.folder_slot = gtk.cast(gtk.Box, slot);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(actions, "settings-folder-actions");
    const add = labelledButton("Add Folder…", "list-add-symbolic", gtk.callback(addFolderActivated), self);
    gtk.gtk_widget_add_css_class(add, "settings-add-folder");
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), add);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), labelledButton("Rescan All Folders", "view-refresh-symbolic", gtk.callback(rescanActivated), self));
    gtk.gtk_box_insert_child_after(gtk.cast(gtk.Box, folders.widget), actions, slot);

    if (watching.supported(self)) {
        const watch = adw.adw_switch_row_new();
        adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, watch), "Watch folders for changes");
        adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, watch), 4);
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, watch), if (self.watch_folders) gtk.true_ else gtk.false_);
        _ = gtk.signalConnect(watch, "notify::active", gtk.callback(watchSwitched), self);
        folders.add(watch);
        self.watch_row = watch;
        self.watch_status_len = 0;
        showWatchStatus(self);
    }
    return folders.widget;
}

fn maintenanceCard(self: *App) *gtk.Widget {
    const maintenance_card = card(
        "applications-engineering-symbolic",
        "Maintenance",
        "Measures loudness and finds duplicate recordings when asked, and checks recording IDs while Orca is idle.",
    );
    var buffer: [64]u8 = undefined;
    const measure = actionRow("Measure Loudness", "");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, measure), 3);
    const measure_button = suffixButton(measure, "Measure", null, gtk.callback(measureClicked), self);
    self.settings_page.measure_row = measure;
    self.settings_page.measure_button = measure_button;
    showMeasure(self);
    maintenance_card.add(measure);
    const available_threads = liborca.analysisAvailableThreads();
    const shown_threads = @min(self.analysis_threads orelse liborca.analysisDefaultThreads(), available_threads);
    const threads = adw.adw_spin_row_new_with_range(1, @floatFromInt(available_threads), 1);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, threads), "Analysis threads");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, threads), analysisThreadsSubtitle(&buffer, shown_threads).ptr);
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, threads), 3);
    adw.adw_spin_row_set_digits(gtk.cast(adw.SpinRow, threads), 0);
    adw.adw_spin_row_set_value(gtk.cast(adw.SpinRow, threads), @floatFromInt(shown_threads));
    _ = gtk.signalConnect(threads, "notify::value", gtk.callback(analysisThreadsChanged), self);
    maintenance_card.add(threads);
    const duplicates = actionRow("Find Duplicates", "Compares measured audio, so files that are the same recording show up in Health.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, duplicates), 3);
    _ = suffixButton(duplicates, "Find", null, gtk.callback(duplicatesClicked), self);
    maintenance_card.add(duplicates);
    const idle = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, idle), "Idle maintenance");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, idle), 3);
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, idle), if (self.idle_maintenance) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(idle, "notify::active", gtk.callback(maintenanceSwitched), self);
    maintenance_card.add(idle);
    self.maintenance_row = idle;
    self.maintenance_status_len = 0;
    showMaintenanceStatus(self);
    const range = settings.threshold_range;
    const threshold = adw.adw_spin_row_new_with_range(@floatFromInt(range[0]), @floatFromInt(range[1]), 1);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, threshold), "Accept confident matches at");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, threshold), "Percent. Accept Confident on the Matches page takes a track's best match scoring this or more.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, threshold), 3);
    adw.adw_spin_row_set_digits(gtk.cast(adw.SpinRow, threshold), 0);
    adw.adw_spin_row_set_value(gtk.cast(adw.SpinRow, threshold), @floatFromInt(self.match_threshold_percent));
    _ = gtk.signalConnect(threshold, "notify::value", gtk.callback(thresholdChanged), self);
    maintenance_card.add(threshold);
    if (self.library) |library| {
        const fill = self.runtime.libraryGenreFill(library) catch liborca.GenreFill{};
        const genres = adw.adw_switch_row_new();
        adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, genres), "Fill missing genres from MusicBrainz");
        adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, genres), "When artist or album info is fetched, tracks with no genre from a file or an edit take MusicBrainz's");
        adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, genres), 3);
        adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, genres), @intFromBool(fill.musicbrainz));
        _ = gtk.signalConnect(genres, "notify::active", gtk.callback(genreFillSwitched), self);
        maintenance_card.add(genres);
    }
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
    const sources = card("network-server-symbolic", "Data sources", "Where Orca's online information comes from, and the terms it comes under.");
    const genre_fill_on = if (self.library) |library|
        (self.runtime.libraryGenreFill(library) catch liborca.GenreFill{}).musicbrainz
    else
        false;
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
    const library = self.library orelse return tab(self, .library, null, &.{}, &.{});
    return tab(self, .library, null, &.{ foldersCard(self, library), maintenanceCard(self) }, &.{acoustIdCard(self)});
}

fn generalTab(self: *App) *gtk.Widget {
    const general = self.general;
    const startup = flatCard("orca-play-symbolic", "Startup", "What happens when Orca opens.");
    startup.add(switchRow("Open Orca at login", "", general.launch_at_login, gtk.callback(loginSwitched), self));
    startup.add(selectRow(
        "Default page",
        "Queue and resume behavior live in Playback",
        &.{ "Albums", "Artists", "Tracks", "Now Playing", null },
        @intFromEnum(general.start_page),
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
        @intFromEnum(general.name_order),
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
    const info = card(
        "avatar-default-symbolic",
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

fn replayGainChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row));
    const mode: liborca.ReplayGainMode = switch (selected) {
        1 => .track,
        2 => .album,
        else => .off,
    };
    self.runtime.playerSetReplayGainMode(self.player, mode) catch return;
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn outputChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.settings_page.syncing) return;
    transport.selectDevice(self, adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row)));
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
    const page = &self.settings_page;
    if (page.device_row == null and page.device_drop_down == null) return;
    page.syncing = true;
    defer page.syncing = false;
    const index: c_uint = @intCast(self.device_index);
    if (page.device_row_names) |names| fillDeviceNames(self, names);
    if (page.device_row) |row| adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, row), index);
    if (page.device_drop_down_names) |names| fillDeviceNames(self, names);
    if (page.device_drop_down) |drop_down| gtk.gtk_drop_down_set_selected(drop_down, index);
}

fn deviceNames(self: *App) *gtk.StringList {
    const names = gtk.gtk_string_list_new(null);
    for (self.device_names.items) |name| gtk.gtk_string_list_append(names, name.ptr);
    return names;
}

fn playbackTab(self: *App) *gtk.Widget {
    const volume = card("multimedia-volume-control-symbolic", "Volume", "ReplayGain plays each track, or each album, at the loudness Measure Loudness found for it.");
    const modes = [_]?[*:0]const u8{ "Off", "Track", "Album", null };
    const replay = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, replay), "ReplayGain");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, replay), "Track evens out every track; Album keeps the levels within an album");
    const mode_list = gtk.gtk_string_list_new(&modes);
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, replay), gtk.cast(gtk.ListModel, mode_list));
    gtk.g_object_unref(mode_list);
    const mode = self.runtime.playerReplayGainMode(self.player) catch .off;
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, replay), switch (mode) {
        .off => 0,
        .track => 1,
        .album, .smart => 2,
    });
    _ = gtk.signalConnect(replay, "notify::selected", gtk.callback(replayGainChanged), self);
    volume.add(replay);
    const gapless = actionRow("Gapless playback", "Always on. Tracks that share a sample rate and channel count play back to back with no gap.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, gapless), 3);
    volume.add(gapless);

    const output = card("audio-card-symbolic", "Output", "Where Orca plays. The device is remembered by name.");
    transport.refreshDevices(self);
    const names = deviceNames(self);
    const device = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, device), "Output Device");
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, device), gtk.cast(gtk.ListModel, names));
    gtk.g_object_unref(names);
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, device), @intCast(self.device_index));
    _ = gtk.signalConnect(device, "notify::selected", gtk.callback(outputChanged), self);
    output.add(device);
    self.settings_page.device_row = device;
    self.settings_page.device_row_names = names;
    return tab(self, .playback, null, &.{volume.widget}, &.{output.widget});
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
const amount_labels = [_]?[*:0]const u8{ "Light", "Medium", "Strong", null };

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
        adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, row), @intFromEnum(chosen));
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

fn crossfeedSwitched(toggle: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = gtk.gtk_switch_get_active(gtk.cast(gtk.Switch, toggle)) != 0;
    if (self.sound_controls.crossfeed_amount_row) |amount|
        gtk.gtk_widget_set_sensitive(amount, if (enabled) gtk.true_ else gtk.false_);
    applyCrossfeed(self, enabled);
}

fn crossfeedAmountChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row));
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

const graphic_title = "Equalizer";
const graphic_description = "Ten bands from 31 Hz to 16 kHz, applied to everything Orca plays.";
const parametric_title = "Parametric Equalizer";
const parametric_description = "Fine-tune your sound with a parametric equalizer. Make subtle adjustments or create your own signature sound.";

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
    if (controls.equalizer_menu) |button| gtk.gtk_widget_set_visible(button, @intFromBool(view == .parametric));
    if (controls.equalizer_title) |label|
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), if (view == .parametric) parametric_title else graphic_title);
    if (controls.equalizer_meta) |label|
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), if (view == .parametric) parametric_description else graphic_description);
    showEqualizerEnabled(self, mode == .graphic);
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
    gtk.gtk_widget_add_css_class(box, "eq-mode");
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
        _ = gtk.signalConnect(button, "toggled", choice[2], self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
}

fn exportActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    parametric.chooseExport(state(data));
}

fn savePresetActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    parametric.askPresetName(state(data));
}

fn equalizerMenu(self: *App) *gtk.Widget {
    const group = gtk.g_simple_action_group_new();
    for ([_]struct { [*:0]const u8, gtk.GCallback }{
        .{ "export", gtk.callback(exportActivated) },
        .{ "save-preset", gtk.callback(savePresetActivated) },
    }) |entry| {
        const action = gtk.g_simple_action_new(entry[0], null).?;
        _ = gtk.signalConnect(action, "activate", entry[1], self);
        gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
        gtk.g_object_unref(action);
    }
    const model = gtk.g_menu_new();
    gtk.g_menu_append(model, "Export…", "equalizer.export");
    gtk.g_menu_append(model, "Save as Preset…", "equalizer.save-preset");
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), "view-more-horizontal-symbolic");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, button), gtk.cast(gtk.GMenuModel, model));
    gtk.g_object_unref(model);
    gtk.gtk_widget_insert_action_group(button, "equalizer", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(button, "Equalizer actions");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, "Equalizer actions", @as(c_int, -1));
    return button;
}

fn soundTab(self: *App) *gtk.Widget {
    const controls = &self.sound_controls;

    const current = self.runtime.playerEqualizer(self.player) catch null;
    if (current) |curve| self.equalizer_curve = curve;
    if (self.runtime.playerParametricEqualizer(self.player) catch null) |curve| self.parametric.curve = curve;
    const curve = self.equalizer_curve;
    const mode = parametric.currentMode(self);

    const equalizer = card("orca-pulse-symbolic", graphic_title, graphic_description);
    gtk.gtk_widget_add_css_class(equalizer.widget, "eq-card");
    controls.equalizer_title = equalizer.title;
    controls.equalizer_meta = equalizer.meta;
    controls.graphic = equalizer.group;
    const choices = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_set_halign(choices, gtk.ALIGN_START);
    gtk.gtk_box_append(gtk.cast(gtk.Box, choices), modeControl(self, mode));
    const menu_button = equalizerMenu(self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, choices), menu_button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, equalizer.body), choices);
    controls.equalizer_menu = menu_button;
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

    const view = tab(self, .sound, null, &.{equalizer.widget}, &.{ outputDeviceCard(self), crossfeedCard(self), audioInformationCard(self) });
    _ = gtk.signalConnect(view, "map", gtk.callback(soundMapped), self);
    return view;
}

fn soundMapped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    transport.refreshDevices(state(data));
}

fn sideCard(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) Card {
    const side = card(icon, title, description);
    gtk.gtk_widget_add_css_class(side.widget, "settings-side-card");
    return side;
}

fn outputDeviceCard(self: *App) *gtk.Widget {
    const output = sideCard("audio-card-symbolic", "Output Device", "Where Orca plays, the same choice as the player bar's");
    transport.refreshDevices(self);
    const names = deviceNames(self);
    const drop_down = gtk.gtk_drop_down_new(gtk.cast(gtk.ListModel, names), null);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, drop_down), gtk.ACCESSIBLE_PROPERTY_LABEL, "Output Device", @as(c_int, -1));
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, drop_down), @intCast(self.device_index));
    _ = gtk.signalConnect(drop_down, "notify::selected", gtk.callback(outputPicked), self);
    gtk.gtk_widget_set_visible(output.group, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, output.widget), drop_down);
    self.settings_page.device_drop_down = gtk.cast(gtk.DropDown, drop_down);
    self.settings_page.device_drop_down_names = names;
    return output.widget;
}

fn crossfeedCard(self: *App) *gtk.Widget {
    const controls = &self.sound_controls;
    const crossfeed_amount = self.runtime.playerCrossfeed(self.player) catch null;
    if (crossfeed_amount) |amount| self.crossfeed_amount = amount;
    const headphones = sideCard("audio-headphones-symbolic", "Crossfeed", "Blends a little of each channel into the other, for headphones");
    _ = headphones.addSwitch("Crossfeed", crossfeed_amount != null, gtk.callback(crossfeedSwitched), self);
    const amount = comboRow("Amount", &amount_labels);
    controls.crossfeed_amount_row = amount.row;
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, amount.row), nearestAmountIndex(self.crossfeed_amount));
    gtk.gtk_widget_set_sensitive(amount.row, if (crossfeed_amount != null) gtk.true_ else gtk.false_);
    headphones.add(amount.row);
    _ = gtk.signalConnect(amount.row, "notify::selected", gtk.callback(crossfeedAmountChanged), self);
    return headphones.widget;
}

const audio_fact_names = std.EnumArray(app.AudioFact, [*:0]const u8).init(.{
    .output_format = "Output Format",
    .sample_rate = "Sample Rate",
    .bit_depth = "Bit Depth",
    .channels = "Channels",
});

fn audioInformationMapped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    transport.refreshSignalPath(state(data));
}

fn audioInformationCard(self: *App) *gtk.Widget {
    const page = &self.settings_page;
    const info = sideCard("audio-x-generic-symbolic", "Audio Information", "What is playing now, as the decoder reads it");
    gtk.gtk_widget_set_visible(info.group, gtk.false_);
    const rows = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(rows, "settings-audio-rows");
    for (std.enums.values(app.AudioFact)) |fact| {
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
        const key = gtk.gtk_label_new(audio_fact_names.get(fact));
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, key), 0);
        gtk.gtk_widget_set_hexpand(key, gtk.true_);
        gtk.gtk_widget_add_css_class(key, "dim-label");
        const value = gtk.gtk_label_new("");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 1);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, value), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_add_css_class(value, "numeric");
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), key);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), value);
        gtk.gtk_box_append(gtk.cast(gtk.Box, rows), row);
        page.audio_values.set(fact, gtk.cast(gtk.Label, value));
    }
    const idle = gtk.gtk_label_new(signal_path.nothing_playing);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, idle), 0);
    gtk.gtk_widget_add_css_class(idle, "dim-label");
    gtk.gtk_widget_add_css_class(idle, "settings-audio-idle");
    gtk.gtk_box_append(gtk.cast(gtk.Box, info.widget), rows);
    gtk.gtk_box_append(gtk.cast(gtk.Box, info.widget), idle);
    page.audio_card = info.widget;
    page.audio_rows = rows;
    page.audio_idle = idle;
    _ = gtk.signalConnect(info.widget, "map", gtk.callback(audioInformationMapped), self);
    showAudioInformation(self, self.runtime.playerSignalPath(self.player) catch null);
    return info.widget;
}

fn writeAudioFact(writer: *std.Io.Writer, fact: app.AudioFact, path: liborca.SignalPath, source: liborca.PcmFormat) std.Io.Writer.Error!void {
    switch (fact) {
        .output_format => {
            try signal_path.writeCodecName(writer, path.codec orelse "PCM");
            try writer.writeAll(" · ");
            try signal_path.writeRate(writer, source.sample_rate);
        },
        .sample_rate => try signal_path.writeHertz(writer, source.sample_rate),
        .bit_depth => if (path.source_declared) try signal_path.writeBitDepth(writer, source) else try writer.writeAll("—"),
        .channels => try signal_path.writeChannels(writer, source.channels),
    }
}

pub fn showAudioInformation(self: *App, maybe_path: ?liborca.SignalPath) void {
    parametric.showRate(self, maybe_path);
    const page = &self.settings_page;
    const rows = page.audio_rows orelse return;
    const path = maybe_path orelse liborca.SignalPath{};
    const source = path.source;
    gtk.gtk_widget_set_visible(rows, @intFromBool(source != null));
    if (page.audio_idle) |idle| gtk.gtk_widget_set_visible(idle, @intFromBool(source == null));
    const format = source orelse return;
    for (std.enums.values(app.AudioFact)) |fact| {
        const label = page.audio_values.get(fact) orelse continue;
        var buffer: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        writeAudioFact(&writer, fact, path, format) catch {};
        buffer[writer.end] = 0;
        gtk.gtk_label_set_text(label, buffer[0..writer.end :0].ptr);
    }
}

pub fn audioInformationShown(self: *App) bool {
    const audio = self.settings_page.audio_card orelse return false;
    return gtk.gtk_widget_get_mapped(audio) != 0;
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

fn ignorePresence(_: *App, _: secret.Presence) void {}

const listenbrainz_token: Credential = .{
    .service = listenbrainz_token_service,
    .account = listenbrainz_token_account,
    .keyring_label = "Orca ListenBrainz user token",
    .title = "User token",
    .replace_title = "Replace token",
    .add_title = "Add token",
    .absent_subtitle = "No token saved",
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
    .checked = ignorePresence,
};

fn acoustIdControls(self: *App) *app.CredentialControls {
    return &self.acoustid_controls;
}

fn acoustIdKeyChanged(_: *App) void {}

const acoustid_user_key: Credential = .{
    .service = liborca.acoustid_credential_service,
    .account = liborca.acoustid_user_key_account,
    .keyring_label = "Orca AcoustID user key",
    .title = "Your AcoustID key",
    .replace_title = "Replace key",
    .add_title = "Add key",
    .absent_subtitle = "No key saved",
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
    .checked = matches.showAcoustIdKey,
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
            gtk.gtk_widget_set_visible(stored_row, gtk.true_);
            const subtitle: [*:0]const u8 = switch (presence) {
                .absent => credential.absent_subtitle,
                .stored => "Saved in your keyring",
                .locked => credential.locked_subtitle,
                .unavailable => "Could not reach the system keyring",
            };
            adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, stored_row), subtitle);
            if (controls.remove_button) |button| {
                gtk.gtk_widget_set_visible(button, if (presence == .stored) gtk.true_ else gtk.false_);
                gtk.gtk_widget_set_sensitive(button, gtk.true_);
            }
            if (controls.unlock_button) |button|
                gtk.gtk_widget_set_visible(button, if (presence == .locked) gtk.true_ else gtk.false_);
            const entry_title = if (presence == .stored) credential.replace_title else credential.add_title;
            if (controls.entry_title) |label| gtk.gtk_label_set_text(label, entry_title);
        }

        fn presenceFound(presence: secret.Presence, data: ?*anyopaque) void {
            const self = state(data);
            credential.checked(self, presence);
            showPresence(self, presence);
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

        fn checkOnce(self: *App) void {
            const controls = credential.controls(self);
            if (controls.checked) return;
            controls.checked = true;
            check(self, credential.first_check);
        }

        fn add(self: *App, target: Card) void {
            const stored_row = actionRow(credential.title, credential.absent_subtitle);
            const remove_button = suffixButton(stored_row, "Remove", null, gtk.callback(removeClicked), self);
            const unlock_button = suffixButton(stored_row, "Unlock", null, gtk.callback(unlockClicked), self);
            gtk.gtk_widget_set_visible(unlock_button, gtk.false_);
            target.add(stored_row);
            addEntry(self, target, stored_row, remove_button, unlock_button);
        }

        fn revealToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            const self = state(data);
            const entry = credential.controls(self).entry_row orelse return;
            const shown = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button));
            gtk.gtk_entry_set_visibility(gtk.cast(gtk.Entry, entry), shown);
            gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), if (shown != 0) "view-conceal-symbolic" else "view-reveal-symbolic");
        }

        fn addEntry(self: *App, target: Card, stored_row: *gtk.Widget, remove_button: *gtk.Widget, unlock_button: *gtk.Widget) void {
            const row = gtk.gtk_list_box_row_new();
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

fn statusText(buffer: []u8, self: *App, status: liborca.ScrobblerStatus) [:0]const u8 {
    var queue_buffer: [128]u8 = undefined;
    const queue = queueText(&queue_buffer, self, status);
    if (status.feedback_pending == 0) return strings.terminated(buffer, queue);
    return strings.format(buffer, "{s} · {d} {s} waiting to sync", .{
        queue,
        status.feedback_pending,
        plural(status.feedback_pending, "love or dislike", "loves and dislikes"),
    });
}

fn queueText(buffer: []u8, self: *App, status: liborca.ScrobblerStatus) [:0]const u8 {
    const user = status.user_name.slice();
    return switch (status.state) {
        .invalid_token => "Token rejected",
        .rate_limited => "Waiting — ListenBrainz asked us to slow down",
        .backing_off => "Waiting — ListenBrainz could not be reached, trying again later",
        .busy => "Waiting — another Orca process is sending to ListenBrainz",
        .offline => "Offline",
        .needs_token => "Not connected — add your user token",
        .disabled, .idle, .validating, .submitting => if (user.len != 0)
            strings.format(buffer, "Connected as {s} · {d} {s} waiting", .{
                user,
                status.pending,
                plural(status.pending, "listen", "listens"),
            })
        else if (self.scrobbling)
            strings.format(buffer, "Submitting listens · {d} {s} waiting", .{
                status.pending,
                plural(status.pending, "listen", "listens"),
            })
        else
            "Not connected",
    };
}

fn showListeningStatus(self: *App) void {
    const row = self.listening_controls.status_row orelse return;
    const library = self.library orelse return;
    const status = self.runtime.libraryScrobblerStatus(library) catch return;
    var buffer: [192]u8 = undefined;
    const text = statusText(&buffer, self, status);
    const controls = &self.listening_controls;
    if (std.mem.eql(u8, text, controls.status_text[0..controls.status_len])) return;
    @memcpy(controls.status_text[0..text.len], text);
    controls.status_len = text.len;
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), text.ptr);
}

pub fn tick(self: *App) void {
    if (self.settings_page.tabs == null) return;
    showListeningStatus(self);
    showWatchStatus(self);
    showMaintenanceStatus(self);
}

fn listeningTab(self: *App) *gtk.Widget {
    const listenbrainz = card(
        "document-send-symbolic",
        "ListenBrainz",
        "Orca always records what you play on this computer. Submitting also sends those listens to your ListenBrainz account.",
    );
    const submit = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, submit), "Submit listens");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, submit), "Only listens that start after you turn this on are sent");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, submit), if (self.scrobbling) gtk.true_ else gtk.false_);
    gtk.gtk_widget_set_sensitive(submit, if (self.library != null) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(submit, "notify::active", gtk.callback(scrobblingSwitched), self);
    listenbrainz.add(submit);

    const now_playing = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, now_playing), "Show what I'm playing now");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, now_playing), "Sends the current track to ListenBrainz once it has played for 10 seconds");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, now_playing), if (self.announce_now_playing) gtk.true_ else gtk.false_);
    gtk.gtk_widget_set_sensitive(now_playing, if (self.library != null and self.scrobbling) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(now_playing, "notify::active", gtk.callback(nowPlayingSwitched), self);
    listenbrainz.add(now_playing);

    ListenBrainzToken.add(self, listenbrainz);

    const link = actionRow("Get your token", "Copy it from your settings at listenbrainz.org");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, link), 3);
    const link_button = externalLink(token_settings_url, "listenbrainz.org");
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, link), link_button);
    adw.adw_action_row_set_activatable_widget(gtk.cast(adw.ActionRow, link), link_button);
    listenbrainz.add(link);

    const status = actionRow("Status", "");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, status), 2);
    self.listening_controls.now_playing_row = now_playing;
    self.listening_controls.status_row = status;
    listenbrainz.add(status);
    showListeningStatus(self);

    const lyrics_card = card(
        "media-view-subtitles-symbolic",
        "Lyrics",
        "Lyrics come from .lrc files beside your tracks and from their tags. Orca never writes lyrics to a file.",
    );
    const fetch = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, fetch), "Fetch lyrics from LRCLIB");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, fetch), "Looks lyrics up on lrclib.net by title, artist, album and duration when the files have none");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, fetch), if (self.lyrics.fetch) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(fetch, "notify::active", gtk.callback(lyricsFetchSwitched), self);
    lyrics_card.add(fetch);

    const view = tab(self, .listening, null, &.{listenbrainz.widget}, &.{ lyrics_card.widget, artistInfoCard(self) });
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
        @intFromEnum(choices.artwork),
        gtk.callback(artworkChosen),
        self,
    ));

    const typeface = flatCard("orca-type-symbolic", "Type", "");
    typeface.add(selectRow(
        "Display typeface",
        "Albums, artists, playlists and Now Playing titles",
        &.{ "Newsreader (serif)", "Same as interface", null },
        @intFromEnum(choices.display_typeface),
        gtk.callback(typefacePicked),
        self,
    ));
    typeface.add(switchRow("Tabular numerals in tables", "Keeps durations and values aligned", choices.tabular_numerals, gtk.callback(numeralsSwitched), self));

    const layout = flatCard("orca-grid-symbolic", "Layout", "");
    layout.add(segmentedRow("Density", "", &.{ "Comfortable", "Compact" }, @intFromEnum(choices.density), gtk.callback(densityChosen), self));
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
        @intFromEnum(choices.inspector),
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

fn copyPathClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const path = self.library_path orelse return;
    copyText(self, path.ptr);
}

fn writeDiagnostics(writer: *std.Io.Writer, self: *App) std.Io.Writer.Error!void {
    try writer.print("Orca {f}\n", .{liborca.version});
    if (self.library) |library| {
        if (self.runtime.libraryStats(library)) |stats| {
            try writer.print("Library: {d} artists, {d} releases, {d} tracks, {d} files, {d} bytes, {d} ms\n", .{
                stats.artists,
                stats.releases,
                stats.tracks,
                stats.files,
                stats.total_bytes,
                stats.total_duration_ms,
            });
        } else |_| try writer.writeAll("Library: unavailable\n");
    } else try writer.writeAll("Library: none open\n");
    try writer.writeAll("\nSignal path\n");
    var buffer: [1024]u8 = undefined;
    const path = self.runtime.playerSignalPath(self.player) catch return writer.writeAll("Unavailable\n");
    try writer.writeAll(signal_path.render(&buffer, path, transport.deviceName(self)));
    try writer.writeByte('\n');
}

fn copyDiagnosticsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeDiagnostics(&writer, self) catch {};
    buffer[writer.end] = 0;
    copyText(self, buffer[0..writer.end :0].ptr);
}

fn advancedTab(self: *App) *gtk.Widget {
    const sources = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(sources, "settings-sources");
    gtk.gtk_box_append(gtk.cast(gtk.Box, sources), sourcesCard(self));
    self.settings_page.sources = gtk.cast(gtk.Box, sources);

    const database = card("drive-harddisk-symbolic", "Library Database", "Your library, ratings, playlists and history live in this file.");
    const path_row = actionRow("Database", if (self.library_path) |path| path.ptr else "No library open");
    gtk.gtk_widget_add_css_class(path_row, "property");
    const copy = suffixButton(path_row, null, "edit-copy-symbolic", gtk.callback(copyPathClicked), self);
    gtk.gtk_widget_set_tooltip_text(copy, "Copy path");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, copy), gtk.ACCESSIBLE_PROPERTY_LABEL, "Copy path", @as(c_int, -1));
    gtk.gtk_widget_set_sensitive(copy, @intFromBool(self.library_path != null));
    database.add(path_row);

    return tab(self, .advanced, sources, &.{database.widget}, &.{});
}

fn aboutTab(self: *App) *gtk.Widget {
    const about = card("orca-wave-symbolic", "About", "The Orca build in use.");
    var version_buffer: [64]u8 = undefined;
    const version = strings.printZ(&version_buffer, "{f}", .{liborca.version}) catch "";
    const version_row = actionRow("Version", version.ptr);
    gtk.gtk_widget_add_css_class(version_row, "property");
    about.add(version_row);
    const backend_row = actionRow("Audio backend", signal_path.audio_backend);
    gtk.gtk_widget_add_css_class(backend_row, "property");
    about.add(backend_row);

    const diagnostics = card("dialog-information-symbolic", "Diagnostics", "For a bug report: the version, the library's totals and the signal path, as text.");
    const copy_row = actionRow("Copy diagnostics", "Copies them to the clipboard. Nothing is sent anywhere.");
    _ = suffixButton(copy_row, "Copy", null, gtk.callback(copyDiagnosticsClicked), self);
    diagnostics.add(copy_row);
    return tab(self, .about, null, &.{about.widget}, &.{diagnostics.widget});
}

const Filter = struct {
    self: *App,
    needle: []const u8,

    fn matches(filter: Filter, text: ?[*:0]const u8) bool {
        const value = text orelse return false;
        return std.ascii.indexOfIgnoreCase(std.mem.span(value), filter.needle) != null;
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
    var first: ?app.SettingsTab = null;
    var current_matches = false;
    for (std.enums.values(app.SettingsTab)) |which| {
        const content = page.contents[@intFromEnum(which)] orelse continue;
        const found = needle.len == 0 or (Filter{ .self = self, .needle = needle }).cards(content);
        if (page.tab_buttons[@intFromEnum(which)]) |button| gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, button), @intFromBool(found));
        if (found and first == null) first = which;
        if (found and which == page.tab) current_matches = true;
    }
    if (!current_matches) if (first) |which| selectTab(self, which);
}

fn columnSpan(which: app.SettingsTab) [2]c_int {
    return if (which == .sound) .{ 3, 2 } else .{ 1, 1 };
}

fn layOut(self: *App, which: app.SettingsTab, narrow: bool) void {
    const grid = self.settings_page.columns[@intFromEnum(which)] orelse return;
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
    self.settings_page.columns[@intFromEnum(which)] = grid;
    layOut(self, which, narrowLayout(self));

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(content, "settings-tab");
    if (top) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, content), widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), grid);
    self.settings_page.contents[@intFromEnum(which)] = content;
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
}

fn stackEqualizerHeader(self: *App) void {
    const header = self.sound_controls.equalizer_header orelse return;
    const orientation = if (iconTabs(self)) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL;
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, header), orientation);
}

pub fn build(self: *App) *gtk.Widget {
    const heading = page_ui.title("Settings");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, heading.title), "settings-title");
    gtk.gtk_label_set_text(heading.meta, "Configure Orca to match your music, your way.");
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
    gtk.g_object_set_data(breakpoint, "orca-settings-fit", @ptrFromInt(@as(usize, @intFromEnum(fit)) + 1));
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(fitApplied), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(fitUnapplied), self);
    adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
}

fn fitOf(breakpoint: ?*anyopaque) app.SettingsFit {
    const tag = @intFromPtr(gtk.g_object_get_data(breakpoint.?, "orca-settings-fit"));
    return @enumFromInt(@as(std.meta.Tag(app.SettingsFit), @intCast(tag - 1)));
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
    page.syncing = true;
    defer page.syncing = false;
    for (page.tab_buttons, 0..) |maybe, index| {
        const button = maybe orelse continue;
        const checked = index == @intFromEnum(page.tab);
        if (checked) gtk.gtk_toggle_button_set_active(button, gtk.true_);
        gtk.gtk_widget_set_focusable(gtk.cast(gtk.Widget, button), @intFromBool(checked));
    }
    if (page.tabs) |stack| adw.adw_view_stack_set_visible_child_name(stack, tab_info.get(page.tab).name);
}

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
        if (candidate == toggle) return selectTab(self, @enumFromInt(index));
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
    const next: usize = @intCast(@mod(@as(isize, @intFromEnum(self.settings_page.tab)) + step, count));
    selectTab(self, @enumFromInt(next));
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
        page.tab_buttons[@intFromEnum(which)] = toggle;
        page.tab_labels[@intFromEnum(which)] = label;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(tabToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, bar), button);
    }
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(tabKeyPressed), self);
    gtk.gtk_widget_add_controller(bar, keys);
    return bar;
}

pub fn show(self: *App) void {
    const page = &self.settings_page;
    const host = page.host orelse return;
    if (page.tabs != null) return;
    const views = adw.adw_view_stack_new();
    const stack = gtk.cast(adw.ViewStack, views);
    page.tabs = stack;
    for (std.enums.values(app.SettingsTab)) |which| {
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
    }
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

pub fn leave(self: *App) void {
    const page = &self.settings_page;
    if (page.tabs == null) return;
    flushPending(self);
    if (page.host) |host| if (page.body) |body| gtk.gtk_box_remove(host, body);
    page.* = .{ .host = page.host, .tab = page.tab, .fit = page.fit };
    self.sound_controls = .{};
    self.listening_controls = .{};
    self.acoustid_controls = .{};
    self.watch_row = null;
    self.maintenance_row = null;
    if (self.equalizer_apply_timer != 0) applyEqualizer(self, equalizerIsOn(self));
    parametric.leave(self);
}
