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
const window = @import("window.zig");
const art = @import("art.zig");
const nowplaying = @import("nowplaying.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const genres = @import("genres.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const signal_path = @import("signal_path.zig");
const details = @import("details.zig");
const lyrics = @import("lyrics.zig");
const feedback = @import("feedback.zig");
const preferences = @import("preferences.zig");

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

fn deviceRow(self: *App, name: [:0]const u8) void {
    if (self.allocator.dupeSentinel(u8, name, 0)) |owned| {
        self.device_names.append(self.allocator, owned) catch self.allocator.free(owned);
    } else |_| {}
    const list = self.device_list orelse return;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "device-row");
    const label = gtk.gtk_label_new(name.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_hexpand(label, gtk.true_);
    const check = gtk.gtk_image_new_from_icon_name("object-select-symbolic");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), check);
    gtk.gtk_list_box_append(list, row);
    self.device_checks.append(self.allocator, check) catch {};
}

pub fn deviceName(self: *const App) [:0]const u8 {
    if (self.device_index < self.device_names.items.len) return self.device_names.items[self.device_index];
    return "Output";
}

fn showSelectedDevice(self: *App) void {
    for (self.device_checks.items, 0..) |check, index|
        gtk.gtk_widget_set_opacity(check, if (index == self.device_index) 1.0 else 0.0);
    preferences.showOutputDevice(self);
    const label = self.device_label orelse return;
    const name = deviceName(self);
    gtk.gtk_label_set_text(label, name.ptr);
    gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, label), name.ptr);
    if (self.device_icon) |icon| gtk.gtk_widget_set_tooltip_text(icon, name.ptr);
}

pub fn refreshDevices(self: *App) void {
    const list = self.device_list orelse return;

    var devices: [max_devices]liborca.Device = undefined;
    const count = self.runtime.enumerateOutputDevices(&devices) catch 0;

    gtk.gtk_list_box_remove_all(list);
    self.device_ids.clearRetainingCapacity();
    self.device_checks.clearRetainingCapacity();
    for (self.device_names.items) |name| self.allocator.free(name);
    self.device_names.clearRetainingCapacity();
    // Id 0 is "let the server decide", which is what a single-output frontend
    // should default to.
    deviceRow(self, "System Default");
    self.device_ids.append(self.allocator, 0) catch {};

    var buffer: [288]u8 = undefined;
    for (devices[0..count]) |*device| {
        const label = if (device.name_len != 0)
            strings.printZ(&buffer, "{s}", .{device.nameSlice()}) catch continue
        else
            strings.printZ(&buffer, "Device {d}", .{device.id}) catch continue;
        deviceRow(self, label);
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
    if (self.zone != null) return true;
    const zone = self.runtime.playerOpenDefaultOutput(
        self.player,
        selectedDeviceId(self),
    ) catch return false;
    self.zone = zone;
    return true;
}

fn deviceActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0) return;
    if (self.device_popover) |popover| gtk.gtk_popover_popdown(popover);
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
    const result = if (status.transport == .playing)
        self.runtime.pausePlayer(self.player)
    else
        self.runtime.playPlayer(self.player);
    result catch |err| {
        if (isNotReady(err)) self.toast("Nothing to play yet — double-click a song");
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
    for (&self.transport_controls.values) |*controls| {
        const button = controls.shuffle orelse continue;
        const shuffle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_active(shuffle, if (gtk.gtk_toggle_button_get_active(shuffle) != 0) gtk.false_ else gtk.true_);
        return;
    }
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

fn showRepeat(self: *App, mode: liborca.RepeatMode) void {
    for (&self.transport_controls.values) |*controls| {
        const button = controls.repeat orelse continue;
        gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), if (mode == .one)
            "media-playlist-repeat-song-symbolic"
        else
            "media-playlist-repeat-symbolic");
        if (mode == .off)
            gtk.gtk_widget_remove_css_class(button, "engaged")
        else
            gtk.gtk_widget_add_css_class(button, "engaged");
    }
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
    const icon: [*:0]const u8 = if (level <= 0)
        "audio-volume-muted-symbolic"
    else if (level < 1.0 / 3.0)
        "audio-volume-low-symbolic"
    else if (level < 2.0 / 3.0)
        "audio-volume-medium-symbolic"
    else
        "audio-volume-high-symbolic";
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
    for (&self.transport_controls.values) |*controls| {
        if (controls.elapsed) |label| gtk.gtk_label_set_text(label, text.ptr);
    }
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

const cover_display_pixels: c_int = 56;

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

fn iconButton(icon: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
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

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
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
    const title_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_set_hexpand(now_title, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), now_title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), feedback.newButton(self, gtk.callback(loveClicked)));
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title_row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), now_detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    return box;
}

pub fn newButtons(self: *App, surface: app.TransportSurface) *gtk.Widget {
    const controls = self.transport_controls.getPtr(surface);
    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(buttons, gtk.ALIGN_CENTER);
    const shuffle = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, shuffle), "media-playlist-shuffle-symbolic");
    gtk.gtk_widget_set_tooltip_text(shuffle, "Shuffle");
    gtk.gtk_widget_add_css_class(shuffle, "flat");
    gtk.gtk_widget_add_css_class(shuffle, "circular");
    gtk.gtk_widget_set_valign(shuffle, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(shuffle, "toggled", gtk.callback(shuffleToggled), self);
    const previous_button = iconButton("media-skip-backward-symbolic", "Previous");
    const play = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    gtk.gtk_widget_set_tooltip_text(play, "Play / Pause");
    gtk.gtk_widget_add_css_class(play, "circular");
    gtk.gtk_widget_add_css_class(play, "play-button");
    gtk.gtk_widget_set_valign(play, gtk.ALIGN_CENTER);
    const next_button = iconButton("media-skip-forward-symbolic", "Next");
    const repeat = iconButton("media-playlist-repeat-symbolic", "Repeat off / all / one");
    controls.shuffle = shuffle;
    controls.previous = previous_button;
    controls.play = play;
    controls.next = next_button;
    controls.repeat = repeat;
    _ = gtk.signalConnect(previous_button, "clicked", gtk.callback(previousClicked), self);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(next_button, "clicked", gtk.callback(nextClicked), self);
    _ = gtk.signalConnect(repeat, "clicked", gtk.callback(repeatClicked), self);
    for ([_]*gtk.Widget{ shuffle, previous_button, play, next_button, repeat }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), button);
    return buttons;
}

pub fn newSeek(self: *App, surface: app.TransportSurface) *gtk.Widget {
    const controls = self.transport_controls.getPtr(surface);
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
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    const buttons = newButtons(self, .bar);
    gtk.gtk_widget_set_vexpand(buttons, gtk.true_);
    gtk.gtk_widget_set_valign(buttons, gtk.ALIGN_END);
    const seek = newSeek(self, .bar);
    gtk.gtk_widget_set_vexpand(seek, gtk.true_);
    gtk.gtk_widget_set_valign(seek, gtk.ALIGN_START);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buttons);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), seek);
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
    const icon = gtk.gtk_image_new_from_icon_name("network-cellular-signal-excellent-symbolic");
    gtk.gtk_widget_add_css_class(icon, "bar-format-icon");
    const child = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, child), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, child), label);
    const button = gtk.gtk_button_new();
    self.format_button = button;
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), child);
    gtk.gtk_widget_set_parent(popover, button);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(formatClicked), self);
    _ = gtk.signalConnect(button, "destroy", gtk.callback(formatDestroyed), self);
    gtk.gtk_widget_set_tooltip_text(button, "Signal Path");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "bar-format");
    gtk.gtk_widget_set_visible(button, gtk.false_);

    const slot = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    self.format_slot = slot;
    gtk.gtk_box_append(gtk.cast(gtk.Box, slot), button);
    return slot;
}

fn formatClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (details.revealSignalPath(self)) return;
    if (self.signal_path_popover) |popover| gtk.gtk_popover_popup(popover);
}

fn formatDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const popover = self.signal_path_popover orelse return;
    self.signal_path_popover = null;
    gtk.gtk_widget_unparent(gtk.cast(gtk.Widget, popover));
}

fn buildDevice(self: *App) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    self.device_list = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(self.device_list.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "device-list");
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(deviceActivated), self);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(content, 280, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), popoverHeading("Output"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), list);
    const popover = gtk.gtk_popover_new();
    self.device_popover = gtk.cast(gtk.Popover, popover);
    gtk.gtk_popover_set_child(self.device_popover.?, content);
    _ = gtk.signalConnect(popover, "show", gtk.callback(outputsShown), self);

    const icon = gtk.gtk_image_new_from_icon_name("audio-card-symbolic");
    self.device_icon = icon;
    gtk.gtk_widget_set_visible(icon, gtk.false_);
    const label = gtk.gtk_label_new("Output");
    self.device_label = gtk.cast(gtk.Label, label);
    gtk.gtk_label_set_xalign(self.device_label.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.device_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(self.device_label.?, 18);
    const child = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, child), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, child), label);
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), child);
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, button), gtk.true_);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "bar-device");
    return button;
}

fn buildDeviceLine(self: *App) *gtk.Widget {
    const label = gtk.gtk_label_new("");
    self.adjustments_label = gtk.cast(gtk.Label, label);
    gtk.gtk_widget_add_css_class(label, "bar-adjustments");
    gtk.gtk_widget_add_css_class(label, "numeric");
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), buildDevice(self));
    return line;
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

    const icon = gtk.gtk_image_new_from_icon_name("audio-volume-high-symbolic");
    self.volume_icon = icon;
    gtk.gtk_widget_add_css_class(icon, "bar-volume-icon");
    const inline_scale = volumeSlider(adjustment, gtk.ORIENTATION_HORIZONTAL);
    self.volume_scale = inline_scale;
    gtk.gtk_widget_set_size_request(inline_scale, 100, -1);
    gtk.gtk_widget_set_valign(inline_scale, gtk.ALIGN_CENTER);

    const popover_scale = volumeSlider(adjustment, gtk.ORIENTATION_VERTICAL);
    gtk.gtk_range_set_inverted(gtk.cast(gtk.Range, popover_scale), gtk.true_);
    gtk.gtk_widget_set_size_request(popover_scale, -1, 140);
    const popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), popover_scale);
    const menu_button = gtk.gtk_menu_button_new();
    self.volume_menu = menu_button;
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, menu_button), "audio-volume-high-symbolic");
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, menu_button), popover);
    gtk.gtk_widget_set_tooltip_text(menu_button, "Volume");
    gtk.gtk_widget_add_css_class(menu_button, "flat");
    gtk.gtk_widget_set_visible(menu_button, gtk.false_);

    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    for ([_]*gtk.Widget{ icon, inline_scale, menu_button }) |widget|
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), widget);
    return box;
}

fn buildOutputs(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_halign(box, gtk.ALIGN_END);

    const output = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_valign(output, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(output, "bar-output");
    gtk.gtk_box_append(gtk.cast(gtk.Box, output), buildFormat(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, output), buildDeviceLine(self));

    const queue = iconButton("view-list-symbolic", "Queue");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, queue), "app.show-queue");

    gtk.gtk_box_append(gtk.cast(gtk.Box, box), output);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), buildVolume(self));
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
        const text = if (path) |value| signal_path.renderCompact(&buffer, value) else "";
        gtk.gtk_label_set_text(label, text.ptr);
        if (self.format_button) |button| gtk.gtk_widget_set_visible(button, boolean(text.len != 0));
    }
    if (self.adjustments_label) |label| {
        const text = if (path) |value| signal_path.renderAdjustments(&buffer, value) else "";
        gtk.gtk_label_set_text(label, text.ptr);
    }
    details.showSignalPath(self, path);
    preferences.showAudioInformation(self, path);
}

fn outputReady(self: *App) bool {
    const zone = self.zone orelse return false;
    const stats = self.runtime.zoneStats(zone) catch return false;
    return stats.output_state == .active and stats.backend_quantum_frames != 0;
}

fn signalPathVisible(self: *App) bool {
    if (details.shownMode(self) == .signal_path) return true;
    if (preferences.audioInformationShown(self)) return true;
    if (self.signal_path_popover) |popover| {
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
    refreshSignalPath(self);
}

fn signalPathShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    refreshSignalPath(state(data));
}

/// Devices come and go while the app runs, so the list is re-read each time
/// it is opened rather than once at launch.
fn outputsShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const chosen = selectedDeviceId(self);
    refreshDevices(self);
    for (self.device_ids.items, 0..) |id, index| {
        if (id == chosen) self.device_index = index;
    }
    showSelectedDevice(self);
}

/// GTK orders Tab focus by each child's vertical centre before its x, so the
/// three groups fill the bar's height and centre their own contents: centred
/// groups of different heights differ by half a pixel, which put the outputs
/// before the transport whenever the format line was hidden.
pub fn build(self: *App) *gtk.Widget {
    const bar = gtk.gtk_center_box_new();
    gtk.gtk_widget_add_css_class(bar, "player-bar");
    gtk.gtk_center_box_set_start_widget(gtk.cast(gtk.CenterBox, bar), buildNowPlaying(self));
    gtk.gtk_center_box_set_center_widget(gtk.cast(gtk.CenterBox, bar), buildControls(self));
    gtk.gtk_center_box_set_end_widget(gtk.cast(gtk.CenterBox, bar), buildOutputs(self));
    return bar;
}

pub fn tick(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;

    const duration_changed = status.duration_ms != self.last_seen_duration_ms;
    self.last_seen_duration_ms = status.duration_ms;
    for (&self.transport_controls.values) |*controls| showTransport(self, controls, status, duration_changed);
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
            gtk.gtk_adjustment_set_upper(adjustment, duration);
            gtk.gtk_adjustment_set_value(adjustment, @floatFromInt(status.position_ms));
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

    const track_changed = !optionalEql(status.track_id, self.shown_track_id);
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
        refreshCover(self, status.track_id);
        window.markPlaying(self, status.track_id);
        albums.markPlaying(self, status.track_id);
        artists.markPlaying(self, status.track_id);
        genres.markPlaying(self, status.track_id);
        nowplaying.update(self, status.track_id);
        details.trackChanged(self);
        lyrics.trackChanged(self);
        feedback.showPlaying(self);
        refreshSignalPath(self);
    }
    refreshSignalPathWhenOutputStarts(self);
    if (track_changed or status.transport != self.shown_transport) {
        self.shown_transport = status.transport;
        self.mpris.notify();
    }
}

fn showTransport(
    self: *App,
    controls: *const app.TransportControls,
    status: liborca.PlayerStatus,
    duration_changed: bool,
) void {
    if (controls.play) |play| gtk.gtk_button_set_icon_name(
        gtk.cast(gtk.Button, play),
        if (status.transport == .playing)
            "media-playback-pause-symbolic"
        else
            "media-playback-start-symbolic",
    );
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
    if (duration_changed) if (controls.total) |label| {
        var buffer: [32]u8 = undefined;
        const text = if (status.duration_ms > 0)
            strings.formatMs(&buffer, status.duration_ms)
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
