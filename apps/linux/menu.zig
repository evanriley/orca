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
    songs: std.ArrayList(feedback.Target) = .empty,
    release_id: ?i64 = null,
    artist_id: ?i64 = null,
    queue_position: ?u32 = null,
    playlist_id: ?i64 = null,
    playlist_position: ?u32 = null,
    playlist_length: u32 = 0,

    pub fn reset(self: *Context, kind: Kind) void {
        self.kind = kind;
        self.tracks.clearRetainingCapacity();
        self.songs.clearRetainingCapacity();
        self.release_id = null;
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
        try self.songs.append(allocator, .{ .track_id = track_id, .recording_id = recording_id, .feedback = current });
        self.tracks.appendAssumeCapacity(track_id);
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.songs.deinit(allocator);
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
    for (playlists.names(self), playlists.ids(self)) |name, id| {
        var label_buffer: [512]u8 = undefined;
        var action_buffer: [64]u8 = undefined;
        const action = strings.printZ(&action_buffer, "app.ctx-add-to-playlist(int64 {d})", .{id}) catch continue;
        gtk.g_menu_append(existing, playlists.menuLabel(&label_buffer, name).ptr, action.ptr);
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
    const songs = context.tracks.items.len != 0;
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
        .playlist => if (songs) {
            gtk.g_menu_append(playback, "Play", "app.ctx-play");
            gtk.g_menu_append(playback, "Play Next", "app.ctx-play-next");
            gtk.g_menu_append(playback, "Add to Queue", "app.ctx-enqueue");
        },
    }
    const navigation = gtk.g_menu_new();
    if (context.kind != .album and context.release_id != null)
        gtk.g_menu_append(navigation, "Show Album", "app.ctx-show-album");
    if (context.artist_id != null)
        gtk.g_menu_append(navigation, "Show Artist", "app.ctx-show-artist");
    const menu = gtk.g_menu_new();
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, playback)) != 0)
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, playback));
    if (context.kind == .playlist) if (context.playlist_position) |position| {
        const arranging = gtk.g_menu_new();
        gtk.g_menu_append(arranging, "Remove from Playlist", "app.ctx-playlist-remove");
        if (position > 0) gtk.g_menu_append(arranging, "Move Up", "app.ctx-playlist-up");
        if (position + 1 < context.playlist_length) gtk.g_menu_append(arranging, "Move Down", "app.ctx-playlist-down");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, arranging));
        gtk.g_object_unref(arranging);
    };
    const opinion = gtk.g_menu_new();
    defer gtk.g_object_unref(opinion);
    if (counts.none != 0) {
        gtk.g_menu_append(opinion, "Love", "app.ctx-love");
        gtk.g_menu_append(opinion, "Dislike", "app.ctx-dislike");
    }
    if (counts.loved != 0) gtk.g_menu_append(opinion, "Remove Love", "app.ctx-remove-love");
    if (counts.hated != 0) gtk.g_menu_append(opinion, "Remove Dislike", "app.ctx-remove-dislike");
    const rates_songs = switch (context.kind) {
        .tracks, .queue, .playlist => true,
        .album, .artist => false,
    };
    if (songs and rates_songs) {
        const rating = ratingMenu();
        gtk.g_menu_append_submenu(opinion, "Rating", gtk.cast(gtk.GMenuModel, rating));
        gtk.g_object_unref(rating);
    }
    if (gtk.g_menu_model_get_n_items(gtk.cast(gtk.GMenuModel, opinion)) != 0)
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, opinion));
    if (songs and context.kind != .artist) {
        const collecting = gtk.g_menu_new();
        const choices = playlistMenu(self);
        gtk.g_menu_append_submenu(collecting, "Add to Playlist", gtk.cast(gtk.GMenuModel, choices));
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, collecting));
        gtk.g_object_unref(choices);
        gtk.g_object_unref(collecting);
    }
    if (context.kind != .artist and (songs or context.kind != .playlist)) {
        const editing = gtk.g_menu_new();
        gtk.g_menu_append(editing, "Edit Tags…", "app.ctx-edit-tags");
        if (context.kind == .tracks or context.kind == .album or context.kind == .playlist)
            gtk.g_menu_append(editing, "Write Tags to Files…", "app.ctx-write-tags");
        gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, editing));
        gtk.g_object_unref(editing);
    }
    if (context.tracks.items.len == 1 and rates_songs) {
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
    const menu = model(self, &self.context, countFeedback(&self.context));
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

pub fn rate(self: *App, stars: i64) void {
    ratings.change(self, self.context.songs.items, ratings.menuRating(stars));
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
        error.QueueEntryInUse => self.toast("That song is already playing or up next"),
        else => self.toast("Could not remove that entry"),
    };
    self.requestTick();
}
