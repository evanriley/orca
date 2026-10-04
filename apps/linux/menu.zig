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
const strings = @import("strings.zig");
const jobs = @import("jobs.zig");
const ratings = @import("ratings.zig");
const playlists = @import("playlists.zig");
const albums = @import("albums.zig");
const window = @import("window.zig");
const health = @import("health.zig");

const App = app.App;

pub const Kind = enum { tracks, album, artist, queue, playlist };

const FeedbackCounts = struct {
    none: u32 = 0,
    loved: u32 = 0,
    hated: u32 = 0,
};

pub const Context = struct {
    kind: Kind = .tracks,
    tracks: std.ArrayList(i64) = .empty,
    targets: std.ArrayList(feedback.Target) = .empty,
    release_id: ?i64 = null,
    release_loved: bool = false,
    artist_id: ?i64 = null,
    queue_position: ?u32 = null,
    playlist_id: ?i64 = null,
    playlist_position: ?u32 = null,
    playlist_length: u32 = 0,

    pub fn reset(self: *Context, kind: Kind) void {
        self.kind = kind;
        self.tracks.clearRetainingCapacity();
        self.targets.clearRetainingCapacity();
        self.release_id = null;
        self.release_loved = false;
        self.artist_id = null;
        self.queue_position = null;
        self.playlist_id = null;
        self.playlist_position = null;
        self.playlist_length = 0;
    }

    pub fn addTrack(
        self: *Context,
        allocator: std.mem.Allocator,
        track_id: i64,
        recording_id: ?i64,
        current: liborca.Feedback,
    ) !void {
        try self.tracks.ensureUnusedCapacity(allocator, 1);
        try self.targets.append(allocator, .{ .track_id = track_id, .recording_id = recording_id, .feedback = current });
        self.tracks.appendAssumeCapacity(track_id);
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.targets.deinit(allocator);
        self.tracks.deinit(allocator);
    }
};

fn ratingMenu() *gtk.GMenu {
    const stars = gtk.g_menu_new();
    gtk.g_menu_append(stars, "1 Star", "app.ctx-rate(int64 1)");
    gtk.g_menu_append(stars, "2 Stars", "app.ctx-rate(int64 2)");
    gtk.g_menu_append(stars, "3 Stars", "app.ctx-rate(int64 3)");
    gtk.g_menu_append(stars, "4 Stars", "app.ctx-rate(int64 4)");
    gtk.g_menu_append(stars, "5 Stars", "app.ctx-rate(int64 5)");
    const clear = gtk.g_menu_new();
    gtk.g_menu_append(clear, "Clear Rating", "app.ctx-rate(int64 0)");
    const rating = gtk.g_menu_new();
    gtk.g_menu_append_section(rating, null, gtk.cast(gtk.GMenuModel, stars));
    gtk.g_menu_append_section(rating, null, gtk.cast(gtk.GMenuModel, clear));
    gtk.g_object_unref(stars);
    gtk.g_object_unref(clear);
    return rating;
}

fn playlistMenu(self: *App) *gtk.GMenu {
    const create = gtk.g_menu_new();
    gtk.g_menu_append(create, "New Playlist…", "app.ctx-add-to-new-playlist");
    const existing = gtk.g_menu_new();
    for (playlists.choices(self)) |choice| {
        var label_buffer: [512]u8 = undefined;
        var action_buffer: [64]u8 = undefined;
        const action = strings.printZ(&action_buffer, "app.ctx-add-to-playlist(int64 {d})", .{choice.id}) catch continue;
        gtk.g_menu_append(existing, playlists.menuLabel(&label_buffer, choice.name).ptr, action.ptr);
    }
    const choices = gtk.g_menu_new();
    gtk.g_menu_append_section(choices, null, gtk.cast(gtk.GMenuModel, create));
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, existing)) != 0)
        gtk.g_menu_append_section(choices, null, gtk.cast(gtk.GMenuModel, existing));
    gtk.g_object_unref(create);
    gtk.g_object_unref(existing);
    return choices;
}

fn model(self: *App, context: *const Context, counts: FeedbackCounts) *gtk.GMenu {
    const tracks = context.tracks.items.len != 0;
    const playback = gtk.g_menu_new();
    switch (context.kind) {
        .tracks, .album, .artist => {
            gtk.g_menu_append(playback, "Play", "app.ctx-play");
            gtk.g_menu_append(playback, "Play Next", "app.ctx-play-next");
            gtk.g_menu_append(playback, "Add to Queue", "app.ctx-enqueue");
        },
        .queue => {
            gtk.g_menu_append(playback, "Play Now", "app.ctx-play");
            gtk.g_menu_append(playback, "Play Next", "queue.play-next");
            gtk.g_menu_append(playback, "Play Later", "queue.play-later");
            gtk.g_menu_append(playback, "Remove from Queue", "app.ctx-remove");
        },
        .playlist => if (tracks) {
            gtk.g_menu_append(playback, "Play", "app.ctx-play");
            gtk.g_menu_append(playback, "Play Next", "app.ctx-play-next");
            gtk.g_menu_append(playback, "Add to Queue", "app.ctx-enqueue");
        },
    }
    const navigation = gtk.g_menu_new();
    if (context.kind != .album) if (context.release_id) |release_id| {
        if (!window.shows(self, .{ .album = release_id }))
            gtk.g_menu_append(navigation, "Show Album", "app.ctx-show-album");
    };
    if (context.artist_id) |artist_id| {
        if (!window.shows(self, .{ .artist = artist_id }))
            gtk.g_menu_append(navigation, "Show Artist", "app.ctx-show-artist");
    }
    const menu = gtk.g_menu_new();
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, playback)) != 0)
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, playback));
    if (context.kind == .queue) {
        const saving = gtk.g_menu_new();
        gtk.g_menu_append(saving, "Save Queue as Playlist…", "queue.save");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, saving));
        gtk.g_object_unref(saving);
    }
    if (context.kind == .playlist and !playlists.openIsSmart(self)) if (context.playlist_position) |position| {
        const arranging = gtk.g_menu_new();
        gtk.g_menu_append(arranging, "Remove from Playlist", "app.ctx-playlist-remove");
        if (position > 0) gtk.g_menu_append(arranging, "Move Up", "app.ctx-playlist-up");
        if (position + 1 < context.playlist_length) gtk.g_menu_append(arranging, "Move Down", "app.ctx-playlist-down");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, arranging));
        gtk.g_object_unref(arranging);
    };
    const opinion = gtk.g_menu_new();
    defer gtk.g_object_unref(opinion);
    const whole_album = context.kind == .album;
    if (whole_album and context.release_id != null) {
        if (context.release_loved)
            gtk.g_menu_append(opinion, "Remove Album Love", "app.ctx-remove-album-love")
        else
            gtk.g_menu_append(opinion, "Love Album", "app.ctx-love-album");
    }
    if (counts.none != 0) {
        gtk.g_menu_append(opinion, if (whole_album) "Love All Tracks" else "Love", "app.ctx-love");
        gtk.g_menu_append(opinion, if (whole_album) "Dislike All Tracks" else "Dislike", "app.ctx-dislike");
    }
    if (counts.loved != 0)
        gtk.g_menu_append(opinion, if (whole_album) "Remove Love from All Tracks" else "Remove Love", "app.ctx-remove-love");
    if (counts.hated != 0)
        gtk.g_menu_append(opinion, if (whole_album) "Remove Dislike from All Tracks" else "Remove Dislike", "app.ctx-remove-dislike");
    const rates_tracks = switch (context.kind) {
        .tracks, .queue, .playlist => true,
        .album, .artist => false,
    };
    if (tracks and rates_tracks) {
        const rating = ratingMenu();
        gtk.g_menu_append_submenu(opinion, "Rating", gtk.cast(gtk.GMenuModel, rating));
        gtk.g_object_unref(rating);
    }
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, opinion)) != 0)
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, opinion));
    if (tracks and context.kind != .artist) {
        const collecting = gtk.g_menu_new();
        const choices = playlistMenu(self);
        gtk.g_menu_append_submenu(collecting, "Add to Playlist", gtk.cast(gtk.GMenuModel, choices));
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, collecting));
        gtk.g_object_unref(choices);
        gtk.g_object_unref(collecting);
    }
    if (context.kind != .artist and (tracks or context.kind != .playlist)) {
        const editing = gtk.g_menu_new();
        gtk.g_menu_append(editing, "Edit Tags…", "app.ctx-edit-tags");
        if (context.kind == .tracks or context.kind == .album or context.kind == .playlist)
            gtk.g_menu_append(editing, "Write Tags to Files…", "app.ctx-write-tags");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, editing));
        gtk.g_object_unref(editing);
    }
    if (context.tracks.items.len == 1 and rates_tracks) {
        const identification = gtk.g_menu_new();
        gtk.g_menu_append(identification, "Verify", "app.ctx-verify");
        gtk.g_menu_append(identification, "Re-identify", "app.ctx-reidentify");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, identification));
        gtk.g_object_unref(identification);
    }
    if (context.kind == .album and context.release_id != null) {
        const identification = gtk.g_menu_new();
        gtk.g_menu_append(identification, "Match Album", "app.ctx-match-album");
        gtk.g_menu_append(identification, "Verify Album", "app.ctx-verify-album");
        gtk.g_menu_append(identification, "Re-identify Album", "app.ctx-reidentify-album");
        gtk.g_menu_append(identification, "Fetch Cover Art", "app.ctx-fetch-cover-art");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, identification));
        gtk.g_object_unref(identification);
    }
    gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, navigation));
    gtk.g_object_unref(playback);
    gtk.g_object_unref(navigation);
    return menu;
}

fn unparentLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const popover = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(popover);
    if (gtk.gtk_widget_get_parent(popover) != null) gtk.gtk_widget_unparent(popover);
    return gtk.SOURCE_REMOVE;
}

fn unparentWithParent(_: ?*anyopaque, popover: ?*anyopaque) callconv(.c) void {
    const widget = gtk.cast(gtk.Widget, popover.?);
    if (gtk.gtk_widget_get_parent(widget) != null) gtk.gtk_widget_unparent(widget);
}

var unsized_popover: ?*gtk.Popover = null;

/// A popover sends its size as it opens, before its menu has laid out, and
/// only a parent that re-presents it on allocation corrects that; a column
/// view cell does not, so the menu stayed a row short. `gtk_popover_present`
/// re-sends the size only while an allocation is pending.
fn presentUnsized(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const queued = gtk.cast(gtk.Popover, data.?);
    defer gtk.g_object_unref(queued);
    const popover = unsized_popover orelse return gtk.SOURCE_REMOVE;
    if (popover != queued) return gtk.SOURCE_REMOVE;
    unsized_popover = null;
    if (gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, popover)) == null) return gtk.SOURCE_REMOVE;
    gtk.gtk_widget_queue_resize(gtk.cast(gtk.Widget, popover));
    gtk.gtk_popover_present(popover);
    return gtk.SOURCE_REMOVE;
}

fn closed(popover: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (unsized_popover == gtk.cast(gtk.Popover, popover.?)) unsized_popover = null;
    _ = gtk.g_idle_add(unparentLater, gtk.g_object_ref(popover));
}

/// Pops up the menu for `self.context` at `x`, `y` in `widget`.
pub fn popup(self: *App, widget: *gtk.Widget, x: f64, y: f64) void {
    const menu = model(self, &self.context, countFeedback(&self.context));
    defer gtk.g_object_unref(menu);
    popupModel(widget, gtk.cast(gtk.GMenuModel, menu), x, y);
}

/// Pops up the "…" menu of a track row for `self.context`.
pub fn popupRowActions(self: *App, widget: *gtk.Widget, x: f64, y: f64) void {
    const context = &self.context;
    const queueing = gtk.g_menu_new();
    defer gtk.g_object_unref(queueing);
    gtk.g_menu_append(queueing, "Play Next", "app.ctx-play-next");
    gtk.g_menu_append(queueing, "Play Later", "app.ctx-enqueue");
    const navigation = gtk.g_menu_new();
    defer gtk.g_object_unref(navigation);
    if (context.release_id != null) gtk.g_menu_append(navigation, "Go to Album", "app.ctx-show-album");
    if (context.artist_id != null) gtk.g_menu_append(navigation, "Go to Artist", "app.ctx-show-artist");
    const file = gtk.g_menu_new();
    defer gtk.g_object_unref(file);
    gtk.g_menu_append(file, "Edit Metadata…", "app.ctx-edit-tags");
    if (context.tracks.items.len == 1) gtk.g_menu_append(file, "Show in Folder", "app.ctx-show-in-folder");
    const items = gtk.g_menu_new();
    defer gtk.g_object_unref(items);
    if (context.tracks.items.len != 0) gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, queueing));
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, navigation)) != 0)
        gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, navigation));
    if (context.tracks.items.len != 0) gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, file));
    popupModel(widget, gtk.cast(gtk.GMenuModel, items), x, y);
}

fn appendWithAccel(menu: *gtk.GMenu, label: [*:0]const u8, action: [*:0]const u8, accel: ?[*:0]const u8) void {
    const item = gtk.g_menu_item_new(label, action);
    defer gtk.g_object_unref(item);
    if (accel) |value| gtk.g_menu_item_set_attribute_value(item, "accel", gtk.g_variant_new_string(value));
    gtk.g_menu_append_item(menu, item);
}

pub fn popupQueueEntry(self: *App, widget: *gtk.Widget, x: f64, y: f64) void {
    const items = queueEntryModel(self);
    defer gtk.g_object_unref(items);
    gtk.gtk_widget_add_css_class(present(widget, gtk.cast(gtk.GMenuModel, items), pointAt(x, y), null), "queue-menu");
}

pub fn popupQueueEntryBelow(self: *App, button: *gtk.Widget) void {
    const items = queueEntryModel(self);
    defer gtk.g_object_unref(items);
    const bounds: gtk.Rectangle = .{ .x = 0, .y = 0, .width = gtk.gtk_widget_get_width(button), .height = gtk.gtk_widget_get_height(button) };
    gtk.gtk_widget_add_css_class(present(button, gtk.cast(gtk.GMenuModel, items), bounds, gtk.ALIGN_END), "queue-menu");
}

fn queueEntryModel(self: *App) *gtk.GMenu {
    const context = &self.context;
    const queueing = gtk.g_menu_new();
    defer gtk.g_object_unref(queueing);
    appendWithAccel(queueing, "Play Next", "queue.play-next", "<Shift>Return");
    appendWithAccel(queueing, "Play Later", "queue.play-later", null);
    const track = gtk.g_menu_new();
    defer gtk.g_object_unref(track);
    const loved = context.targets.items.len != 0 and context.targets.items[0].feedback == .loved;
    if (loved)
        appendWithAccel(track, "Remove Love", "app.ctx-remove-love", "l")
    else
        appendWithAccel(track, "Love", "app.ctx-love", "l");
    if (context.release_id != null) appendWithAccel(track, "Go to Album", "app.ctx-show-album", null);
    if (context.artist_id != null) appendWithAccel(track, "Go to Artist", "app.ctx-show-artist", null);
    const queue = gtk.g_menu_new();
    defer gtk.g_object_unref(queue);
    appendWithAccel(queue, "Remove from Queue", "app.ctx-remove", "Delete");
    appendWithAccel(queue, "Save Queue as Playlist…", "queue.save", null);
    const items = gtk.g_menu_new();
    gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, queueing));
    gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, track));
    gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, queue));
    return items;
}

pub fn popupModel(widget: *gtk.Widget, menu_model: *gtk.GMenuModel, x: f64, y: f64) void {
    _ = present(widget, menu_model, pointAt(x, y), null);
}

fn pointAt(x: f64, y: f64) gtk.Rectangle {
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
}

fn present(widget: *gtk.Widget, menu_model: *gtk.GMenuModel, anchor: gtk.Rectangle, halign: ?c_int) *gtk.Widget {
    const popover = gtk.gtk_popover_menu_new_from_model(menu_model);
    gtk.gtk_widget_set_parent(popover, widget);
    _ = gtk.g_signal_connect_object(widget, "destroy", gtk.callback(unparentWithParent), popover, 0);
    gtk.gtk_popover_set_has_arrow(gtk.cast(gtk.Popover, popover), gtk.false_);
    gtk.gtk_popover_set_pointing_to(gtk.cast(gtk.Popover, popover), &anchor);
    if (halign) |alignment| {
        gtk.gtk_popover_set_position(gtk.cast(gtk.Popover, popover), gtk.POS_BOTTOM);
        gtk.gtk_widget_set_halign(popover, alignment);
    }
    _ = gtk.signalConnect(popover, "closed", gtk.callback(closed), null);
    gtk.gtk_popover_popup(gtk.cast(gtk.Popover, popover));
    unsized_popover = gtk.cast(gtk.Popover, popover);
    _ = gtk.g_idle_add(presentUnsized, gtk.g_object_ref(popover));
    return popover;
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
    for (context.targets.items) |track| switch (track.feedback) {
        .none => counts.none += 1,
        .loved => counts.loved += 1,
        .hated => counts.hated += 1,
    };
    return counts;
}

pub fn love(self: *App) void {
    feedback.change(self, self.context.targets.items, null, .loved);
}

pub fn dislike(self: *App) void {
    feedback.change(self, self.context.targets.items, null, .hated);
}

pub fn removeLove(self: *App) void {
    feedback.change(self, self.context.targets.items, .loved, .none);
}

pub fn removeDislike(self: *App) void {
    feedback.change(self, self.context.targets.items, .hated, .none);
}

pub fn loveAlbum(self: *App) void {
    albums.setReleaseLove(self, self.context.release_id orelse return, true);
}

pub fn removeAlbumLove(self: *App) void {
    albums.setReleaseLove(self, self.context.release_id orelse return, false);
}

pub fn rate(self: *App, stars: i64) void {
    ratings.change(self, self.context.targets.items, ratings.menuRating(stars));
}

pub fn addToPlaylist(self: *App, playlist_id: i64) void {
    playlists.addTracks(self, playlist_id, self.context.tracks.items);
}

pub fn addToNewPlaylist(self: *App) void {
    if (self.context.tracks.items.len == 0) return;
    playlists.askNew(self, self.context.tracks.items);
}

pub fn removeFromPlaylist(self: *App) void {
    const playlist_id = self.context.playlist_id orelse return;
    playlists.removeAt(self, playlist_id, self.context.playlist_position orelse return);
}

pub fn movePlaylistEntry(self: *App, direction: enum { up, down }) void {
    const playlist_id = self.context.playlist_id orelse return;
    const position = self.context.playlist_position orelse return;
    const to = switch (direction) {
        .up => if (position == 0) return else position - 1,
        .down => if (position + 1 >= self.context.playlist_length) return else position + 1,
    };
    playlists.move(self, playlist_id, position, to);
}

pub fn matchAlbum(self: *App) void {
    jobs.startAlbumMatching(self, self.context.release_id orelse return);
}

pub fn verifyAlbum(self: *App) void {
    jobs.startAlbumVerification(self, self.context.release_id orelse return);
}

pub fn reidentifyAlbum(self: *App) void {
    jobs.startAlbumReidentification(self, self.context.release_id orelse return);
}

pub fn verifyTrack(self: *App) void {
    if (self.context.tracks.items.len != 1) return;
    jobs.startTrackVerification(self, self.context.tracks.items[0]);
}

pub fn reidentifyTrack(self: *App) void {
    if (self.context.tracks.items.len != 1) return;
    jobs.startTrackReidentification(self, self.context.tracks.items[0]);
}

pub fn fetchCoverArt(self: *App) void {
    jobs.startCoverArtFetch(self, self.context.release_id orelse return);
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
        .playlist => if (self.context.playlist_id == self.playlists.open_id)
            playlists.playFrom(self, self.context.playlist_position orelse return),
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
        error.QueueEntryInUse => self.toast("That track is already playing or up next"),
        else => self.toast("Could not remove that entry"),
    };
    self.requestTick();
}
