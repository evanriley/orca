//! Transport bar: prev / play-pause / next, seek, volume, shuffle, repeat and
//! the output device chooser.
//!
//! Position and duration are read from `playerStatus` and rendered. They are
//! never adjusted, cached across tracks, or reconstructed from telemetry: that
//! is engine state and it belongs to liborca.

const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const mpris = @import("mpris.zig");

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
    const drop_down = self.device_drop_down orelse return 0;
    if (self.device_ids.items.len == 0) return 0;
    const selected = gtk.gtk_drop_down_get_selected(drop_down);
    if (selected == gtk.INVALID_LIST_POSITION or selected >= self.device_ids.items.len) return 0;
    return self.device_ids.items[selected];
}

pub fn refreshDevices(self: *App) void {
    const names = self.device_names orelse return;
    const drop_down = self.device_drop_down orelse return;

    var devices: [max_devices]liborca.audio.backend.Device = undefined;
    const count = self.runtime.enumerateOutputDevices(&devices) catch 0;

    self.suppress_widget_writeback = true;
    gtk.gtk_string_list_splice(
        names,
        0,
        gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, names)),
        null,
    );
    self.device_ids.clearRetainingCapacity();
    // Id 0 is "let the server decide", which is what a single-output frontend
    // should default to.
    gtk.gtk_string_list_append(names, "System Default");
    self.device_ids.append(self.allocator, 0) catch {};

    var buffer: [288]u8 = undefined;
    for (devices[0..count]) |*device| {
        const label = if (device.name_len != 0)
            strings.printZ(&buffer, "{s}", .{device.nameSlice()}) catch continue
        else
            strings.printZ(&buffer, "Device {d}", .{device.id}) catch continue;
        gtk.gtk_string_list_append(names, label.ptr);
        self.device_ids.append(self.allocator, device.id) catch {};
    }
    gtk.gtk_drop_down_set_selected(drop_down, 0);
    self.suppress_widget_writeback = false;
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

fn deviceSelected(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_widget_writeback) return;
    if (self.zone) |zone| {
        self.runtime.destroyZone(zone) catch {};
        self.zone = null;
    }
    self.setStatus(if (ensureOutput(self))
        "Output device changed"
    else
        "Could not open that output device");
}

// ----------------------------------------------------------------- playback

pub fn playIds(self: *App, ids: []const i64, start: u32) void {
    if (ids.len == 0) return;
    if (!ensureOutput(self)) {
        self.setStatus("No audio output is available");
        return;
    }
    const library = (self.runtime.playerLibrary(self.player) catch null) orelse {
        self.setStatus("The player is not ready");
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
            self.setStatus("Could not start playback");
            return;
        };
        self.pending_play_request = request;
        return;
    }
    self.runtime.playerPlayTracksBound(self.player, library, ids, start) catch {
        self.setStatus("Could not start playback");
        return;
    };
    var buffer: [64]u8 = undefined;
    self.setStatus(strings.printZ(&buffer, "Playing {d} tracks", .{ids.len}) catch "Playing");
}

pub fn toggle(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;
    const result = if (status.transport == .playing)
        self.runtime.pausePlayer(self.player)
    else
        self.runtime.playPlayer(self.player);
    result catch |err| {
        if (isNotReady(err)) self.setStatus(
            "Nothing to play - double-click a track, or select several and press Enter",
        );
    };
    self.mpris.notify();
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    toggle(state(data));
}

fn previousClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    _ = self.runtime.playerPrevious(self.player) catch {};
    self.mpris.notify();
}

fn nextClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const moved = self.runtime.playerNext(self.player) catch true;
    if (!moved) self.setStatus("End of the queue");
    self.mpris.notify();
}

fn shuffleToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
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
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), if (self.repeat_mode == .one)
        "media-playlist-repeat-song-symbolic"
    else
        "media-playlist-repeat-symbolic");
    gtk.gtk_widget_set_opacity(
        gtk.cast(gtk.Widget, button),
        if (self.repeat_mode == .off) 0.45 else 1.0,
    );
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

/// What the transport bar draws when the audible track has no usable cover.
///
/// A file that carries none, a file that has gone missing, an image liborca
/// refused as unrecognizable or oversized, and one gdk-pixbuf could not decode
/// all land here. A placeholder is the honest answer to all four, and none of
/// them is worth interrupting somebody's listening with a dialog.
const cover_placeholder_icon: [*:0]const u8 = "audio-x-generic-symbolic";

/// How large the cover is drawn.
const cover_display_pixels: c_int = 48;

/// How large the cover is *decoded*, which is the bound that matters.
///
/// liborca refuses to read more than `metadata.max_image_bytes` of encoded
/// image, but encoded size says almost nothing about pixel count: the largest
/// cover in the reference library is an 11.3 MiB JPEG, and a JPEG that size is
/// routinely 3000 pixels square — 36 MB of pixels for a widget 48 pixels wide.
/// gdk-pixbuf scales inside the loader, so asking for a bounded size never
/// materializes the full image. Twice the display size covers HiDPI scaling.
const cover_decode_pixels: c_int = 128;

/// Put the audible track's cover in the transport bar, or the placeholder.
/// Called only when the audible Track changes, never on the 100 ms tick.
fn refreshCover(self: *App, track_id: ?i64) void {
    const image = self.now_playing_cover orelse return;
    const texture = coverTexture(self, track_id) orelse {
        gtk.gtk_image_set_from_icon_name(image, cover_placeholder_icon);
        gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, image), "dim-label");
        return;
    };
    defer gtk.g_object_unref(texture);
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, image), "dim-label");
    gtk.gtk_image_set_from_paintable(image, gtk.cast(gtk.GdkPaintable, texture));
}

fn coverTexture(self: *App, track_id: ?i64) ?*gtk.GdkTexture {
    const id = track_id orelse return null;
    const library = (self.runtime.playerLibrary(self.player) catch null) orelse return null;
    const cover = (self.runtime.libraryTrackArtwork(library, self.io, id) catch
        return null) orelse return null;
    defer cover.deinit();
    return decodeCover(cover.bytes);
}

/// Encoded bytes to a bounded-size texture, or null if the platform decoder
/// will not have them.
fn decodeCover(bytes: []const u8) ?*gtk.GdkTexture {
    // Borrowed, not copied: the decode below is synchronous and both the
    // stream and the GBytes are dropped before this returns, so liborca's
    // buffer outlives every reader of it. Copying cost 12 MB of resident
    // memory on this library's largest cover for no benefit at all.
    const borrowed = gtk.g_bytes_new_static(bytes.ptr, bytes.len);
    defer gtk.g_bytes_unref(borrowed);
    const stream = gtk.g_memory_input_stream_new_from_bytes(borrowed);
    defer gtk.g_object_unref(stream);
    var err: ?*gtk.GError = null;
    const pixbuf = gtk.gdk_pixbuf_new_from_stream_at_scale(
        stream,
        cover_decode_pixels,
        cover_decode_pixels,
        gtk.true_,
        null,
        &err,
    ) orelse {
        gtk.g_clear_error(&err);
        return null;
    };
    defer gtk.g_object_unref(pixbuf);
    return gtk.gdk_texture_new_for_pixbuf(pixbuf);
}

// -------------------------------------------------------------------- build

const volume_icons: [5]?[*:0]const u8 = .{
    "audio-volume-muted-symbolic",
    "audio-volume-high-symbolic",
    "audio-volume-low-symbolic",
    "audio-volume-medium-symbolic",
    null,
};

pub fn build(self: *App) *gtk.Widget {
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_margin_top(bar, 8);
    gtk.gtk_widget_set_margin_bottom(bar, 10);
    gtk.gtk_widget_set_margin_start(bar, 12);
    gtk.gtk_widget_set_margin_end(bar, 12);

    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(buttons, "linked");
    const previous = gtk.gtk_button_new_from_icon_name("media-skip-backward-symbolic");
    const play = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    const next = gtk.gtk_button_new_from_icon_name("media-skip-forward-symbolic");
    self.previous_button = previous;
    self.play_button = play;
    self.next_button = next;
    gtk.gtk_widget_set_tooltip_text(previous, "Previous");
    gtk.gtk_widget_set_tooltip_text(play, "Play / Pause");
    gtk.gtk_widget_set_tooltip_text(next, "Next");
    gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), previous);
    gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), play);
    gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), next);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), buttons);
    _ = gtk.signalConnect(previous, "clicked", gtk.callback(previousClicked), self);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(next, "clicked", gtk.callback(nextClicked), self);

    const cover = gtk.gtk_image_new_from_icon_name(cover_placeholder_icon);
    self.now_playing_cover = gtk.cast(gtk.Image, cover);
    gtk.gtk_image_set_pixel_size(self.now_playing_cover.?, cover_display_pixels);
    gtk.gtk_widget_set_valign(cover, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(cover, "dim-label");
    gtk.gtk_widget_set_tooltip_text(cover, "Cover art");
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), cover);

    const now = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(now, 220, -1);
    gtk.gtk_widget_set_valign(now, gtk.ALIGN_CENTER);
    const now_title = gtk.gtk_label_new("Nothing playing");
    const now_detail = gtk.gtk_label_new("");
    self.now_playing_title = gtk.cast(gtk.Label, now_title);
    self.now_playing_detail = gtk.cast(gtk.Label, now_detail);
    gtk.gtk_label_set_xalign(self.now_playing_title.?, 0.0);
    gtk.gtk_label_set_xalign(self.now_playing_detail.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.now_playing_title.?, gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_ellipsize(self.now_playing_detail.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(now_title, "heading");
    gtk.gtk_widget_add_css_class(now_detail, "dim-label");
    gtk.gtk_box_append(gtk.cast(gtk.Box, now), now_title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, now), now_detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), now);

    const elapsed = gtk.gtk_label_new("0:00");
    const total = gtk.gtk_label_new("");
    self.elapsed_label = gtk.cast(gtk.Label, elapsed);
    self.total_label = gtk.cast(gtk.Label, total);
    gtk.gtk_widget_add_css_class(elapsed, "numeric");
    gtk.gtk_widget_add_css_class(total, "numeric");
    self.seek_adjustment = gtk.gtk_adjustment_new(0, 0, 1, 1000, 10000, 0);
    const scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, self.seek_adjustment);
    self.seek_scale = gtk.cast(gtk.Scale, scale);
    gtk.gtk_scale_set_draw_value(self.seek_scale.?, gtk.false_);
    gtk.gtk_widget_set_hexpand(scale, gtk.true_);
    gtk.gtk_widget_set_valign(scale, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), elapsed);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), scale);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), total);
    _ = gtk.signalConnect(scale, "change-value", gtk.callback(seekChangeValue), self);

    const shuffle = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, shuffle), "media-playlist-shuffle-symbolic");
    gtk.gtk_widget_set_tooltip_text(shuffle, "Shuffle");
    _ = gtk.signalConnect(shuffle, "toggled", gtk.callback(shuffleToggled), self);
    const repeat = gtk.gtk_button_new_from_icon_name("media-playlist-repeat-symbolic");
    gtk.gtk_widget_set_tooltip_text(repeat, "Repeat off / all / one");
    gtk.gtk_widget_set_opacity(repeat, 0.45);
    _ = gtk.signalConnect(repeat, "clicked", gtk.callback(repeatClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), shuffle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), repeat);

    // GtkVolumeButton is deprecated in GTK 4.10; a plain GtkScaleButton with
    // the volume icons set is the supported replacement.
    const volume = gtk.gtk_scale_button_new(0.0, 1.0, 0.02, &volume_icons);
    self.volume_button = volume;
    gtk.gtk_widget_set_tooltip_text(volume, "Volume");
    gtk.gtk_scale_button_set_value(gtk.cast(gtk.ScaleButton, volume), 1.0);
    _ = gtk.signalConnect(volume, "value-changed", gtk.callback(volumeChanged), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), volume);

    if (self.device_drop_down) |drop_down| _ = gtk.signalConnect(
        drop_down,
        "notify::selected",
        gtk.callback(deviceSelected),
        self,
    );
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
    if (self.next_button) |next|
        gtk.gtk_widget_set_sensitive(next, boolean(status.queue_length > 0));
    if (self.previous_button) |previous|
        gtk.gtk_widget_set_sensitive(previous, boolean(status.queue_length > 0));

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
                "";
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
                    strings.printZ(&detail_buffer, "{s} — {s}", .{
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
