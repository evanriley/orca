//! Love and dislike: the heart in the player bar, the heart button on every
//! song row, and the one place a change is applied and shown.
//!
//! The choice belongs to liborca and is kept per recording; this only asks for
//! it and repaints what displays it.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const track_model = @import("track_model.zig");
const song_table = @import("song_table.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const details = @import("details.zig");
const queue = @import("queue.zig");
const nowplaying = @import("nowplaying.zig");
const playlists = @import("playlists.zig");
const loved = @import("loved.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;

pub const filled_icon = "orca-heart-filled-symbolic";
const outline_icon = "orca-heart-outline-symbolic";
const heart_pixels: c_int = 14;
const album_heart_pixels: c_int = 16;
const change_batch = 512;

pub fn newRowButton(handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const button = newHeartButton(handler, data);
    gtk.gtk_widget_add_css_class(button, "row-heart");
    gtk.gtk_widget_set_focus_on_click(button, gtk.false_);
    showButton(button, .none);
    return button;
}

pub fn showRowButton(button: *gtk.Widget, feedback: liborca.Feedback) void {
    showButton(button, feedback);
}

pub fn newAlbumButton(handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const button = newHeartButton(handler, data);
    gtk.gtk_widget_remove_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "album-heart");
    if (gtk.gtk_button_get_child(gtk.cast(gtk.Button, button))) |image|
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), album_heart_pixels);
    showAlbumButton(button, false);
    return button;
}

pub fn showAlbumButton(button: *gtk.Widget, album_loved: bool) void {
    showHeart(button, album_loved, if (album_loved) "Remove Album Love" else "Love Album");
}

pub fn newButton(self: *App, handler: gtk.GCallback) *gtk.Widget {
    const button = newHeartButton(handler, self);
    gtk.gtk_widget_set_sensitive(button, gtk.false_);
    self.love_button = button;
    showButton(button, .none);
    return button;
}

pub fn newNowPlayingButton(self: *App, handler: gtk.GCallback) *gtk.Widget {
    const button = newHeartButton(handler, self);
    gtk.gtk_widget_set_sensitive(button, gtk.false_);
    self.now_love_button = button;
    showButton(button, .none);
    return button;
}

fn newHeartButton(handler: gtk.GCallback, data: ?*anyopaque) *gtk.Widget {
    const image = gtk.gtk_image_new_from_icon_name(outline_icon);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), heart_pixels);
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), image);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "circular");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(button, "clicked", handler, data);
    return button;
}

fn showButton(button: *gtk.Widget, feedback: liborca.Feedback) void {
    const is_loved = feedback == .loved;
    showHeart(button, is_loved, if (is_loved) "Remove Love" else "Love");
}

fn showHeart(button: *gtk.Widget, filled: bool, label: [*:0]const u8) void {
    const image = gtk.gtk_button_get_child(gtk.cast(gtk.Button, button)) orelse return;
    gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, image), if (filled) filled_icon else outline_icon);
    if (filled) {
        gtk.gtk_widget_add_css_class(image, "loved-heart");
        gtk.gtk_widget_add_css_class(button, "loved");
    } else {
        gtk.gtk_widget_remove_css_class(image, "loved-heart");
        gtk.gtk_widget_remove_css_class(button, "loved");
    }
    gtk.gtk_widget_set_tooltip_text(button, label);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
}

pub const Target = struct {
    track_id: i64,
    recording_id: ?i64,
    feedback: liborca.Feedback,
};

pub const Recordings = std.AutoHashMapUnmanaged(i64, void);

pub fn showPlaying(self: *App) void {
    for ([_]?*gtk.Widget{ self.love_button, self.now_love_button }) |maybe_button| {
        const button = maybe_button orelse continue;
        if (self.shown_track_id == null) {
            gtk.gtk_widget_set_sensitive(button, gtk.false_);
            showButton(button, .none);
            continue;
        }
        gtk.gtk_widget_set_sensitive(button, gtk.true_);
        showButton(button, self.shown_feedback);
    }
}

pub fn toggleLoveOfPlaying(self: *App) void {
    const track_id = self.shown_track_id orelse return;
    const target: Target = .{
        .track_id = track_id,
        .recording_id = self.shown_recording_id,
        .feedback = self.shown_feedback,
    };
    toggle(self, target);
}

pub fn toggle(self: *App, target: Target) void {
    change(self, &.{target}, null, if (target.feedback == .loved) .none else .loved);
}

pub fn change(self: *App, targets: []const Target, only: ?liborca.Feedback, value: liborca.Feedback) void {
    const library = self.library orelse return;
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(self.allocator);
    var chosen: std.ArrayList(Target) = .empty;
    defer chosen.deinit(self.allocator);
    for (targets) |target| {
        if (only) |wanted| if (target.feedback != wanted) continue;
        ids.append(self.allocator, target.track_id) catch return self.toast("Out of memory");
        chosen.append(self.allocator, target) catch return self.toast("Out of memory");
    }
    var changed: Recordings = .empty;
    defer changed.deinit(self.allocator);
    var updated: u32 = 0;
    var start: usize = 0;
    var failed = false;
    while (start < ids.items.len) : (start += change_batch) {
        const end = @min(start + change_batch, ids.items.len);
        const result = self.runtime.librarySetFeedback(library, ids.items[start..end], value) catch {
            failed = true;
            break;
        };
        updated += result.updated;
        for (chosen.items[start..end]) |target| {
            const recording = target.recording_id orelse continue;
            changed.put(self.allocator, recording, {}) catch return self.toast("Out of memory");
        }
    }
    if (failed) self.toast("Could not save that");
    if (changed.count() == 0) {
        if (!failed and chosen.items.len != 0) self.toast("Nothing was changed");
        return;
    }
    repaint(self, &changed, value);
    self.requestTick();
}

fn repaint(self: *App, changed: *const Recordings, value: liborca.Feedback) void {
    if (self.shown_recording_id) |recording| if (changed.contains(recording)) {
        self.shown_feedback = value;
    };
    showPlaying(self);
    repaintLists(self, changed, .{ .feedback = value });
}

/// Shows `change` on every listed song whose recording is in `changed`.
pub fn repaintLists(self: *App, changed: *const Recordings, change_value: track_model.Change) void {
    repaintRows(self, changed, change_value);
    albums.repaint(self, changed, change_value);
    artists.repaint(self, changed, change_value);
    queue.repaint(self, changed, change_value);
    nowplaying.repaint(changed, change_value);
    playlists.repaint(self, changed, change_value);
    loved.repaint(self, changed, change_value);
    details.invalidate(self);
}

/// Replaces, in place, each row of `store` whose recording changed, with a copy
/// that carries the new value: a list view rebinds the widget of an item it is
/// given anew, and nothing else about the list moves.
pub fn replaceRows(store: *gtk.ListStore, changed: *const Recordings, change_value: track_model.Change) bool {
    const model = gtk.cast(gtk.ListModel, store);
    const count = gtk.g_list_model_get_n_items(model);
    var replaced = false;
    var index: c_uint = 0;
    while (index < count) : (index += 1) {
        const item = gtk.g_list_model_get_item(model, index) orelse continue;
        defer gtk.g_object_unref(item);
        const row: *TrackObject = @ptrCast(@alignCast(item));
        const recording = row.recordingId() orelse continue;
        if (!changed.contains(recording)) continue;
        var probe = row.fields().*;
        if (!change_value.apply(&probe)) continue;
        const copy = track_model.clone(row) orelse continue;
        _ = change_value.apply(copy.fields());
        var replacement: [1]?*anyopaque = .{copy};
        gtk.g_list_store_splice(store, index, 1, &replacement, 1);
        gtk.g_object_unref(copy);
        replaced = true;
    }
    return replaced;
}

fn repaintRows(self: *App, changed: *const Recordings, change_value: track_model.Change) void {
    song_table.repaint(&self.songs, changed, change_value);
}
