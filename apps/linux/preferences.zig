//! Settings: a page of four tabs. Library holds the folders, maintenance and
//! AcoustID; Playback the ReplayGain and output choices; Sound the equalizer
//! and crossfeed; Listening ListenBrainz and lyrics.
//! The tabs are built fresh each time the page is shown, from the engine's
//! current state, and destroyed when it is left.

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

const App = app.App;

const listenbrainz_token_service = liborca.listenbrainz_token_service;
const listenbrainz_token_account = liborca.listenbrainz_token_account;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const Card = struct {
    widget: *gtk.Widget,
    header: *gtk.Widget,
    group: *gtk.Widget,

    fn add(self: Card, row: *gtk.Widget) void {
        adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, self.group), row);
    }
};

fn card(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) Card {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(box, "settings-card");
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    const image = gtk.gtk_image_new_from_icon_name(icon);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), 24);
    gtk.gtk_widget_set_valign(image, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(image, "settings-card-icon");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    const heading = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(heading, "settings-card-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0);
    const meta = gtk.gtk_label_new(description);
    gtk.gtk_widget_add_css_class(meta, "meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, meta), gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), meta);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), image);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), text);
    const rows = adw.adw_preferences_group_new();
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), rows);
    return .{ .widget = box, .header = header, .group = rows };
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

fn removeRootClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const name = gtk.gtk_widget_get_name(gtk.cast(gtk.Widget, button));
    const root_id = std.fmt.parseInt(i64, std.mem.span(name), 10) catch return;
    var roots = self.runtime.libraryRootPage(library, app.page_size, 0) catch return self.toast("Could not remove that folder");
    defer roots.deinit();
    const path = for (roots.items) |root| {
        if (root.id == root_id) break root.path;
    } else return;

    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const folder = if (slash) |index| trimmed[index + 1 ..] else trimmed;
    var buffer: [1024]u8 = undefined;
    const heading = strings.printZ(&buffer, "Remove “{s}”?", .{if (folder.len == 0) path else folder}) catch "Remove this folder?";
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Its songs leave the library. The files on disk are not touched.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "remove", "Remove");
    adw.adw_alert_dialog_set_response_appearance(alert, "remove", adw.RESPONSE_DESTRUCTIVE);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    const pending = self.allocator.create(PendingRemoval) catch return;
    pending.* = .{ .self = self, .root_id = root_id };
    _ = gtk.signalConnect(dialog, "response", gtk.callback(removeRootResponse), pending);
    adw.adw_dialog_present(dialog, gtk.cast(gtk.Widget, button));
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
        if (removed.tracks_removed == 1) "song" else "songs",
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
    if (!self.watch_folders) return "";
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
    matches.reload(self);
}

fn fingerprintsSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    if (enabled == self.match_fingerprints) return;
    self.match_fingerprints = enabled;
    settings.save(self);
    matches.reload(self);
    maintenance.apply(self) catch self.toast("Could not change idle maintenance");
    showMaintenanceStatus(self);
    self.requestTick();
}

const acoustid_key_url = "https://acoustid.org/api-key";

fn keyPageLaunched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_uri_launcher_launch_finish(gtk.cast(gtk.UriLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open AcoustID");
}

fn getKeyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const launcher = gtk.gtk_uri_launcher_new(acoustid_key_url);
    gtk.gtk_uri_launcher_launch(launcher, self.window, null, keyPageLaunched, self);
    gtk.g_object_unref(launcher);
}

fn acoustIdCard(self: *App) *gtk.Widget {
    const acoustid = card(
        "auth-fingerprint-symbolic",
        "AcoustID",
        "AcoustID identifies songs by their sound. With your key, the matches you accept can be sent back from the Matches page, so others can identify them too.",
    );
    const fingerprints = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, fingerprints), "Match by audio fingerprint");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, fingerprints), "Find Matches also sends a fingerprint of each song's audio to AcoustID");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, fingerprints), if (self.match_fingerprints) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(fingerprints, "notify::active", gtk.callback(fingerprintsSwitched), self);
    acoustid.add(fingerprints);

    AcoustIdKey.add(self, acoustid);

    const link = actionRow("Need a key?", "Sign in to AcoustID, copy your API key, paste it above and choose Save.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, link), 3);
    const get_key = suffixButton(link, "Get a key", null, gtk.callback(getKeyClicked), self);
    gtk.gtk_widget_add_css_class(get_key, "flat");
    adw.adw_action_row_set_activatable_widget(gtk.cast(adw.ActionRow, link), get_key);
    acoustid.add(link);
    AcoustIdKey.checkOnce(self);
    return acoustid.widget;
}

fn folderRows(self: *App, library: liborca.LibraryHandle) *gtk.Widget {
    const rows = adw.adw_preferences_group_new();
    var roots = self.runtime.libraryRootPage(library, app.page_size, 0) catch return rows;
    defer roots.deinit();
    var buffer: [1024]u8 = undefined;
    for (roots.items) |root| {
        const row = actionRow(strings.terminated(&buffer, root.path).ptr, if (root.enabled) "" else "Paused");
        adw.adw_action_row_add_prefix(gtk.cast(adw.ActionRow, row), gtk.gtk_image_new_from_icon_name("folder-symbolic"));
        const remove = suffixButton(row, null, "user-trash-symbolic", gtk.callback(removeRootClicked), self);
        gtk.gtk_widget_set_tooltip_text(remove, "Stop reading this folder");
        const id_text: [:0]const u8 = strings.printZ(&buffer, "{d}", .{root.id}) catch continue;
        gtk.gtk_widget_set_name(remove, id_text.ptr);
        adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, rows), row);
    }
    return rows;
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
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), labelledButton("Add Folder…", "list-add-symbolic", gtk.callback(addFolderActivated), self));
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
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, threshold), "Percent. Accept Confident on the Matches page takes a song's best match scoring this or more.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, threshold), 3);
    adw.adw_spin_row_set_digits(gtk.cast(adw.SpinRow, threshold), 0);
    adw.adw_spin_row_set_value(gtk.cast(adw.SpinRow, threshold), @floatFromInt(self.match_threshold_percent));
    _ = gtk.signalConnect(threshold, "notify::value", gtk.callback(thresholdChanged), self);
    maintenance_card.add(threshold);
    return maintenance_card.widget;
}

fn libraryTab(self: *App) *gtk.Widget {
    const library = self.library orelse return tab(self, .library, &.{}, &.{});
    return tab(self, .library, &.{ foldersCard(self, library), maintenanceCard(self) }, &.{acoustIdCard(self)});
}

fn replayGainChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row));
    const mode: liborca.ReplayGainMode = if (selected == 1) .track else .off;
    self.runtime.playerSetReplayGainMode(self.player, mode) catch return;
    transport.refreshSignalPath(self);
    settings.save(self);
}

fn outputChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    transport.selectDevice(self, adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row)));
}

fn playbackTab(self: *App) *gtk.Widget {
    const volume = card("multimedia-volume-control-symbolic", "Volume", "ReplayGain plays each song at the loudness Measure Loudness found for it.");
    const modes = [_]?[*:0]const u8{ "Off", "Per Track", null };
    const replay = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, replay), "ReplayGain");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, replay), "Evens out loudness between songs, using measured loudness");
    const mode_list = gtk.gtk_string_list_new(&modes);
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, replay), gtk.cast(gtk.ListModel, mode_list));
    gtk.g_object_unref(mode_list);
    const mode = self.runtime.playerReplayGainMode(self.player) catch .off;
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, replay), if (mode == .track) 1 else 0);
    _ = gtk.signalConnect(replay, "notify::selected", gtk.callback(replayGainChanged), self);
    volume.add(replay);

    const output = card("audio-card-symbolic", "Output", "Where Orca plays. The device is remembered by name.");
    transport.refreshDevices(self);
    const names = gtk.gtk_string_list_new(null);
    for (self.device_names.items) |name| gtk.gtk_string_list_append(names, name.ptr);
    const device = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, device), "Output Device");
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, device), gtk.cast(gtk.ListModel, names));
    gtk.g_object_unref(names);
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, device), @intCast(self.device_index));
    _ = gtk.signalConnect(device, "notify::selected", gtk.callback(outputChanged), self);
    output.add(device);
    return tab(self, .playback, &.{volume.widget}, &.{output.widget});
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

fn equalizerSwitched(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const enabled = adw.adw_switch_row_get_active(gtk.cast(adw.SwitchRow, row)) != 0;
    showEqualizerEnabled(self, enabled);
    applyEqualizer(self, enabled);
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

fn soundTab(self: *App) *gtk.Widget {
    const controls = &self.sound_controls;

    const current = self.runtime.playerEqualizer(self.player) catch null;
    if (current) |curve| self.equalizer_curve = curve;
    const curve = self.equalizer_curve;

    const equalizer = card("emblem-system-symbolic", "Equalizer", "Ten bands from 31 Hz to 16 kHz, applied to everything Orca plays.");
    const enabled = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, enabled), "Equalizer");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, enabled), if (current != null) gtk.true_ else gtk.false_);
    equalizer.add(enabled);

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
    showEqualizerEnabled(self, current != null);

    _ = gtk.signalConnect(enabled, "notify::active", gtk.callback(equalizerSwitched), self);
    _ = gtk.signalConnect(preset.row, "notify::selected", gtk.callback(presetChanged), self);
    _ = gtk.signalConnect(preamp, "notify::value", gtk.callback(preampChanged), self);

    const headphones = card("audio-headphones-symbolic", "Headphones", "Crossfeed for listening on headphones.");
    const crossfeed_amount = self.runtime.playerCrossfeed(self.player) catch null;
    if (crossfeed_amount) |amount| self.crossfeed_amount = amount;
    const crossfeed = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, crossfeed), "Crossfeed");
    adw.adw_action_row_set_subtitle(
        gtk.cast(adw.ActionRow, crossfeed),
        "Blends a little of each channel into the other, for headphones",
    );
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, crossfeed), if (crossfeed_amount != null) gtk.true_ else gtk.false_);
    headphones.add(crossfeed);
    const amount = comboRow("Amount", &amount_labels);
    controls.crossfeed_amount_row = amount.row;
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, amount.row), nearestAmountIndex(self.crossfeed_amount));
    gtk.gtk_widget_set_sensitive(amount.row, if (crossfeed_amount != null) gtk.true_ else gtk.false_);
    headphones.add(amount.row);
    _ = gtk.signalConnect(crossfeed, "notify::active", gtk.callback(crossfeedSwitched), self);
    _ = gtk.signalConnect(amount.row, "notify::selected", gtk.callback(crossfeedAmountChanged), self);
    return tab(self, .sound, &.{equalizer.widget}, &.{headphones.widget});
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
            const visible = presence != .absent;
            gtk.gtk_widget_set_visible(stored_row, if (visible) gtk.true_ else gtk.false_);
            const subtitle: [*:0]const u8 = switch (presence) {
                .absent, .stored => "Saved in your keyring",
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
            if (controls.entry_row) |row|
                adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), if (presence == .stored) credential.replace_title else credential.title);
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
            if (credential.controls(self).entry_row) |row| gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, row), "");
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
            const stored_row = actionRow(credential.title, "Saved in your keyring");
            gtk.gtk_widget_set_visible(stored_row, gtk.false_);
            const remove_button = suffixButton(stored_row, "Remove", null, gtk.callback(removeClicked), self);
            const unlock_button = suffixButton(stored_row, "Unlock", null, gtk.callback(unlockClicked), self);
            gtk.gtk_widget_set_visible(unlock_button, gtk.false_);
            target.add(stored_row);

            const entry = adw.adw_password_entry_row_new();
            adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, entry), credential.title);
            const save_button = gtk.gtk_button_new_with_label("Save");
            gtk.gtk_widget_set_valign(save_button, gtk.ALIGN_CENTER);
            gtk.gtk_widget_add_css_class(save_button, "suggested-action");
            gtk.gtk_widget_set_sensitive(save_button, gtk.false_);
            _ = gtk.signalConnect(save_button, "clicked", gtk.callback(saveClicked), self);
            adw.adw_entry_row_add_suffix(gtk.cast(adw.EntryRow, entry), save_button);
            _ = gtk.signalConnect(entry, "entry-activated", gtk.callback(entryActivated), self);
            _ = gtk.signalConnect(entry, "changed", gtk.callback(entryTyped), self);
            target.add(entry);

            credential.controls(self).* = .{
                .entry_row = entry,
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
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, now_playing), "Sends the current song to ListenBrainz once it has played for 10 seconds");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, now_playing), if (self.announce_now_playing) gtk.true_ else gtk.false_);
    gtk.gtk_widget_set_sensitive(now_playing, if (self.library != null and self.scrobbling) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(now_playing, "notify::active", gtk.callback(nowPlayingSwitched), self);
    listenbrainz.add(now_playing);

    ListenBrainzToken.add(self, listenbrainz);

    const link = actionRow("Get your token", "Copy it from your ListenBrainz settings, paste it above and choose Save.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, link), 3);
    const link_button = gtk.gtk_link_button_new_with_label(token_settings_url, "listenbrainz.org/settings");
    gtk.gtk_widget_set_valign(link_button, gtk.ALIGN_CENTER);
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
        "Lyrics come from .lrc files beside your songs and from their tags. Orca never writes lyrics to a file.",
    );
    const fetch = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, fetch), "Fetch lyrics from LRCLIB");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, fetch), "Looks lyrics up on lrclib.net by title, artist, album and duration when the files have none");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, fetch), if (self.lyrics.fetch) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(fetch, "notify::active", gtk.callback(lyricsFetchSwitched), self);
    lyrics_card.add(fetch);

    const view = tab(self, .listening, &.{listenbrainz.widget}, &.{lyrics_card.widget});
    _ = gtk.signalConnect(view, "map", gtk.callback(listeningMapped), self);
    return view;
}

fn layOut(columns: *gtk.Widget, narrow: bool) void {
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, columns), if (narrow) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, columns), if (narrow) gtk.false_ else gtk.true_);
}

fn tab(self: *App, which: app.SettingsTab, left: []const *gtk.Widget, right: []const *gtk.Widget) *gtk.Widget {
    const columns = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(columns, "settings-columns");
    for ([_][]const *gtk.Widget{ left, right }) |cards| {
        const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
        gtk.gtk_widget_set_valign(column, gtk.ALIGN_START);
        gtk.gtk_widget_set_hexpand(column, gtk.true_);
        for (cards) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, column), widget);
        gtk.gtk_box_append(gtk.cast(gtk.Box, columns), column);
    }
    layOut(columns, self.window_narrow);
    self.settings_page.columns[@intFromEnum(which)] = columns;
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), columns);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    return scroller;
}

pub fn setNarrow(self: *App) void {
    for (self.settings_page.columns) |columns| if (columns) |widget| layOut(widget, self.window_narrow);
}

pub fn build(self: *App) *gtk.Widget {
    const heading = page_ui.title("Settings");
    const icon = gtk.gtk_image_new_from_icon_name("emblem-system-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 40);
    gtk.gtk_widget_add_css_class(icon, "settings-page-icon");
    gtk.gtk_box_prepend(gtk.cast(gtk.Box, heading.widget), icon);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, heading.meta), gtk.false_);

    const host = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, host), heading.widget);
    self.settings_page.host = gtk.cast(gtk.Box, host);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), page_ui.header());
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), host);
    return view;
}

const tab_names = [_][*:0]const u8{ "library", "playback", "sound", "listening" };

pub fn show(self: *App) void {
    const page = &self.settings_page;
    const host = page.host orelse return;
    if (page.tabs != null) return;
    const views = adw.adw_view_stack_new();
    const stack = gtk.cast(adw.ViewStack, views);
    page.tabs = stack;
    _ = adw.adw_view_stack_add_titled_with_icon(stack, libraryTab(self), tab_names[0], "Library", "folder-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, playbackTab(self), tab_names[1], "Playback", "audio-volume-high-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, soundTab(self), tab_names[2], "Sound", "audio-headphones-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, listeningTab(self), tab_names[3], "Listening", "document-open-recent-symbolic");
    adw.adw_view_stack_set_visible_child_name(stack, tab_names[@intFromEnum(page.tab)]);
    gtk.gtk_widget_set_vexpand(views, gtk.true_);

    const switcher = adw.adw_view_switcher_new();
    adw.adw_view_switcher_set_stack(gtk.cast(adw.ViewSwitcher, switcher), stack);
    adw.adw_view_switcher_set_policy(gtk.cast(adw.ViewSwitcher, switcher), adw.VIEW_SWITCHER_POLICY_WIDE);
    gtk.gtk_widget_add_css_class(switcher, "settings-tabs");
    gtk.gtk_widget_set_hexpand(switcher, gtk.true_);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "settings-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), switcher);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), views);
    gtk.gtk_box_append(host, body);
    page.body = body;
}

pub fn leave(self: *App) void {
    const page = &self.settings_page;
    const stack = page.tabs orelse return;
    if (adw.adw_view_stack_get_visible_child_name(stack)) |name| {
        for (tab_names, 0..) |candidate, index| {
            if (std.mem.eql(u8, std.mem.span(name), std.mem.span(candidate))) page.tab = @enumFromInt(index);
        }
    }
    if (page.host) |host| if (page.body) |body| gtk.gtk_box_remove(host, body);
    page.* = .{ .host = page.host, .tab = page.tab };
    self.sound_controls = .{};
    self.listening_controls = .{};
    self.acoustid_controls = .{};
    self.watch_row = null;
    self.maintenance_row = null;
    if (self.equalizer_apply_timer != 0) applyEqualizer(self, equalizerIsOn(self));
}
