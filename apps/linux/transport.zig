//! The player bar: now playing, transport, seek, volume, shuffle, repeat and
//! the output device chooser.
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
const settings = @import("settings.zig");

const App = app.App;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

/// The Zig API reports why a call was refused. These are the refusals the C ABI
/// used to flatten into `ORCA_STATUS_INVALID_STATE`.
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

// ------------------------------------------------------------------ devices

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

fn showSelectedDevice(self: *App) void {
    for (self.device_checks.items, 0..) |check, index|
        gtk.gtk_widget_set_opacity(check, if (index == self.device_index) 1.0 else 0.0);
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
}

// ----------------------------------------------------------------- playback

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
        // event correlated by this request id, drained on the app tick.
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
}

pub fn toggle(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;
    const result = if (status.transport == .playing)
        self.runtime.pausePlayer(self.player)
    else
        self.runtime.playPlayer(self.player);
    result catch |err| {
        if (isNotReady(err)) self.toast("Nothing to play yet — double-click a track");
    };
    self.mpris.notify();
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    toggle(state(data));
}

pub fn previous(self: *App) void {
    _ = self.runtime.playerPrevious(self.player) catch {};
    self.mpris.notify();
}

pub fn next(self: *App) void {
    const moved = self.runtime.playerNext(self.player) catch true;
    if (!moved) self.toast("End of the queue");
    self.mpris.notify();
}

fn previousClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    previous(state(data));
}

fn nextClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    next(state(data));
}

fn shuffleToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_widget_writeback) return;
    const active = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
    self.runtime.playerSetShuffle(self.player, active) catch {};
}

fn repeatClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.repeat_mode = switch (self.repeat_mode) {
        .off => .all,
        .all => .one,
        .one => .off,
    };
    self.runtime.playerSetRepeat(self.player, self.repeat_mode) catch return;
    showRepeat(gtk.cast(gtk.Widget, button), self.repeat_mode);
}

fn showRepeat(button: *gtk.Widget, mode: liborca.RepeatMode) void {
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), if (mode == .one)
        "media-playlist-repeat-song-symbolic"
    else
        "media-playlist-repeat-symbolic");
    if (mode == .off)
        gtk.gtk_widget_remove_css_class(button, "engaged")
    else
        gtk.gtk_widget_add_css_class(button, "engaged");
}

fn volumeChanged(_: ?*anyopaque, value: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_widget_writeback) return;
    self.runtime.playerSetVolume(self.player, @floatCast(value)) catch {};
}

// ------------------------------------------------------------------ seeking
//
// `GtkRange` owns the pointer gesture on its own slider, so a drag is observed
// through `change-value` rather than through a competing `GtkGestureClick` —
// a click gesture added here swallows the drag entirely. While a value is
// settling the 100 ms tick stops writing the slider, otherwise the timer fights
// the gesture, and the seek is issued once the user stops moving. Suppressing
// the write is presentation; the position itself always comes from
// `playerStatus`.

const seek_settle_us: i64 = 220_000;

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
    self.seek_changed_at_us = gtk.g_get_monotonic_time();
    if (self.elapsed_label) |label| {
        var buffer: [32]u8 = undefined;
        gtk.gtk_label_set_text(
            label,
            strings.formatMs(&buffer, @intCast(self.seek_pending_ms)).ptr,
        );
    }
    return gtk.false_;
}

fn applySettledSeek(self: *App) void {
    if (!self.seeking) return;
    if (gtk.g_get_monotonic_time() - self.seek_changed_at_us < seek_settle_us) return;
    self.seeking = false;
    _ = self.runtime.playerSeekMs(self.player, @intCast(self.seek_pending_ms)) catch return;
    self.mpris.notify();
}

// ---------------------------------------------------------------- cover art

const cover_display_pixels: c_int = 56;

/// Put the audible track's cover in the bar, or the placeholder. Called only
/// when the audible Track changes, never on the 100 ms tick.
fn refreshCover(self: *App, track_id: ?i64) void {
    const cover = self.now_playing_art orelse return;
    const id = track_id orelse {
        art.forget(self, cover);
        gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, cover), "placeholder");
        return;
    };
    art.show(self, cover, art.Key.track(id, .thumb));
}

fn coverClicked(_: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    window.showPage(state(data), .now_playing);
}

// -------------------------------------------------------------------- build

const volume_icons: [5]?[*:0]const u8 = .{
    "audio-volume-muted-symbolic",
    "audio-volume-high-symbolic",
    "audio-volume-low-symbolic",
    "audio-volume-medium-symbolic",
    null,
};

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
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), now_title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), now_detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    return box;
}

fn buildControls(self: *App) *gtk.Widget {
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_CENTER);

    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(buttons, gtk.ALIGN_CENTER);
    const shuffle = gtk.gtk_toggle_button_new();
    self.shuffle_button = shuffle;
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
    self.repeat_button = repeat;
    self.previous_button = previous_button;
    self.play_button = play;
    self.next_button = next_button;
    _ = gtk.signalConnect(previous_button, "clicked", gtk.callback(previousClicked), self);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(next_button, "clicked", gtk.callback(nextClicked), self);
    _ = gtk.signalConnect(repeat, "clicked", gtk.callback(repeatClicked), self);
    for ([_]*gtk.Widget{ shuffle, previous_button, play, next_button, repeat }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buttons);

    const seek = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const elapsed = gtk.gtk_label_new("0:00");
    const total = gtk.gtk_label_new("0:00");
    self.elapsed_label = gtk.cast(gtk.Label, elapsed);
    self.total_label = gtk.cast(gtk.Label, total);
    for ([_]*gtk.Widget{ elapsed, total }) |label| {
        gtk.gtk_widget_add_css_class(label, "numeric");
        gtk.gtk_widget_add_css_class(label, "seek-time");
        gtk.gtk_widget_set_size_request(label, 44, -1);
    }
    gtk.gtk_label_set_xalign(self.elapsed_label.?, 1.0);
    gtk.gtk_label_set_xalign(self.total_label.?, 0.0);
    self.seek_adjustment = gtk.gtk_adjustment_new(0, 0, 1, 1000, 10000, 0);
    const scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, self.seek_adjustment);
    self.seek_scale = gtk.cast(gtk.Scale, scale);
    gtk.gtk_scale_set_draw_value(self.seek_scale.?, gtk.false_);
    gtk.gtk_widget_add_css_class(scale, "seek");
    gtk.gtk_widget_set_size_request(scale, 420, -1);
    gtk.gtk_widget_set_hexpand(scale, gtk.true_);
    _ = gtk.signalConnect(scale, "change-value", gtk.callback(seekChangeValue), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, seek), elapsed);
    gtk.gtk_box_append(gtk.cast(gtk.Box, seek), scale);
    gtk.gtk_box_append(gtk.cast(gtk.Box, seek), total);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), seek);
    return column;
}

fn buildOutputs(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_set_halign(box, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);

    // GtkVolumeButton is deprecated in GTK 4.10; a plain GtkScaleButton with
    // the volume icons set is the supported replacement.
    const volume = gtk.gtk_scale_button_new(0.0, 1.0, 0.02, &volume_icons);
    self.volume_button = volume;
    gtk.gtk_widget_set_tooltip_text(volume, "Volume");
    gtk.gtk_widget_add_css_class(volume, "flat");
    gtk.gtk_scale_button_set_value(gtk.cast(gtk.ScaleButton, volume), 1.0);
    _ = gtk.signalConnect(volume, "value-changed", gtk.callback(volumeChanged), self);

    const list = gtk.gtk_list_box_new();
    self.device_list = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(self.device_list.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "device-list");
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(deviceActivated), self);
    const heading = gtk.gtk_label_new("Output");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0.0);
    gtk.gtk_widget_add_css_class(heading, "heading");
    gtk.gtk_widget_set_margin_start(heading, 10);
    gtk.gtk_widget_set_margin_top(heading, 6);
    gtk.gtk_widget_set_margin_bottom(heading, 6);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(content, 280, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), list);
    const popover = gtk.gtk_popover_new();
    self.device_popover = gtk.cast(gtk.Popover, popover);
    gtk.gtk_popover_set_child(self.device_popover.?, content);
    _ = gtk.signalConnect(popover, "show", gtk.callback(outputsShown), self);
    const outputs = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, outputs), "audio-card-symbolic");
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, outputs), popover);
    gtk.gtk_widget_set_tooltip_text(outputs, "Output device");
    gtk.gtk_widget_add_css_class(outputs, "flat");

    const queue = iconButton("view-list-symbolic", "Queue");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, queue), "app.show-queue");

    gtk.gtk_box_append(gtk.cast(gtk.Box, box), volume);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), outputs);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), queue);
    return box;
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

pub fn build(self: *App) *gtk.Widget {
    const bar = gtk.gtk_center_box_new();
    gtk.gtk_widget_add_css_class(bar, "player-bar");
    gtk.gtk_center_box_set_start_widget(gtk.cast(gtk.CenterBox, bar), buildNowPlaying(self));
    gtk.gtk_center_box_set_center_widget(gtk.cast(gtk.CenterBox, bar), buildControls(self));
    gtk.gtk_center_box_set_end_widget(gtk.cast(gtk.CenterBox, bar), buildOutputs(self));
    return bar;
}

// --------------------------------------------------------------------- tick

pub fn tick(self: *App) void {
    applySettledSeek(self);
    const status = self.runtime.playerStatus(self.player) catch return;

    if (self.play_button) |play| gtk.gtk_button_set_icon_name(
        gtk.cast(gtk.Button, play),
        if (status.transport == .playing)
            "media-playback-pause-symbolic"
        else
            "media-playback-start-symbolic",
    );
    if (self.next_button) |button|
        gtk.gtk_widget_set_sensitive(button, boolean(status.queue_length > 0));
    if (self.previous_button) |button|
        gtk.gtk_widget_set_sensitive(button, boolean(status.queue_length > 0));
    if (self.shuffle_button) |button| {
        const shown = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
        if (shown != status.shuffle) {
            self.suppress_widget_writeback = true;
            gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), boolean(status.shuffle));
            self.suppress_widget_writeback = false;
        }
    }
    if (status.repeat != self.repeat_mode) {
        self.repeat_mode = status.repeat;
        if (self.repeat_button) |button| showRepeat(button, status.repeat);
    }

    // Position is authoritative from the snapshot; the widget is only told
    // about it when the user is not dragging.
    const duration: f64 = if (status.duration_ms > 0)
        @floatFromInt(status.duration_ms)
    else
        1.0;
    if (!self.seeking) {
        if (self.seek_adjustment) |adjustment| {
            self.suppress_widget_writeback = true;
            gtk.gtk_adjustment_set_upper(adjustment, duration);
            gtk.gtk_adjustment_set_value(adjustment, @floatFromInt(status.position_ms));
            self.suppress_widget_writeback = false;
        }
        if (self.elapsed_label) |label| {
            var buffer: [32]u8 = undefined;
            gtk.gtk_label_set_text(label, strings.formatMs(&buffer, status.position_ms).ptr);
        }
    }
    if (self.seek_scale) |scale| gtk.gtk_widget_set_sensitive(
        gtk.cast(gtk.Widget, scale),
        boolean(status.duration_ms > 0),
    );
    if (status.duration_ms != self.last_seen_duration_ms) {
        self.last_seen_duration_ms = status.duration_ms;
        if (self.total_label) |label| {
            var buffer: [32]u8 = undefined;
            const text = if (status.duration_ms > 0)
                strings.formatMs(&buffer, status.duration_ms)
            else
                "0:00";
            gtk.gtk_label_set_text(label, text.ptr);
        }
    }

    if (self.volume_button) |volume| {
        const button = gtk.cast(gtk.ScaleButton, volume);
        const level: f64 = status.volume;
        if (!self.suppress_widget_writeback and gtk.gtk_scale_button_get_value(button) != level) {
            self.suppress_widget_writeback = true;
            gtk.gtk_scale_button_set_value(button, level);
            self.suppress_widget_writeback = false;
        }
    }

    const track_changed = !optionalEql(status.track_id, self.shown_track_id);
    if (track_changed) {
        self.shown_track_id = status.track_id;
        var title: [:0]const u8 = "Nothing playing";
        var detail: [:0]const u8 = "";
        var title_buffer: [512]u8 = undefined;
        var detail_buffer: [1024]u8 = undefined;
        if (status.track_id != null) {
            if (mpris.nowPlaying(self.runtime, self.player)) |current| {
                defer current.deinit();
                const summary = current.summary;
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
        nowplaying.update(self, status.track_id);
    }
    if (track_changed or status.transport != self.shown_transport) {
        self.shown_transport = status.transport;
        self.mpris.notify();
    }
}

fn optionalEql(a: ?i64, b: ?i64) bool {
    if (a) |left| {
        const right = b orelse return false;
        return left == right;
    }
    return b == null;
}
