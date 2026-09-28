//! Preferences: the library's folders and maintenance, and playback choices.
//! Built fresh each time it opens, from the engine's current state.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const settings = @import("settings.zig");
const transport = @import("transport.zig");

const App = app.App;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn group(title: [*:0]const u8, description: ?[*:0]const u8) *gtk.Widget {
    const widget = adw.adw_preferences_group_new();
    adw.adw_preferences_group_set_title(gtk.cast(adw.PreferencesGroup, widget), title);
    adw.adw_preferences_group_set_description(gtk.cast(adw.PreferencesGroup, widget), description);
    return widget;
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

// ------------------------------------------------------------------ library

fn removeRootClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const name = gtk.gtk_widget_get_name(gtk.cast(gtk.Widget, button));
    const root_id = std.fmt.parseInt(i64, std.mem.span(name), 10) catch return;
    self.runtime.libraryRemoveRoot(library, root_id) catch return self.toast("Could not remove that folder");
    const row = gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, button));
    var ancestor = row;
    while (ancestor) |widget| : (ancestor = gtk.gtk_widget_get_parent(widget)) {
        if (gtk.g_object_get_data(widget, "orca-root-row") != null) {
            gtk.gtk_widget_set_visible(widget, gtk.false_);
            break;
        }
    }
    self.toast("Orca won't scan that folder again. Its tracks stay listed for now.");
}

fn addFolderActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    closeDialog(self);
    jobs.chooseFolder(self);
}

fn rescanActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    closeDialog(self);
    jobs.rescan(self);
}

fn measureClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    closeDialog(self);
    jobs.startAnalysis(self);
}

fn duplicatesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    closeDialog(self);
    jobs.startDuplicates(self);
}

fn libraryPage(self: *App) *gtk.Widget {
    const page = adw.adw_preferences_page_new();
    adw.adw_preferences_page_set_title(gtk.cast(adw.PreferencesPage, page), "Library");
    adw.adw_preferences_page_set_icon_name(gtk.cast(adw.PreferencesPage, page), "folder-music-symbolic");
    const library = self.library orelse return page;

    const folders = group("Music Folders", "Orca reads these folders. It never changes a file unless you write tags to it.");
    var roots = self.runtime.libraryRootPage(library, app.page_size, 0) catch null;
    defer if (roots) |*value| value.deinit();
    var buffer: [1024]u8 = undefined;
    if (roots) |value| for (value.items) |root| {
        const row = actionRow(strings.terminated(&buffer, root.path).ptr, if (root.enabled) "" else "Paused");
        gtk.g_object_set_data(row, "orca-root-row", row);
        const remove = suffixButton(row, null, "user-trash-symbolic", gtk.callback(removeRootClicked), self);
        gtk.gtk_widget_set_tooltip_text(remove, "Stop reading this folder");
        const id_text: [:0]const u8 = strings.printZ(&buffer, "{d}", .{root.id}) catch continue;
        gtk.gtk_widget_set_name(remove, id_text.ptr);
        adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, folders), row);
    };
    const add = adw.adw_button_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, add), "Add Folder…");
    adw.adw_button_row_set_start_icon_name(add, "list-add-symbolic");
    _ = gtk.signalConnect(add, "activated", gtk.callback(addFolderActivated), self);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, folders), add);
    const rescan = adw.adw_button_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, rescan), "Rescan All Folders");
    adw.adw_button_row_set_start_icon_name(rescan, "view-refresh-symbolic");
    _ = gtk.signalConnect(rescan, "activated", gtk.callback(rescanActivated), self);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, folders), rescan);
    adw.adw_preferences_page_add(gtk.cast(adw.PreferencesPage, page), gtk.cast(adw.PreferencesGroup, folders));

    const maintenance = group("Maintenance", null);
    const unmeasured = self.runtime.libraryUnanalyzedCount(library) catch 0;
    const measure_text: [:0]const u8 = if (unmeasured == 0)
        "Every file is measured. ReplayGain and duplicate finding use these measurements."
    else
        strings.printZ(&buffer, "{d} files not measured yet. ReplayGain and duplicate finding need this; it decodes every file, so it takes a while and can be stopped.", .{unmeasured}) catch "";
    const measure = actionRow("Measure Loudness", measure_text.ptr);
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, measure), 3);
    const measure_button = suffixButton(measure, "Measure", null, gtk.callback(measureClicked), self);
    if (unmeasured == 0) gtk.gtk_widget_set_sensitive(measure_button, gtk.false_);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, maintenance), measure);
    const duplicates = actionRow("Find Duplicates", "Compares measured audio, so files that are the same recording show up in Health.");
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, duplicates), 3);
    _ = suffixButton(duplicates, "Find", null, gtk.callback(duplicatesClicked), self);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, maintenance), duplicates);
    adw.adw_preferences_page_add(gtk.cast(adw.PreferencesPage, page), gtk.cast(adw.PreferencesGroup, maintenance));
    return page;
}

// ----------------------------------------------------------------- playback

fn replayGainChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row));
    const mode: liborca.ReplayGainMode = if (selected == 1) .track else .off;
    self.runtime.playerSetReplayGainMode(self.player, mode) catch return;
    settings.save(self);
}

fn outputChanged(row: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    transport.selectDevice(self, adw.adw_combo_row_get_selected(gtk.cast(adw.ComboRow, row)));
}

fn playbackPage(self: *App) *gtk.Widget {
    const page = adw.adw_preferences_page_new();
    adw.adw_preferences_page_set_title(gtk.cast(adw.PreferencesPage, page), "Playback");
    adw.adw_preferences_page_set_icon_name(gtk.cast(adw.PreferencesPage, page), "audio-speakers-symbolic");

    const volume = group("Volume", null);
    const modes = [_]?[*:0]const u8{ "Off", "Per Track", null };
    const replay = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, replay), "ReplayGain");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, replay), "Evens out loudness between tracks, using measured loudness");
    const mode_list = gtk.gtk_string_list_new(&modes);
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, replay), gtk.cast(gtk.ListModel, mode_list));
    gtk.g_object_unref(mode_list);
    const mode = self.runtime.playerReplayGainMode(self.player) catch .off;
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, replay), if (mode == .track) 1 else 0);
    _ = gtk.signalConnect(replay, "notify::selected", gtk.callback(replayGainChanged), self);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, volume), replay);
    adw.adw_preferences_page_add(gtk.cast(adw.PreferencesPage, page), gtk.cast(adw.PreferencesGroup, volume));

    const output = group("Output", null);
    transport.refreshDevices(self);
    const names = gtk.gtk_string_list_new(null);
    for (self.device_names.items) |name| gtk.gtk_string_list_append(names, name.ptr);
    const device = adw.adw_combo_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, device), "Output Device");
    adw.adw_combo_row_set_model(gtk.cast(adw.ComboRow, device), gtk.cast(gtk.ListModel, names));
    gtk.g_object_unref(names);
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, device), @intCast(self.device_index));
    _ = gtk.signalConnect(device, "notify::selected", gtk.callback(outputChanged), self);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, output), device);
    adw.adw_preferences_page_add(gtk.cast(adw.PreferencesPage, page), gtk.cast(adw.PreferencesGroup, output));
    return page;
}

// ------------------------------------------------------------------- dialog

fn closeDialog(self: *App) void {
    const dialog = self.preferences_dialog orelse return;
    _ = adw.adw_dialog_close(dialog);
}

fn dialogClosed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    state(data).preferences_dialog = null;
}

pub fn present(self: *App) void {
    const dialog = adw.adw_preferences_dialog_new();
    self.preferences_dialog = dialog;
    _ = gtk.signalConnect(dialog, "closed", gtk.callback(dialogClosed), self);
    adw.adw_preferences_dialog_add(gtk.cast(adw.PreferencesDialog, dialog), gtk.cast(adw.PreferencesPage, libraryPage(self)));
    adw.adw_preferences_dialog_add(gtk.cast(adw.PreferencesDialog, dialog), gtk.cast(adw.PreferencesPage, playbackPage(self)));
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
