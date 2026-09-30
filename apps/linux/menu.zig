//! Right-click menus for tracks, albums, artists and queue entries.
//!
//! A menu acts on the thing it was opened on, which is recorded here before
//! it pops up; its items are parameterless `app.ctx-*` actions that read that
//! record. The popover is parented to the clicked widget, so the actions
//! resolve through it, and it is unparented on idle after it closes: the item
//! activates after `closed`, and a popover already unparented by then would
//! no longer find the application's actions.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const transport = @import("transport.zig");
const mpris = @import("mpris.zig");
const feedback = @import("feedback.zig");

const App = app.App;

pub const Kind = enum { tracks, album, artist, queue };

const FeedbackCounts = struct {
    none: u32 = 0,
    loved: u32 = 0,
    hated: u32 = 0,
};

pub const Context = struct {
    kind: Kind = .tracks,
    tracks: std.ArrayList(i64) = .empty,
    songs: std.ArrayList(feedback.Target) = .empty,
    release_id: ?i64 = null,
    artist_id: ?i64 = null,
    queue_position: ?u32 = null,

    pub fn reset(self: *Context, kind: Kind) void {
        self.kind = kind;
        self.tracks.clearRetainingCapacity();
        self.songs.clearRetainingCapacity();
        self.release_id = null;
        self.artist_id = null;
        self.queue_position = null;
    }

    pub fn addTrack(
        self: *Context,
        allocator: std.mem.Allocator,
        track_id: i64,
        recording_id: ?i64,
        current: liborca.Feedback,
    ) !void {
        try self.tracks.ensureUnusedCapacity(allocator, 1);
        try self.songs.append(allocator, .{ .track_id = track_id, .recording_id = recording_id, .feedback = current });
        self.tracks.appendAssumeCapacity(track_id);
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.songs.deinit(allocator);
        self.tracks.deinit(allocator);
    }
};

fn model(context: *const Context, counts: FeedbackCounts) *gtk.GMenu {
    const playback = gtk.g_menu_new();
    switch (context.kind) {
        .tracks, .album, .artist => {
            gtk.g_menu_append(playback, "Play", "app.ctx-play");
            gtk.g_menu_append(playback, "Play Next", "app.ctx-play-next");
            gtk.g_menu_append(playback, "Add to Queue", "app.ctx-enqueue");
        },
        .queue => {
            gtk.g_menu_append(playback, "Play", "app.ctx-play");
            gtk.g_menu_append(playback, "Remove from Queue", "app.ctx-remove");
        },
    }
    const navigation = gtk.g_menu_new();
    if (context.kind != .album and context.release_id != null)
        gtk.g_menu_append(navigation, "Show Album", "app.ctx-show-album");
    if (context.artist_id != null)
        gtk.g_menu_append(navigation, "Show Artist", "app.ctx-show-artist");
    const menu = gtk.g_menu_new();
    gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, playback));
    const opinion = gtk.g_menu_new();
    defer gtk.g_object_unref(opinion);
    if (counts.none != 0) {
        gtk.g_menu_append(opinion, "Love", "app.ctx-love");
        gtk.g_menu_append(opinion, "Dislike", "app.ctx-dislike");
    }
    if (counts.loved != 0) gtk.g_menu_append(opinion, "Remove Love", "app.ctx-remove-love");
    if (counts.hated != 0) gtk.g_menu_append(opinion, "Remove Dislike", "app.ctx-remove-dislike");
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, opinion)) != 0)
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, opinion));
    if (context.kind != .artist) {
        const editing = gtk.g_menu_new();
        gtk.g_menu_append(editing, "Edit Tags…", "app.ctx-edit-tags");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, editing));
        gtk.g_object_unref(editing);
    }
    gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, navigation));
    gtk.g_object_unref(playback);
    gtk.g_object_unref(navigation);
    return menu;
}

fn unparentLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const popover = gtk.cast(gtk.Widget, data.?);
    if (gtk.gtk_widget_get_parent(popover) != null) gtk.gtk_widget_unparent(popover);
    return gtk.SOURCE_REMOVE;
}

var unsized_popover: ?*gtk.Popover = null;

/// A popover sends its size as it opens, before its menu has laid out, and
/// only a parent that re-presents it on allocation corrects that; a column
/// view cell does not, so the menu stayed a row short. `gtk_popover_present`
/// re-sends the size only while an allocation is pending.
fn presentUnsized(_: ?*anyopaque) callconv(.c) gtk.gboolean {
    const popover = unsized_popover orelse return gtk.SOURCE_REMOVE;
    unsized_popover = null;
    gtk.gtk_widget_queue_resize(gtk.cast(gtk.Widget, popover));
    gtk.gtk_popover_present(popover);
    return gtk.SOURCE_REMOVE;
}

fn closed(popover: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (unsized_popover == gtk.cast(gtk.Popover, popover.?)) unsized_popover = null;
    _ = gtk.g_idle_add(unparentLater, popover);
}

/// Pops up the menu for `self.context` at `x`, `y` in `widget`.
pub fn popup(self: *App, widget: *gtk.Widget, x: f64, y: f64) void {
    const menu = model(&self.context, countFeedback(&self.context));
    defer gtk.g_object_unref(menu);
    const popover = gtk.gtk_popover_menu_new_from_model(gtk.cast(gtk.GMenuModel, menu));
    gtk.gtk_widget_set_parent(popover, widget);
    gtk.gtk_popover_set_has_arrow(gtk.cast(gtk.Popover, popover), gtk.false_);
    const point: gtk.Rectangle = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    gtk.gtk_popover_set_pointing_to(gtk.cast(gtk.Popover, popover), &point);
    _ = gtk.signalConnect(popover, "closed", gtk.callback(closed), null);
    gtk.gtk_popover_popup(gtk.cast(gtk.Popover, popover));
    unsized_popover = gtk.cast(gtk.Popover, popover);
    _ = gtk.g_idle_add(presentUnsized, null);
}

/// A right-button click gesture on `widget`, calling `handler` with the
/// widget, its coordinates and `data`.
pub fn onSecondaryClick(
    widget: *gtk.Widget,
    handler: *const fn (?*anyopaque, c_int, f64, f64, ?*anyopaque) callconv(.c) void,
    data: ?*anyopaque,
) void {
    const gesture = gtk.gtk_gesture_click_new();
    gtk.gtk_gesture_single_set_button(gtk.cast(gtk.GestureSingle, gesture), 3);
    _ = gtk.signalConnect(gesture, "pressed", gtk.callback(handler), data);
    gtk.gtk_widget_add_controller(widget, gesture);
}

pub fn playingMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    const current = mpris.nowPlaying(self.runtime, self.player) orelse return;
    defer current.deinit();
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, current.summary.id, current.summary.recording_id, current.summary.feedback) catch return;
    self.context.release_id = current.summary.release_id;
    self.context.artist_id = current.summary.artist_id;
    popup(self, gestureWidget(gesture), x, y);
}

pub fn gestureWidget(gesture: ?*anyopaque) *gtk.Widget {
    return gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture));
}

fn countFeedback(context: *const Context) FeedbackCounts {
    var counts: FeedbackCounts = .{};
    for (context.songs.items) |song| switch (song.feedback) {
        .none => counts.none += 1,
        .loved => counts.loved += 1,
        .hated => counts.hated += 1,
    };
    return counts;
}

pub fn love(self: *App) void {
    feedback.change(self, self.context.songs.items, null, .loved);
}

pub fn dislike(self: *App) void {
    feedback.change(self, self.context.songs.items, null, .hated);
}

pub fn removeLove(self: *App) void {
    feedback.change(self, self.context.songs.items, .loved, .none);
}

pub fn removeDislike(self: *App) void {
    feedback.change(self, self.context.songs.items, .hated, .none);
}

pub fn play(self: *App) void {
    switch (self.context.kind) {
        .queue => {
            const position = self.context.queue_position orelse return;
            self.runtime.playerQueueJump(self.player, position) catch
                self.toast("Could not play that entry");
            self.mpris.notify();
            self.requestTick();
        },
        else => transport.playIds(self, self.context.tracks.items, 0),
    }
}

pub fn playNext(self: *App) void {
    const library = self.library orelse return;
    if (self.context.tracks.items.len == 0) return;
    if (!transport.ensureOutput(self)) return self.toast("No audio output is available");
    self.runtime.playerQueueInsertNext(self.player, library, self.context.tracks.items) catch
        return self.toast("Could not queue that");
    self.toast(if (self.context.tracks.items.len == 1) "Playing next" else "Playing these next");
    self.requestTick();
}

pub fn enqueue(self: *App) void {
    const library = self.library orelse return;
    if (self.context.tracks.items.len == 0) return;
    if (!transport.ensureOutput(self)) return self.toast("No audio output is available");
    self.runtime.playerEnqueueTracksBound(self.player, library, self.context.tracks.items) catch
        return self.toast("Could not queue that");
    self.toast("Added to the queue");
    self.requestTick();
}

pub fn remove(self: *App) void {
    const position = self.context.queue_position orelse return;
    self.runtime.playerQueueRemove(self.player, position) catch |err| switch (err) {
        error.QueueEntryInUse => self.toast("That song is already playing or up next"),
        else => self.toast("Could not remove that entry"),
    };
    self.requestTick();
}
