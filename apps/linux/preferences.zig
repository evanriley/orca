//! Preferences: the library's folders and maintenance, playback choices, and
//! the sound: equalizer and crossfeed.
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

// -------------------------------------------------------------------- sound

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

fn dialogToast(self: *App, message: [:0]const u8) void {
    const dialog = self.preferences_dialog orelse return self.toast(message);
    const item = adw.adw_toast_new(message.ptr);
    adw.adw_toast_set_timeout(item, 3);
    adw.adw_preferences_dialog_add_toast(gtk.cast(adw.PreferencesDialog, dialog), item);
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
        return dialogToast(self, "Could not apply the equalizer");
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
        return dialogToast(self, "Could not apply crossfeed");
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

fn soundPage(self: *App) *gtk.Widget {
    const page = adw.adw_preferences_page_new();
    adw.adw_preferences_page_set_title(gtk.cast(adw.PreferencesPage, page), "Sound");
    adw.adw_preferences_page_set_icon_name(gtk.cast(adw.PreferencesPage, page), "audio-headphones-symbolic");
    const controls = &self.sound_controls;

    const current = self.runtime.playerEqualizer(self.player) catch null;
    if (current) |curve| self.equalizer_curve = curve;
    const curve = self.equalizer_curve;

    const equalizer = group("Equalizer", null);
    const enabled = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, enabled), "Equalizer");
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, enabled), if (current != null) gtk.true_ else gtk.false_);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, equalizer), enabled);

    const preset = comboRow("Preset", &preset_labels);
    controls.preset_row = preset.row;
    controls.preset_names = preset.names;
    showPreset(self, matchingPreset(curve));
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, equalizer), preset.row);

    controls.bands = bandSliders(self, curve);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, equalizer), controls.bands.?);

    const preamp = adw.adw_spin_row_new_with_range(preamp_range_db[0], preamp_range_db[1], 0.5);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, preamp), "Preamp");
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, preamp), "Decibels. Lower it if boosted bands distort");
    adw.adw_spin_row_set_digits(gtk.cast(adw.SpinRow, preamp), 1);
    controls.preamp_row = preamp;
    showCurve(self, curve);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, equalizer), preamp);
    showEqualizerEnabled(self, current != null);
    adw.adw_preferences_page_add(gtk.cast(adw.PreferencesPage, page), gtk.cast(adw.PreferencesGroup, equalizer));

    _ = gtk.signalConnect(enabled, "notify::active", gtk.callback(equalizerSwitched), self);
    _ = gtk.signalConnect(preset.row, "notify::selected", gtk.callback(presetChanged), self);
    _ = gtk.signalConnect(preamp, "notify::value", gtk.callback(preampChanged), self);

    const headphones = group("Headphones", null);
    const crossfeed_amount = self.runtime.playerCrossfeed(self.player) catch null;
    if (crossfeed_amount) |amount| self.crossfeed_amount = amount;
    const crossfeed = adw.adw_switch_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, crossfeed), "Crossfeed");
    adw.adw_action_row_set_subtitle(
        gtk.cast(adw.ActionRow, crossfeed),
        "Blends a little of each channel into the other, for headphones",
    );
    adw.adw_switch_row_set_active(gtk.cast(adw.SwitchRow, crossfeed), if (crossfeed_amount != null) gtk.true_ else gtk.false_);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, headphones), crossfeed);
    const amount = comboRow("Amount", &amount_labels);
    controls.crossfeed_amount_row = amount.row;
    adw.adw_combo_row_set_selected(gtk.cast(adw.ComboRow, amount.row), nearestAmountIndex(self.crossfeed_amount));
    gtk.gtk_widget_set_sensitive(amount.row, if (crossfeed_amount != null) gtk.true_ else gtk.false_);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, headphones), amount.row);
    adw.adw_preferences_page_add(gtk.cast(adw.PreferencesPage, page), gtk.cast(adw.PreferencesGroup, headphones));
    _ = gtk.signalConnect(crossfeed, "notify::active", gtk.callback(crossfeedSwitched), self);
    _ = gtk.signalConnect(amount.row, "notify::selected", gtk.callback(crossfeedAmountChanged), self);
    return page;
}

// ------------------------------------------------------------------- dialog

fn closeDialog(self: *App) void {
    const dialog = self.preferences_dialog orelse return;
    _ = adw.adw_dialog_close(dialog);
}

fn dialogClosed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.preferences_dialog = null;
    self.sound_controls = .{};
    if (self.equalizer_apply_timer != 0) applyEqualizer(self, equalizerIsOn(self));
}

pub fn present(self: *App) void {
    const dialog = adw.adw_preferences_dialog_new();
    self.preferences_dialog = dialog;
    _ = gtk.signalConnect(dialog, "closed", gtk.callback(dialogClosed), self);
    adw.adw_preferences_dialog_add(gtk.cast(adw.PreferencesDialog, dialog), gtk.cast(adw.PreferencesPage, libraryPage(self)));
    adw.adw_preferences_dialog_add(gtk.cast(adw.PreferencesDialog, dialog), gtk.cast(adw.PreferencesPage, playbackPage(self)));
    adw.adw_preferences_dialog_add(gtk.cast(adw.PreferencesDialog, dialog), gtk.cast(adw.PreferencesPage, soundPage(self)));
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
