//! The player bar: now playing, transport, seek, volume, shuffle, repeat, the
//! source format and Signal Path, and the output device chooser.
//!
//! Position and duration are read from `playerStatus` and rendered. They are
//! never adjusted, cached across tracks, or reconstructed from telemetry: that
//! is engine state and it belongs to liborca.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const mpris = @import("mpris.zig");
const notify = @import("notify.zig");
const window = @import("window.zig");
const art = @import("art.zig");
const nowplaying = @import("nowplaying.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const artist_page = @import("artist_page.zig");
const genres = @import("genres.zig");
const folders = @import("folders.zig");
const palette = @import("palette.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const signal_path = @import("signal_path.zig");
const details = @import("details.zig");
const lyrics = @import("lyrics.zig");
const feedback = @import("feedback.zig");
const preferences = @import("preferences.zig");
const parametric = @import("parametric.zig");
const radio = @import("radio.zig");
const home = @import("home.zig");

const App = app.App;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn isNotReady(err: anyerror) bool {
    return switch (err) {
        error.PlayerHasNoSource,
        error.PlayerHasNoOutput,
        error.PlayerHasNoLibrary,
        error.PlayerBoundToAnotherLibrary,
        error.LibraryHasNoDatabase,
        => true,
        else => false,
    };
}

const max_devices = 32;

/// The output the next Zone should open.
///
/// `ORCA_OUTPUT_DEVICE` overrides the dropdown, naming an orca device id from
/// `orca-cli devices`. It exists so an automated run can be pinned to a silent
/// sink: device 0 means "system default", which on a developer's machine is
/// their speakers, and a test that plays to them is unacceptable. It mirrors
/// `ORCA_LIBRARY`, and like it is a development affordance rather than
/// configuration -- a person picks their device from the dropdown.
fn selectedDeviceId(self: *App) u64 {
    if (self.pinned_output_device) |pinned| return pinned;
    if (self.device_index >= self.device_ids.items.len) return 0;
    return self.device_ids.items[self.device_index];
}

const max_rows = max_devices + 1;

const SummaryLine = enum { sending, mode, supports };

const Picker = struct {
    bar: ?*gtk.Widget = null,
    button: ?*gtk.Widget = null,
    bar_name: ?*gtk.Label = null,
    summary: ?*gtk.Widget = null,
    lines: [3]?*gtk.Widget = .{ null, null, null },
    values: [3]?*gtk.Label = .{ null, null, null },
    volume_value: ?*gtk.Label = null,
    capabilities: [max_rows]?liborca.DeviceCapabilities = @splat(null),
};

var picker: Picker = .{};

const picker_gap: c_int = 8;

fn deviceIcon(kind: liborca.DeviceKind, system_default: bool) [*:0]const u8 {
    if (system_default) return "orca-device-speaker-symbolic";
    return switch (kind) {
        .usb => "orca-device-dac-symbolic",
        .hdmi => "orca-device-tv-symbolic",
        .bluetooth => "orca-device-bluetooth-symbolic",
        .unknown, .pci, .virtual => "orca-device-speaker-symbolic",
    };
}

fn deviceRow(
    self: *App,
    name: [:0]const u8,
    kind: liborca.DeviceKind,
    capabilities: ?liborca.DeviceCapabilities,
) void {
    const system_default = self.device_names.items.len == 0;
    if (self.allocator.dupeSentinel(u8, name, 0)) |owned| {
        self.device_names.append(self.allocator, owned) catch self.allocator.free(owned);
    } else |_| {}
    const list = self.device_list orelse return;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "device-row");
    if (capabilities) |known| if (known.state == .unavailable) gtk.gtk_widget_add_css_class(row, "unavailable");

    const icon_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(icon_box, "device-icon");
    gtk.gtk_widget_set_valign(icon_box, gtk.ALIGN_CENTER);
    const icon = gtk.gtk_image_new_from_icon_name(deviceIcon(kind, system_default));
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), bar_icon_pixels);
    gtk.gtk_widget_set_hexpand(icon, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, icon_box), icon);
    gtk.gtk_widget_set_hexpand(icon_box, gtk.false_);

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    const label = gtk.gtk_label_new(name.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1);
    gtk.gtk_widget_add_css_class(label, "device-name");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), label);
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (system_default)
        writer.writeAll(signal_path.system_default_note) catch {}
    else
        signal_path.writeDeviceNote(&writer, kind, capabilities) catch {};
    if (writer.end != 0) {
        buffer[writer.end] = 0;
        const note = gtk.gtk_label_new(buffer[0..writer.end :0].ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, note), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, note), gtk.ELLIPSIZE_END);
        gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, note), 1);
        gtk.gtk_widget_add_css_class(note, "device-note");
        if (!system_default and kind == .bluetooth) gtk.gtk_widget_add_css_class(note, "caution");
        gtk.gtk_box_append(gtk.cast(gtk.Box, labels), note);
    }

    const check = gtk.gtk_image_new_from_icon_name("orca-check-symbolic");
    gtk.gtk_widget_add_css_class(check, "device-check");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), icon_box);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), labels);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), check);
    gtk.gtk_list_box_append(list, row);
    if (capabilities) |known| if (known.state == .unavailable) {
        if (gtk.gtk_widget_get_parent(row)) |list_row| gtk.gtk_widget_set_sensitive(list_row, gtk.false_);
    };
    self.device_checks.append(self.allocator, check) catch {};
    const index = self.device_checks.items.len - 1;
    if (index < max_rows) picker.capabilities[index] = capabilities;
}

pub fn deviceName(self: *const App) [:0]const u8 {
    if (self.device_index < self.device_names.items.len) return self.device_names.items[self.device_index];
    return "Output";
}

pub fn deviceCapabilities(self: *const App) ?liborca.DeviceCapabilities {
    return if (self.device_index < max_rows) picker.capabilities[self.device_index] else null;
}

fn showSelectedDevice(self: *App) void {
    for (self.device_checks.items, 0..) |check, index| {
        const chosen = index == self.device_index;
        gtk.gtk_widget_set_opacity(check, if (chosen) 1.0 else 0.0);
        const content = gtk.gtk_widget_get_parent(check) orelse continue;
        const row = gtk.gtk_widget_get_parent(content) orelse continue;
        if (chosen)
            gtk.gtk_widget_add_css_class(row, "chosen")
        else
            gtk.gtk_widget_remove_css_class(row, "chosen");
    }
    preferences.showOutputDevice(self);
    showDeviceSupports(self);
    const label = picker.bar_name orelse return;
    const name = deviceName(self);
    gtk.gtk_label_set_text(label, name.ptr);
    gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, label), name.ptr);
}

/// Every caller but the picker opening asks for `.identity`: `.capabilities`
/// waits on each device and would stall the UI thread.
pub fn refreshDevices(self: *App) void {
    readDevices(self, .identity);
}

fn readDevices(self: *App, detail: liborca.DiscoveryDetail) void {
    const list = self.device_list orelse return;

    var devices: [max_devices]liborca.Device = undefined;
    const count = self.runtime.enumerateOutputDevices(&devices, detail) catch 0;

    gtk.gtk_list_box_remove_all(list);
    self.device_ids.clearRetainingCapacity();
    self.device_checks.clearRetainingCapacity();
    for (self.device_names.items) |name| self.allocator.free(name);
    self.device_names.clearRetainingCapacity();
    picker.capabilities = @splat(null);
    // Id 0 is "let the server decide", which is what a single-output frontend
    // should default to.
    deviceRow(self, "System default", .unknown, null);
    self.device_ids.append(self.allocator, 0) catch {};

    var buffer: [288]u8 = undefined;
    for (devices[0..count]) |*device| {
        const label = if (device.name_len != 0)
            strings.printZ(&buffer, "{s}", .{device.nameSlice()}) catch continue
        else
            strings.printZ(&buffer, "Device {d}", .{device.id}) catch continue;
        deviceRow(self, label, device.kind, device.capabilities);
        self.device_ids.append(self.allocator, device.id) catch {};
    }
    self.device_index = 0;
    for (self.device_names.items, 0..) |name, index| {
        if (index != 0 and std.mem.eql(u8, name, self.preferred_output.value)) self.device_index = index;
    }
    if (self.pinned_output_device) |pinned| {
        for (self.device_ids.items, 0..) |id, index| {
            if (id == pinned) self.device_index = index;
        }
    }
    showSelectedDevice(self);
}

/// Opens an output if the Player has none. Returns false when no backend or
/// device is available, which is a real condition, not an error to swallow.
pub fn ensureOutput(self: *App) bool {
    if (outputFailed(self)) {
        self.runtime.destroyZone(self.zone.?) catch {};
        self.zone = null;
    }
    if (self.zone != null) return true;
    const zone = self.runtime.playerOpenDefaultOutput(
        self.player,
        selectedDeviceId(self),
    ) catch return false;
    self.zone = zone;
    return true;
}

pub fn restoreAtLaunch(self: *App) void {
    const library = self.library orelse return;
    const mode: liborca.RestoreMode = switch (self.playback.on_launch) {
        .restore_paused => .paused,
        .restore_playing => if (ensureOutput(self)) .playing else .paused,
        .start_empty => .none,
    };
    const outcome = self.runtime.playerRestoreState(self.player, library, mode) catch
        return self.toast("Could not restore the last queue");
    if (outcome.entries == 0) if (self.zone) |zone| {
        self.runtime.destroyZone(zone) catch {};
        self.zone = null;
    };
    self.mpris.notify();
    self.requestTick();
}

pub fn applyLongTrackMemory(self: *App) void {
    const threshold_ms: ?u64 = if (self.playback.remember_long_position) long_track_ms else null;
    self.runtime.playerSetLongTrackMemory(self.player, threshold_ms) catch {};
}

const long_track_ms: u64 = 20 * std.time.ms_per_min;

fn deviceActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0) return;
    selectDevice(self, @intCast(index));
}

/// Makes the output at `index` in the output menu the one playback uses, and
/// remembers it by name.
pub fn selectDevice(self: *App, index: usize) void {
    if (index >= self.device_ids.items.len or index == self.device_index) return;
    self.device_index = index;
    showSelectedDevice(self);
    self.preferred_output.set(self.allocator, if (index == 0) "" else self.device_names.items[index]);
    settings.save(self);
    if (self.pinned_output_device != null) {
        self.toast("The output is pinned by ORCA_OUTPUT_DEVICE");
        return;
    }
    if (parametric.applyDevicePreset(self, self.device_names.items[index])) preferences.showEqualizer(self);
    // Only an open output moves; one that was never opened waits for the
    // next play, as at launch.
    const zone = self.zone orelse return;
    self.runtime.destroyZone(zone) catch {};
    self.zone = null;
    if (!ensureOutput(self)) self.toast("Could not open that output device");
    refreshSignalPath(self);
    self.requestTick();
}

pub fn playIds(self: *App, ids: []const i64, start: u32) void {
    if (ids.len == 0) return;
    if (!ensureOutput(self)) {
        self.toast("No audio output is available");
        return;
    }
    const library = (self.runtime.playerLibrary(self.player) catch null) orelse {
        self.toast("The player is not ready");
        return;
    };
    if (ids.len == 1) {
        // Async through the control lane: the outcome arrives as a completion
        // event correlated by this request id, drained on the tick `submit` wakes.
        const request = self.runtime.submit(.{ .play_track = .{
            .player = self.player,
            .library = library,
            .track_id = ids[0],
        } }) catch {
            self.toast("Could not start playback");
            return;
        };
        self.pending_play_request = request;
        return;
    }
    self.runtime.playerPlayTracksBound(self.player, library, ids, start) catch {
        self.toast("Could not start playback");
        return;
    };
    self.requestTick();
}

pub fn toggle(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;
    if (status.transport != .playing and status.queue_length != 0 and !ensureOutput(self))
        return self.toast("No audio output is available");
    const result = if (status.transport == .playing)
        self.runtime.pausePlayer(self.player)
    else
        self.runtime.playPlayer(self.player);
    result catch |err| {
        if (isNotReady(err)) self.toast("Nothing to play yet — double-click a track");
    };
    self.mpris.notify();
    self.requestTick();
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    toggle(state(data));
}

pub fn previous(self: *App) void {
    _ = self.runtime.playerPrevious(self.player) catch {};
    self.mpris.notify();
    self.requestTick();
}

pub fn next(self: *App) void {
    const moved = self.runtime.playerNext(self.player) catch true;
    if (!moved) self.toast("End of the queue");
    self.mpris.notify();
    self.requestTick();
}

fn previousClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    previous(state(data));
}

fn nextClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    next(state(data));
}

pub fn toggleShuffle(self: *App) void {
    const button = self.transport_controls.shuffle orelse return;
    const shuffle = gtk.cast(gtk.ToggleButton, button);
    gtk.gtk_toggle_button_set_active(shuffle, if (gtk.gtk_toggle_button_get_active(shuffle) != 0) gtk.false_ else gtk.true_);
}

fn shuffleToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_widget_writeback) return;
    const active = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
    self.runtime.playerSetShuffle(self.player, active) catch {};
    self.requestTick();
}

fn repeatClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    cycleRepeat(state(data));
}

pub fn cycleRepeat(self: *App) void {
    self.repeat_mode = switch (self.repeat_mode) {
        .off => .all,
        .all => .one,
        .one => .off,
    };
    self.runtime.playerSetRepeat(self.player, self.repeat_mode) catch return;
    showRepeat(self, self.repeat_mode);
}

pub fn showRepeat(self: *App, mode: liborca.RepeatMode) void {
    const button = self.transport_controls.repeat orelse return;
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), if (mode == .one)
        "orca-repeat-one-symbolic"
    else
        "orca-repeat-symbolic");
    if (mode == .off)
        gtk.gtk_widget_remove_css_class(button, "engaged")
    else
        gtk.gtk_widget_add_css_class(button, "engaged");
}

fn radioClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    radio.toggle(state(data));
}

/// Shows whether a Radio session is running on the bar's Radio button.
pub fn showRadio(self: *App, on: bool) void {
    const button = self.transport_controls.radio orelse return;
    const name: [*:0]const u8 = if (on) "Radio on" else "Radio off";
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, name, @as(c_int, -1));
    if (on)
        gtk.gtk_widget_add_css_class(button, "engaged")
    else
        gtk.gtk_widget_remove_css_class(button, "engaged");
}

fn volumeChanged(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const value = gtk.gtk_adjustment_get_value(gtk.cast(gtk.Adjustment, adjustment));
    showVolumeIcon(self, value);
    if (self.suppress_widget_writeback) return;
    self.runtime.playerSetVolume(self.player, @floatCast(value)) catch {};
    if (self.volume_settle_timer != 0) _ = gtk.g_source_remove(self.volume_settle_timer);
    self.volume_settle_timer = gtk.g_timeout_add(volume_settle_ms, volumeSettled, self);
}

const volume_settle_ms: c_uint = 250;

fn volumeSettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.volume_settle_timer = 0;
    settings.save(self);
    if (details.shownMode(self) == .signal_path) refreshSignalPath(self);
    return gtk.SOURCE_REMOVE;
}

fn showVolumeIcon(self: *App, level: f64) void {
    if (picker.volume_value) |label| {
        var buffer: [8]u8 = undefined;
        const text = strings.printZ(&buffer, "{d}", .{@as(u32, @intFromFloat(@round(@max(level, 0) * 100)))}) catch "";
        gtk.gtk_label_set_text(label, text.ptr);
    }
    const icon: [*:0]const u8 = if (level <= 0)
        "orca-volume-muted-symbolic"
    else if (level < 0.5)
        "orca-volume-low-symbolic"
    else
        "orca-volume-high-symbolic";
    if (self.volume_icon) |image| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, image), icon);
    if (self.volume_menu) |button| gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), icon);
}

// `GtkRange` owns the pointer gesture on its own slider, so a drag is observed
// through `change-value` rather than through a competing `GtkGestureClick` —
// a click gesture added here swallows the drag entirely. While a value is
// settling the tick stops writing the slider, otherwise position updates fight
// the gesture, and the seek is issued once the user stops moving. Suppressing
// the write is presentation; the position itself always comes from
// `playerStatus`.

const seek_settle_ms: c_uint = 220;

fn seekChangeValue(
    _: ?*anyopaque,
    _: c_int,
    value: f64,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    const clamped = if (value < 0) 0 else value;
    self.seeking = true;
    self.seek_pending_ms = @intFromFloat(clamped);
    if (self.seek_settle_timer != 0) _ = gtk.g_source_remove(self.seek_settle_timer);
    self.seek_settle_timer = gtk.g_timeout_add(seek_settle_ms, seekSettled, self);
    var buffer: [32]u8 = undefined;
    const text = strings.formatMs(&buffer, @intCast(self.seek_pending_ms));
    if (self.transport_controls.elapsed) |label| gtk.gtk_label_set_text(label, text.ptr);
    return gtk.false_;
}

fn seekSettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.seek_settle_timer = 0;
    self.seeking = false;
    defer self.requestTick();
    _ = self.runtime.playerSeekMs(self.player, @intCast(self.seek_pending_ms)) catch return gtk.SOURCE_REMOVE;
    self.mpris.notify();
    return gtk.SOURCE_REMOVE;
}

const cover_display_pixels: c_int = 54;
const bar_icon_pixels: c_int = 17;

/// Put the audible track's cover in the bar, or the placeholder. Called only
/// when the audible Track changes, never on every tick.
fn refreshCover(self: *App, track_id: ?i64) void {
    const cover = self.now_playing_art orelse return;
    const id = track_id orelse {
        art.forget(self, cover);
        gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, cover), "placeholder");
        return;
    };
    art.show(self, cover, art.Key.track(id, .thumb));
}

fn loveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    feedback.toggleLoveOfPlaying(state(data));
}

fn coverClicked(_: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    window.showPage(state(data), .now_playing);
}

fn nameButton(button: *gtk.Widget, name: [*:0]const u8) void {
    gtk.gtk_widget_set_tooltip_text(button, name);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, name, @as(c_int, -1));
}

fn iconButton(icon: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    nameButton(button, tooltip);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "circular");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

fn buildNowPlaying(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    self.now_playing_box = box;
    gtk.gtk_widget_set_size_request(box, 260, -1);

    const cover = art.newCover(self, art.iconPlaceholder(cover_display_pixels), cover_display_pixels);
    self.now_playing_art = cover;
    gtk.gtk_widget_set_tooltip_text(cover, "Now Playing");
    gtk.gtk_widget_set_cursor_from_name(cover, "pointer");
    const click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(click, "released", gtk.callback(coverClicked), self);
    gtk.gtk_widget_add_controller(cover, click);
    menu.onSecondaryClick(cover, menu.playingMenu, self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cover);

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const now_title = gtk.gtk_label_new("Nothing playing");
    const now_detail = gtk.gtk_label_new("");
    self.now_playing_title = gtk.cast(gtk.Label, now_title);
    self.now_playing_detail = gtk.cast(gtk.Label, now_detail);
    gtk.gtk_label_set_xalign(self.now_playing_title.?, 0.0);
    gtk.gtk_label_set_xalign(self.now_playing_detail.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.now_playing_title.?, gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_ellipsize(self.now_playing_detail.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(now_title, "now-title");
    gtk.gtk_widget_add_css_class(now_detail, "now-detail");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), now_title);
    const alert = gtk.gtk_image_new_from_icon_name("orca-alert-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, alert), 13);
    gtk.gtk_widget_set_visible(alert, gtk.false_);
    self.now_playing_alert = alert;
    const detail_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 5);
    gtk.gtk_widget_add_css_class(detail_row, "now-detail-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, detail_row), alert);
    gtk.gtk_box_append(gtk.cast(gtk.Box, detail_row), now_detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail_row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    const love = feedback.newButton(self, gtk.callback(loveClicked));
    gtk.gtk_widget_add_css_class(love, "bar-button");
    gtk.gtk_widget_set_valign(love, gtk.ALIGN_CENTER);
    if (gtk.gtk_button_get_child(gtk.cast(gtk.Button, love))) |image|
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), bar_icon_pixels);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), love);
    return box;
}

pub fn newButtons(self: *App) *gtk.Widget {
    const controls = &self.transport_controls;
    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(buttons, gtk.ALIGN_CENTER);
    const shuffle = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, shuffle), "orca-shuffle-symbolic");
    nameButton(shuffle, "Shuffle");
    gtk.gtk_widget_add_css_class(shuffle, "flat");
    gtk.gtk_widget_add_css_class(shuffle, "circular");
    gtk.gtk_widget_set_valign(shuffle, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(shuffle, "toggled", gtk.callback(shuffleToggled), self);
    const previous_button = iconButton("orca-previous-symbolic", "Previous");
    const play = gtk.gtk_button_new_from_icon_name("orca-play-symbolic");
    nameButton(play, "Play / Pause");
    gtk.gtk_widget_add_css_class(play, "circular");
    gtk.gtk_widget_add_css_class(play, "play-button");
    gtk.gtk_widget_set_valign(play, gtk.ALIGN_CENTER);
    const next_button = iconButton("orca-next-symbolic", "Next");
    const repeat = iconButton("orca-repeat-symbolic", "Repeat off / all / one");
    const radio_button = iconButton("orca-radio-symbolic", "Radio");
    controls.shuffle = shuffle;
    controls.previous = previous_button;
    controls.play = play;
    controls.next = next_button;
    controls.repeat = repeat;
    controls.radio = radio_button;
    _ = gtk.signalConnect(previous_button, "clicked", gtk.callback(previousClicked), self);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(next_button, "clicked", gtk.callback(nextClicked), self);
    _ = gtk.signalConnect(repeat, "clicked", gtk.callback(repeatClicked), self);
    _ = gtk.signalConnect(radio_button, "clicked", gtk.callback(radioClicked), self);
    showRadio(self, false);
    for ([_]*gtk.Widget{ shuffle, previous_button, play, next_button, repeat, radio_button }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), button);
    return buttons;
}

pub fn newSeek(self: *App) *gtk.Widget {
    const controls = &self.transport_controls;
    const seek = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const elapsed = gtk.gtk_label_new("0:00");
    const total = gtk.gtk_label_new("0:00");
    controls.elapsed = gtk.cast(gtk.Label, elapsed);
    controls.total = gtk.cast(gtk.Label, total);
    for ([_]*gtk.Widget{ elapsed, total }) |label| {
        gtk.gtk_widget_add_css_class(label, "numeric");
        gtk.gtk_widget_add_css_class(label, "seek-time");
        gtk.gtk_widget_set_size_request(label, 44, -1);
    }
    gtk.gtk_label_set_xalign(controls.elapsed.?, 1.0);
    gtk.gtk_label_set_xalign(controls.total.?, 0.0);
    const adjustment = self.seek_adjustment orelse adjustment: {
        const created = gtk.gtk_adjustment_new(0, 0, 1, 1000, 10000, 0);
        self.seek_adjustment = created;
        break :adjustment created;
    };
    const scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, adjustment);
    controls.scale = scale;
    gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, scale), gtk.false_);
    gtk.gtk_widget_add_css_class(scale, "seek");
    gtk.gtk_widget_set_size_request(scale, 120, -1);
    gtk.gtk_widget_set_hexpand(scale, gtk.true_);
    _ = gtk.signalConnect(scale, "change-value", gtk.callback(seekChangeValue), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, seek), elapsed);
    gtk.gtk_box_append(gtk.cast(gtk.Box, seek), scale);
    gtk.gtk_box_append(gtk.cast(gtk.Box, seek), total);
    return seek;
}

fn buildControls(self: *App) *gtk.Widget {
    const buttons = newButtons(self);
    gtk.gtk_box_set_spacing(gtk.cast(gtk.Box, buttons), 14);
    const controls = &self.transport_controls;
    for ([_]?*gtk.Widget{ controls.shuffle, controls.previous, controls.next, controls.repeat, controls.radio }) |button|
        gtk.gtk_widget_add_css_class(button.?, "bar-button");
    showRepeat(self, self.repeat_mode);
    const seek = newSeek(self);
    gtk.gtk_box_set_spacing(gtk.cast(gtk.Box, seek), 10);
    for ([_]?*gtk.Label{ controls.elapsed, controls.total }) |label|
        gtk.gtk_widget_set_size_request(gtk.cast(gtk.Widget, label.?), 26, -1);
    const stack = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_valign(stack, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(stack, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, stack), buttons);
    gtk.gtk_box_append(gtk.cast(gtk.Box, stack), seek);
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), stack);
    return column;
}

fn popoverHeading(text: [*:0]const u8) *gtk.Widget {
    const heading = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0.0);
    gtk.gtk_widget_add_css_class(heading, "heading");
    gtk.gtk_widget_set_margin_start(heading, 10);
    gtk.gtk_widget_set_margin_top(heading, 6);
    gtk.gtk_widget_set_margin_bottom(heading, 6);
    return heading;
}

fn buildFormat(self: *App) *gtk.Widget {
    const path_label = gtk.gtk_label_new(signal_path.nothing_playing);
    self.signal_path_label = gtk.cast(gtk.Label, path_label);
    gtk.gtk_label_set_xalign(self.signal_path_label.?, 0.0);
    gtk.gtk_label_set_wrap(self.signal_path_label.?, gtk.true_);
    gtk.gtk_label_set_max_width_chars(self.signal_path_label.?, 36);
    gtk.gtk_widget_set_tooltip_text(path_label, signal_path.pipewire_hedge);
    gtk.gtk_widget_add_css_class(path_label, "dim-label");
    gtk.gtk_widget_set_margin_start(path_label, 10);
    gtk.gtk_widget_set_margin_end(path_label, 10);
    gtk.gtk_widget_set_margin_bottom(path_label, 10);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(content, 280, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), popoverHeading("Signal Path"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), path_label);
    const popover = gtk.gtk_popover_new();
    self.signal_path_popover = gtk.cast(gtk.Popover, popover);
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), content);
    _ = gtk.signalConnect(popover, "show", gtk.callback(signalPathShown), self);

    const label = gtk.gtk_label_new("");
    self.format_label = gtk.cast(gtk.Label, label);
    gtk.gtk_label_set_xalign(self.format_label.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.format_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, "numeric");
    const button = gtk.gtk_button_new();
    self.format_button = button;
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), label);
    gtk.gtk_widget_set_parent(popover, button);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(formatClicked), self);
    _ = gtk.signalConnect(button, "destroy", gtk.callback(formatDestroyed), self);
    gtk.gtk_widget_set_tooltip_text(button, "Open Signal Path");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "bar-format");
    gtk.gtk_widget_set_halign(button, gtk.ALIGN_START);
    gtk.gtk_widget_set_visible(button, gtk.false_);
    return button;
}

fn formatClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    openSignalPath(state(data));
}

fn openSignalPath(self: *App) void {
    if (details.revealSignalPath(self)) return;
    if (self.signal_path_popover) |popover| gtk.gtk_popover_popup(popover);
}

fn formatDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const popover = self.signal_path_popover orelse return;
    self.signal_path_popover = null;
    gtk.gtk_widget_unparent(gtk.cast(gtk.Widget, popover));
}

fn summaryLine(key: [*:0]const u8, line: SummaryLine) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    const key_label = gtk.gtk_label_new(key);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, key_label), 0.0);
    gtk.gtk_widget_add_css_class(key_label, "device-summary-key");
    const value = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 1.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, value), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, value), 1);
    gtk.gtk_widget_set_hexpand(value, gtk.true_);
    gtk.gtk_widget_add_css_class(value, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), key_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), value);
    picker.lines[@backingInt(line)] = row;
    picker.values[@backingInt(line)] = gtk.cast(gtk.Label, value);
    return row;
}

fn buildSummary() *gtk.Widget {
    const summary = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(summary, "device-summary");
    picker.summary = summary;
    gtk.gtk_box_append(gtk.cast(gtk.Box, summary), summaryLine("Sending", .sending));
    gtk.gtk_box_append(gtk.cast(gtk.Box, summary), summaryLine("Mode", .mode));
    gtk.gtk_box_append(gtk.cast(gtk.Box, summary), summaryLine("Device supports", .supports));
    gtk.gtk_widget_set_visible(summary, gtk.false_);
    return summary;
}

fn showSummaryLine(line: SummaryLine, text: [:0]const u8) void {
    const index = @backingInt(line);
    if (picker.values[index]) |label| {
        gtk.gtk_label_set_text(label, text.ptr);
        gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, label), if (text.len == 0) null else text.ptr);
    }
    if (picker.lines[index]) |row| gtk.gtk_widget_set_visible(row, boolean(text.len != 0));
    const summary = picker.summary orelse return;
    var shown = false;
    for (picker.lines) |maybe_row| {
        const row = maybe_row orelse continue;
        if (gtk.gtk_widget_get_visible(row) != 0) shown = true;
    }
    gtk.gtk_widget_set_visible(summary, boolean(shown));
}

fn showSummaryText(line: SummaryLine, comptime write_fn: anytype, arguments: anytype) void {
    var buffer: [160]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    @call(.auto, write_fn, .{&writer} ++ arguments) catch {};
    buffer[writer.end] = 0;
    showSummaryLine(line, buffer[0..writer.end :0]);
}

fn showSignalSummary(path: ?liborca.SignalPath) void {
    const value = path orelse {
        showSummaryLine(.sending, "");
        showSummaryLine(.mode, "");
        return;
    };
    showSummaryText(.sending, signal_path.writeSending, .{value});
    showSummaryText(.mode, signal_path.writeMode, .{value});
}

fn showDeviceSupports(self: *const App) void {
    const capabilities = if (self.device_index < max_rows) picker.capabilities[self.device_index] else null;
    const known = capabilities orelse return showSummaryLine(.supports, "");
    showSummaryText(.supports, signal_path.writeDeviceSupports, .{known});
    if (picker.values[@backingInt(SummaryLine.supports)]) |label|
        gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, label), signal_path.device_supports_source);
}

fn pickerVolume(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "device-volume");
    const icon = gtk.gtk_image_new_from_icon_name("orca-volume-high-symbolic");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), icon);
    if (self.volume_adjustment) |adjustment| {
        const scale = volumeSlider(adjustment, gtk.ORIENTATION_HORIZONTAL);
        gtk.gtk_widget_set_hexpand(scale, gtk.true_);
        gtk.gtk_widget_set_valign(scale, gtk.ALIGN_CENTER);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), scale);
    }
    const value = gtk.gtk_label_new("100");
    picker.volume_value = gtk.cast(gtk.Label, value);
    gtk.gtk_label_set_xalign(picker.volume_value.?, 1.0);
    gtk.gtk_widget_add_css_class(value, "numeric");
    gtk.gtk_widget_add_css_class(value, "device-volume-value");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), value);
    return row;
}

fn pickerSignalPathClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.device_popover) |popover| gtk.gtk_popover_popdown(popover);
    openSignalPath(self);
}

fn pickerSoundSettingsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.device_popover) |popover| gtk.gtk_popover_popdown(popover);
    preferences.selectTab(self, .sound);
    window.showPage(self, .settings);
}

fn pickerFooter(self: *App) *gtk.Widget {
    const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(footer, "device-footer");

    const path_child = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, path_child), gtk.gtk_label_new("Signal Path"));
    const chevron = gtk.gtk_image_new_from_icon_name("orca-chevron-right-symbolic");
    gtk.gtk_widget_add_css_class(chevron, "device-footer-chevron");
    gtk.gtk_box_append(gtk.cast(gtk.Box, path_child), chevron);
    const path_button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, path_button), path_child);
    gtk.gtk_widget_add_css_class(path_button, "flat");
    gtk.gtk_widget_add_css_class(path_button, "device-signal-path");
    gtk.gtk_widget_set_hexpand(path_button, gtk.true_);
    gtk.gtk_widget_set_halign(path_button, gtk.ALIGN_START);
    _ = gtk.signalConnect(path_button, "clicked", gtk.callback(pickerSignalPathClicked), self);

    const settings_button = gtk.gtk_button_new_with_label("Sound settings");
    gtk.gtk_widget_add_css_class(settings_button, "flat");
    gtk.gtk_widget_add_css_class(settings_button, "device-sound-settings");
    _ = gtk.signalConnect(settings_button, "clicked", gtk.callback(pickerSoundSettingsClicked), self);

    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), path_button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), settings_button);
    return footer;
}

fn buildDevice(self: *App) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    self.device_list = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(self.device_list.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "device-list");
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(deviceActivated), self);
    const title = gtk.gtk_label_new("Play on");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const refresh = iconButton("orca-refresh-symbolic", "Refresh devices");
    gtk.gtk_widget_add_css_class(refresh, "device-refresh");
    _ = gtk.signalConnect(refresh, "clicked", gtk.callback(refreshClicked), self);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "device-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), refresh);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(content, 400, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), buildSummary());
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), pickerVolume(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), pickerFooter(self));
    const popover = gtk.gtk_popover_new();
    self.device_popover = gtk.cast(gtk.Popover, popover);
    gtk.gtk_popover_set_child(self.device_popover.?, content);
    gtk.gtk_popover_set_has_arrow(self.device_popover.?, gtk.false_);
    gtk.gtk_widget_add_css_class(popover, "device-picker");
    _ = gtk.signalConnect(popover, "show", gtk.callback(outputsShown), self);

    const label = gtk.gtk_label_new("Output");
    picker.bar_name = gtk.cast(gtk.Label, label);
    gtk.gtk_label_set_xalign(picker.bar_name.?, 0.0);
    gtk.gtk_label_set_ellipsize(picker.bar_name.?, gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(picker.bar_name.?, 18);
    const chevron = gtk.gtk_image_new_from_icon_name("orca-chevron-down-symbolic");
    gtk.gtk_widget_add_css_class(chevron, "bar-device-chevron");
    const child = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 3);
    gtk.gtk_box_append(gtk.cast(gtk.Box, child), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, child), chevron);
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), child);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    picker.button = button;
    gtk.gtk_widget_set_tooltip_text(button, "Output device");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "bar-device");
    gtk.gtk_widget_set_halign(button, gtk.ALIGN_START);
    return button;
}

fn volumeSlider(adjustment: *gtk.Adjustment, orientation: c_int) *gtk.Widget {
    const scale = gtk.gtk_scale_new(orientation, adjustment);
    gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, scale), gtk.false_);
    gtk.gtk_scale_set_digits(gtk.cast(gtk.Scale, scale), 2);
    gtk.gtk_widget_set_tooltip_text(scale, "Volume");
    gtk.gtk_widget_add_css_class(scale, "volume");
    return scale;
}

fn buildVolume(self: *App) *gtk.Widget {
    const adjustment = gtk.gtk_adjustment_new(1.0, 0.0, 1.0, 0.02, 0.1, 0.0);
    self.volume_adjustment = adjustment;
    _ = gtk.signalConnect(adjustment, "value-changed", gtk.callback(volumeChanged), self);

    const icon = gtk.gtk_image_new_from_icon_name("orca-volume-high-symbolic");
    self.volume_icon = icon;
    gtk.gtk_widget_add_css_class(icon, "bar-volume-icon");
    const inline_scale = volumeSlider(adjustment, gtk.ORIENTATION_HORIZONTAL);
    self.volume_scale = inline_scale;
    gtk.gtk_widget_set_size_request(inline_scale, 76, -1);
    gtk.gtk_widget_set_valign(inline_scale, gtk.ALIGN_CENTER);

    const popover_scale = volumeSlider(adjustment, gtk.ORIENTATION_VERTICAL);
    gtk.gtk_range_set_inverted(gtk.cast(gtk.Range, popover_scale), gtk.true_);
    gtk.gtk_widget_set_size_request(popover_scale, -1, 140);
    const popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), popover_scale);
    const menu_button = gtk.gtk_menu_button_new();
    self.volume_menu = menu_button;
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, menu_button), "orca-volume-high-symbolic");
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, menu_button), popover);
    nameButton(menu_button, "Volume");
    gtk.gtk_widget_add_css_class(menu_button, "flat");
    gtk.gtk_widget_set_visible(menu_button, gtk.false_);

    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    for ([_]*gtk.Widget{ icon, inline_scale, menu_button }) |widget|
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), widget);
    return box;
}

fn buildOutputs(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_halign(box, gtk.ALIGN_END);

    const signal = gtk.gtk_image_new_from_icon_name("orca-signal-symbolic");
    gtk.gtk_widget_add_css_class(signal, "bar-signal-icon");
    self.format_slot = signal;
    const lines = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(lines, gtk.ALIGN_CENTER);
    const volume = buildVolume(self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), buildFormat(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, lines), buildDevice(self));
    const output = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_valign(output, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(output, "bar-output");
    gtk.gtk_box_append(gtk.cast(gtk.Box, output), signal);
    gtk.gtk_box_append(gtk.cast(gtk.Box, output), lines);

    const queue = iconButton("orca-queue-symbolic", "Queue");
    gtk.gtk_widget_add_css_class(queue, "bar-button");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, queue), "app.show-queue");

    gtk.gtk_box_append(gtk.cast(gtk.Box, box), output);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), volume);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), queue);
    return box;
}

/// `playerSignalPath` stops the engine briefly to read it, so it is asked for
/// only when the audible Track, the DSP settings, the volume or the output
/// change, the popover or the inspector's signal path opens, or a stream starts
/// running; never on every tick. One read serves the bar, the popover and every
/// inspector.
pub fn refreshSignalPath(self: *App) void {
    var buffer: [1024]u8 = undefined;
    const ready = outputReady(self);
    const path = self.runtime.playerSignalPath(self.player) catch null;
    self.signal_path_has_output = ready;
    if (self.signal_path_label) |label| {
        const text = if (path) |value| signal_path.render(&buffer, value, deviceName(self)) else "Signal path unavailable";
        gtk.gtk_label_set_text(label, text.ptr);
    }
    if (self.format_label) |label| {
        const technology = if (path) |value| signal_path.renderTechnology(&buffer, value) else "";
        const text = if (technology.len == 0 and self.shown_failure_track != null) "No signal" else technology;
        gtk.gtk_label_set_text(label, text.ptr);
        if (self.format_button) |button| gtk.gtk_widget_set_visible(button, boolean(text.len != 0));
    }
    showSignalSummary(path);
    details.showSignalPath(self, path);
    preferences.showAudioInformation(self, path);
    if (path) |value| settleSignalPath(self, value);
}

const signal_path_settle_ms: c_uint = 250;
const signal_path_device_reads_max = 8;

fn settleSignalPath(self: *App, path: liborca.SignalPath) void {
    self.signal_path_draining = signal_path.processingDraining(path);
    if (self.signal_path_settle_timer != 0) return;
    if (signal_path.deviceUnreported(path) and self.signal_path_device_reads < signal_path_device_reads_max) {
        self.signal_path_device_reads += 1;
        armSignalPathSettle(self);
    } else if (self.signal_path_draining and self.shown_transport == .playing) armSignalPathSettle(self);
}

fn armSignalPathSettle(self: *App) void {
    if (self.signal_path_settle_timer != 0) return;
    self.signal_path_settle_timer = gtk.g_timeout_add(signal_path_settle_ms, signalPathSettled, self);
}

fn signalPathSettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.signal_path_settle_timer = 0;
    if (signalPathVisible(self)) refreshSignalPath(self);
    return gtk.SOURCE_REMOVE;
}

fn outputFailed(self: *App) bool {
    const zone = self.zone orelse return false;
    const stats = self.runtime.zoneStats(zone) catch return false;
    return stats.output_state == .failed;
}

fn outputReady(self: *App) bool {
    const zone = self.zone orelse return false;
    const stats = self.runtime.zoneStats(zone) catch return false;
    return stats.output_state == .active and stats.backend_quantum_frames != 0;
}

fn signalPathVisible(self: *App) bool {
    if (details.shownMode(self) == .signal_path) return true;
    for ([_]?*gtk.Popover{ self.signal_path_popover, self.device_popover }) |maybe_popover| {
        const popover = maybe_popover orelse continue;
        if (gtk.gtk_widget_get_visible(gtk.cast(gtk.Widget, popover)) != 0) return true;
    }
    const button = self.format_button orelse return false;
    const line = gtk.gtk_widget_get_parent(button) orelse return false;
    return gtk.gtk_widget_get_mapped(line) != 0;
}

/// The device rate exists only once a stream runs, after the track change
/// that opened it read the path. `playerSignalPath` pauses the engine, so this
/// reads it at most once per stream start, and only while it is on screen.
fn refreshSignalPathWhenOutputStarts(self: *App) void {
    if (!outputReady(self)) {
        self.signal_path_has_output = false;
        return;
    }
    if (self.signal_path_has_output or !signalPathVisible(self)) return;
    self.signal_path_device_reads = 0;
    refreshSignalPath(self);
}

fn signalPathShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.signal_path_device_reads = 0;
    refreshSignalPath(self);
}

/// Devices come and go while the app runs, so the list is re-read each time
/// it is opened rather than once at launch.
fn outputsShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    placeAboveBar(self);
    readCapabilities(self);
}

fn placeAboveBar(self: *App) void {
    const popover = self.device_popover orelse return;
    const button = picker.button orelse return;
    const bar = picker.bar orelse return;
    var bounds: gtk.Rect = .{};
    if (gtk.gtk_widget_compute_bounds(button, bar, &bounds) == 0) return;
    gtk.gtk_popover_set_offset(popover, 0, -(@as(c_int, @intFromFloat(bounds.y)) + picker_gap));
}

fn refreshClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    readCapabilities(state(data));
}

fn readCapabilities(self: *App) void {
    const chosen = selectedDeviceId(self);
    readDevices(self, .capabilities);
    for (self.device_ids.items, 0..) |id, index| {
        if (id == chosen) self.device_index = index;
    }
    showSelectedDevice(self);
    refreshSignalPath(self);
}

const bar_gap: c_int = 24;

fn barColumns(bar: *gtk.Widget) [3]*gtk.Widget {
    const start = gtk.gtk_widget_get_first_child(bar).?;
    const center = gtk.gtk_widget_get_next_sibling(start).?;
    return .{ start, center, gtk.gtk_widget_get_next_sibling(center).? };
}

fn measureBar(
    bar: *gtk.Widget,
    orientation: c_int,
    _: c_int,
    minimum: *c_int,
    natural: *c_int,
    minimum_baseline: *c_int,
    natural_baseline: *c_int,
) callconv(.c) void {
    const horizontal = orientation == gtk.ORIENTATION_HORIZONTAL;
    minimum.* = if (horizontal) 2 * bar_gap else 0;
    natural.* = minimum.*;
    minimum_baseline.* = -1;
    natural_baseline.* = -1;
    for (barColumns(bar)) |column| {
        var column_minimum: c_int = 0;
        var column_natural: c_int = 0;
        gtk.gtk_widget_measure(column, orientation, -1, &column_minimum, &column_natural, null, null);
        if (horizontal) {
            natural.* += column_natural;
        } else {
            minimum.* = @max(minimum.*, column_minimum);
            natural.* = @max(natural.*, column_natural);
        }
    }
}

fn allocateBar(bar: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const columns = barColumns(bar);
    var minimums: [3]c_int = undefined;
    for (columns, &minimums) |column, *column_minimum|
        gtk.gtk_widget_measure(column, gtk.ORIENTATION_HORIZONTAL, height, column_minimum, null, null, null);
    const space: c_int = @max(0, width - 2 * bar_gap);
    const side = @divTrunc(space * 2, 7);
    var start: c_int = @max(minimums[0], side);
    var end: c_int = @max(minimums[2], side);
    var excess: c_int = start + end + minimums[1] - space;
    if (excess > 0) {
        const cut = @min(@divTrunc(excess + 1, 2), start - minimums[0]);
        start -= cut;
        excess -= cut;
    }
    if (excess > 0) {
        const cut = @min(excess, end - minimums[2]);
        end -= cut;
        excess -= cut;
    }
    if (excess > 0) start -= @min(excess, start - minimums[0]);
    const widths = [3]c_int{ start, @max(minimums[1], space - start - end), end };
    var x: c_int = 0;
    for (columns, widths) |column, column_width| {
        gtk.gtk_widget_size_allocate(column, &.{ .x = x, .y = 0, .width = column_width, .height = height }, -1);
        x += column_width + bar_gap;
    }
}

/// GTK orders Tab focus by each child's vertical centre before its x, so the
/// three groups fill the bar's height and centre their own contents: centred
/// groups of different heights differ by half a pixel, which put the outputs
/// before the transport whenever the format line was hidden.
pub fn build(self: *App) *gtk.Widget {
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(bar, "player-bar");
    picker.bar = bar;
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), buildNowPlaying(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), buildControls(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), buildOutputs(self));
    gtk.gtk_widget_set_layout_manager(bar, gtk.gtk_custom_layout_new(null, measureBar, allocateBar));
    return bar;
}

pub fn tick(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;

    const duration_changed = status.duration_ms != self.last_seen_duration_ms;
    self.last_seen_duration_ms = status.duration_ms;
    const track_changed = !optionalEql(status.track_id, self.shown_track_id);
    const transport_changed = status.transport != self.shown_transport;
    showTransport(self, &self.transport_controls, status, duration_changed or track_changed);
    if (status.repeat != self.repeat_mode) {
        self.repeat_mode = status.repeat;
        showRepeat(self, status.repeat);
    }

    // Position is authoritative from the snapshot; the widget is only told
    // about it when the user is not dragging.
    if (!self.seeking) {
        if (self.seek_adjustment) |adjustment| {
            const duration: f64 = if (status.duration_ms > 0)
                @floatFromInt(status.duration_ms)
            else
                1.0;
            self.suppress_widget_writeback = true;
            if (duration_changed or gtk.gtk_adjustment_get_upper(adjustment) != duration)
                gtk.gtk_adjustment_set_upper(adjustment, duration);
            if (duration_changed or track_changed or transport_changed or
                seekPositionVisiblyMoved(self, adjustment, status))
                gtk.gtk_adjustment_set_value(adjustment, if (status.duration_ms > 0) @floatFromInt(status.position_ms) else 0.0);
            self.suppress_widget_writeback = false;
        }
    }

    if (self.volume_adjustment) |adjustment| {
        const level: f64 = status.volume;
        if (!self.suppress_widget_writeback and gtk.gtk_adjustment_get_value(adjustment) != level) {
            self.suppress_widget_writeback = true;
            gtk.gtk_adjustment_set_value(adjustment, level);
            self.suppress_widget_writeback = false;
        }
    }

    if (track_changed) {
        self.shown_track_id = status.track_id;
        self.shown_recording_id = null;
        self.shown_feedback = .none;
        var title: [:0]const u8 = "Nothing playing";
        var detail: [:0]const u8 = "";
        var title_buffer: [512]u8 = undefined;
        var detail_buffer: [1024]u8 = undefined;
        if (status.track_id != null) {
            if (mpris.nowPlaying(self.runtime, self.player)) |current| {
                defer current.deinit();
                const summary = current.summary;
                self.shown_recording_id = summary.recording_id;
                self.shown_feedback = summary.feedback;
                title = if (summary.title.len != 0)
                    strings.printZ(&title_buffer, "{s}", .{summary.title}) catch "Unknown title"
                else
                    "Unknown title";
                const artist = if (summary.artist.len != 0) summary.artist else summary.album_artist;
                detail = if (artist.len != 0 and summary.album.len != 0)
                    strings.printZ(&detail_buffer, "{s} · {s}", .{
                        artist,
                        summary.album,
                    }) catch ""
                else if (artist.len != 0)
                    strings.printZ(&detail_buffer, "{s}", .{artist}) catch ""
                else if (summary.album.len != 0)
                    strings.printZ(&detail_buffer, "{s}", .{summary.album}) catch ""
                else
                    "";
            }
        }
        if (self.now_playing_title) |label| gtk.gtk_label_set_text(label, title.ptr);
        if (self.now_playing_detail) |label| gtk.gtk_label_set_text(label, detail.ptr);
        if (status.track_id != null) notify.trackChanged(self, title.ptr, detail.ptr);
        refreshCover(self, status.track_id);
        window.markPlaying(self, status.track_id);
        albums.markPlaying(self, status.track_id);
        artist_page.markPlaying(self, status.track_id);
        genres.markPlaying(self, status.track_id);
        folders.markPlaying(self, status.track_id);
        palette.markPlaying(self, status.track_id);
        home.markPlaying(self, status.track_id);
        nowplaying.update(self, status.track_id);
        details.trackChanged(self);
        lyrics.trackChanged(self);
        feedback.showPlaying(self);
        refreshSignalPath(self);
    }
    const failed: ?liborca.PlaybackFailure = if (status.track_id == null) status.last_failure else null;
    const failed_track: ?i64 = if (failed) |failure| failure.track_id else null;
    if (track_changed or !optionalEql(failed_track, self.shown_failure_track)) {
        self.shown_failure_track = failed_track;
        showFailure(self, failed);
    }
    refreshSignalPathWhenOutputStarts(self);
    if (track_changed or transport_changed) {
        self.shown_transport = status.transport;
        if (transport_changed and status.transport == .playing and self.signal_path_draining)
            armSignalPathSettle(self);
        if (transport_changed and status.transport == .paused and outputFailed(self))
            self.toast("Paused because the output device stopped working");
        self.mpris.notify();
    }
}

fn failureDetail(reason: liborca.PlaybackFailure.Reason) [:0]const u8 {
    return switch (reason) {
        .codec_unavailable => "Stopped \u{00b7} no decoder for this file",
        .decode_error => "Stopped \u{00b7} file could not be read",
        else => "Stopped \u{00b7} file unavailable",
    };
}

/// The bar while nothing plays because the last entry could not be opened:
/// that Track, why it stopped, and no signal.
fn showFailure(self: *App, failure: ?liborca.PlaybackFailure) void {
    const bar = picker.bar;
    const controls = &self.transport_controls;
    if (self.now_playing_alert) |alert| gtk.gtk_widget_set_visible(alert, @intFromBool(failure != null));
    for ([_]?*gtk.Widget{ controls.shuffle, controls.repeat, controls.radio }) |button|
        if (button) |widget| gtk.gtk_widget_set_visible(widget, @intFromBool(failure == null));
    if (controls.play) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(failure == null));
    if (self.now_playing_art) |cover| {
        if (failure != null) gtk.gtk_widget_add_css_class(cover, "failed-cover") else gtk.gtk_widget_remove_css_class(cover, "failed-cover");
    }
    const failed = failure orelse {
        if (bar) |widget| gtk.gtk_widget_remove_css_class(widget, "failed");
        if (self.shown_track_id == null) {
            if (self.now_playing_title) |label| gtk.gtk_label_set_text(label, "Nothing playing");
            if (self.now_playing_detail) |label| gtk.gtk_label_set_text(label, "");
            refreshCover(self, null);
        }
        refreshSignalPath(self);
        return;
    };
    if (bar) |widget| gtk.gtk_widget_add_css_class(widget, "failed");
    var title_buffer: [512]u8 = undefined;
    var title: [:0]const u8 = "Unknown title";
    if (self.library) |library| {
        if (self.runtime.libraryTrackSummary(library, failed.track_id) catch null) |summary| {
            defer summary.deinit(self.allocator);
            if (summary.title.len != 0) title = strings.printZ(&title_buffer, "{s}", .{summary.title}) catch title;
        }
    }
    if (self.now_playing_title) |label| gtk.gtk_label_set_text(label, title.ptr);
    if (self.now_playing_detail) |label| gtk.gtk_label_set_text(label, failureDetail(failed.reason).ptr);
    refreshCover(self, failed.track_id);
    refreshSignalPath(self);
}

fn seekPositionVisiblyMoved(self: *App, adjustment: *gtk.Adjustment, status: liborca.PlayerStatus) bool {
    const shown_value = gtk.gtk_adjustment_get_value(adjustment);
    const shown_ms: u64 = if (shown_value > 0) @intFromFloat(shown_value) else 0;
    if (status.position_ms < shown_ms) return true;
    if (status.position_ms / std.time.ms_per_s != shown_ms / std.time.ms_per_s) return true;
    const width = widestSeekScaleWidth(self);
    if (width == 0) return false;
    return (status.position_ms - shown_ms) * width >= status.duration_ms;
}

fn widestSeekScaleWidth(self: *App) u64 {
    const scale = self.transport_controls.scale orelse return 0;
    if (gtk.gtk_widget_get_mapped(scale) == 0) return 0;
    const width = gtk.gtk_widget_get_width(scale);
    return if (width > 0) @intCast(width) else 0;
}

fn showTransport(
    self: *App,
    controls: *const app.TransportControls,
    status: liborca.PlayerStatus,
    total_changed: bool,
) void {
    if (controls.play) |play| {
        const button = gtk.cast(gtk.Button, play);
        const icon: [:0]const u8 = if (status.transport == .playing)
            "orca-pause-symbolic"
        else
            "orca-play-symbolic";
        const shown = std.mem.span(gtk.gtk_button_get_icon_name(button) orelse "");
        if (!std.mem.eql(u8, shown, icon))
            gtk.gtk_button_set_icon_name(button, icon.ptr);
    }
    if (controls.next) |button|
        gtk.gtk_widget_set_sensitive(button, boolean(status.queue_length > 0));
    if (controls.previous) |button|
        gtk.gtk_widget_set_sensitive(button, boolean(status.queue_length > 0));
    if (controls.shuffle) |button| {
        const shown = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
        if (shown != status.shuffle) {
            self.suppress_widget_writeback = true;
            gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), boolean(status.shuffle));
            self.suppress_widget_writeback = false;
        }
    }
    if (controls.scale) |scale| gtk.gtk_widget_set_sensitive(scale, boolean(status.duration_ms > 0));
    if (!self.seeking) if (controls.elapsed) |label| {
        var buffer: [32]u8 = undefined;
        gtk.gtk_label_set_text(label, strings.formatMs(&buffer, status.position_ms).ptr);
    };
    if (total_changed) if (controls.total) |label| {
        var buffer: [32]u8 = undefined;
        const text = if (status.duration_ms > 0)
            strings.formatMs(&buffer, status.duration_ms)
        else if (status.track_id != null)
            "–:––"
        else
            "0:00";
        gtk.gtk_label_set_text(label, text.ptr);
    };
}

fn optionalEql(a: ?i64, b: ?i64) bool {
    if (a) |left| {
        const right = b orelse return false;
        return left == right;
    }
    return b == null;
}
