//! The Loved page: the loved albums and the loved songs, most recently loved
//! first.
//!
//! liborca keeps both kinds of love and orders them; this asks for a page at
//! a time and shows it. The page is reread whenever it is shown, so a heart
//! cleared on it leaves its row in place until then.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const albums = @import("albums.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const playlists = @import("playlists.zig");
const browse_model = @import("browse_model.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;

pub const navigation_tag = "loved";

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    album_store: ?*gtk.ListStore = null,
    albums_loaded: u32 = 0,
    albums_exhausted: bool = false,
    albums_body: ?*gtk.Stack = null,
    song_store: ?*gtk.ListStore = null,
    songs_loaded: u32 = 0,
    songs_exhausted: bool = false,
    songs_body: ?*gtk.Stack = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

pub fn reload(self: *App) void {
    reloadAlbums(self);
    reloadSongs(self);
}

fn reloadAlbums(self: *App) void {
    const store = self.loved.album_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.albums_loaded = 0;
    self.loved.albums_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryReleaseCountMatching(library, .{ .loved_only = true }) catch 0;
    if (self.loved.albums_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "grid");
    loadNextAlbums(self);
}

fn loadNextAlbums(self: *App) void {
    const store = self.loved.album_store orelse return;
    if (self.loved.albums_exhausted) return;
    const loaded = albums.appendReleasePage(self, store, .{
        .loved_only = true,
        .sort = .loved,
        .limit = app.page_size,
        .offset = self.loved.albums_loaded,
    }) orelse {
        self.loved.albums_exhausted = true;
        return;
    };
    if (loaded < app.page_size) self.loved.albums_exhausted = true;
    self.loved.albums_loaded += loaded;
}

fn reloadSongs(self: *App) void {
    const store = self.loved.song_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.songs_loaded = 0;
    self.loved.songs_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryTrackMatchCount(library, .{ .loved_only = true }) catch 0;
    if (self.loved.songs_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");
    loadNextSongs(self);
}

fn loadNextSongs(self: *App) void {
    const store = self.loved.song_store orelse return;
    if (self.loved.songs_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryTrackQuery(library, "", .{
        .loved_only = true,
        .sort = .loved,
        .limit = app.page_size,
        .offset = self.loved.songs_loaded,
    }) catch {
        self.loved.songs_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.loved.songs_exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (additions.items) |row| gtk.g_object_unref(row);
        additions.deinit(self.allocator);
    }
    for (page.items) |summary| {
        const row = track_model.new(summary) orelse continue;
        additions.append(self.allocator, row) catch {
            gtk.g_object_unref(row);
            break;
        };
    }
    if (additions.items.len != 0) gtk.g_list_store_splice(
        store,
        gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
        0,
        additions.items.ptr,
        @intCast(additions.items.len),
    );
    self.loved.songs_loaded += @intCast(page.items.len);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const store = self.loved.song_store orelse return;
    _ = feedback.replaceRows(store, changed, change);
}

fn nearEnd(adjustment: ?*anyopaque) bool {
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    return remaining < page * 2;
}

fn albumsScrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (!self.loved.albums_exhausted and nearEnd(adjustment)) loadNextAlbums(self);
}

fn songsScrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (!self.loved.songs_exhausted and nearEnd(adjustment)) loadNextSongs(self);
}

fn albumActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.loved.album_store orelse return;
    const id = albums.releaseAt(store, position) orelse return;
    albums.openAlbum(self, self.loved.navigation orelse return, id);
}

fn songActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.loved.song_store orelse return;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *TrackObject = @ptrCast(@alignCast(item));
    if (!row.hasFile()) return self.toast("That track has no playable file");
    transport.playIds(self, &.{row.id()}, 0);
}

fn setupSong(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playlists.setupSongRow(state(data), item, songMenu);
}

fn songMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    self.context.reset(.tracks);
    if (track.hasFile()) self.context.addTrack(self.allocator, track.id(), track.recordingId(), track.feedback()) catch return;
    self.context.release_id = track.releaseId();
    self.context.artist_id = track.artistId();
    menu.popup(self, row, x, y);
}

fn emptyPage(title: [*:0]const u8, description: [*:0]const u8) *gtk.Widget {
    const page = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, page), feedback.filled_icon);
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, page), title);
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, page), description);
    return page;
}

fn scrollerFor(child: *gtk.Widget, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), child);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        handler,
        self,
    );
    return scroller;
}

fn buildAlbums(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.loved.album_store = store;
    const grid = albums.newGrid(self, store, gtk.callback(albumActivated));
    const body = gtk.gtk_stack_new();
    self.loved.albums_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.loved.albums_body.?, scrollerFor(grid, gtk.callback(albumsScrolled), self), "grid");
    _ = gtk.gtk_stack_add_named(
        self.loved.albums_body.?,
        emptyPage("No Loved Albums", "Love an album with the heart on its page or from its menu."),
        "empty",
    );
    return body;
}

fn buildSongs(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(track_model.getType()).?;
    self.loved.song_store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupSong), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(playlists.bindRow), self);
    const list = gtk.gtk_list_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(list, "playlist-list");
    _ = gtk.signalConnect(list, "activate", gtk.callback(songActivated), self);
    const body = gtk.gtk_stack_new();
    self.loved.songs_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.loved.songs_body.?, scrollerFor(list, gtk.callback(songsScrolled), self), "list");
    _ = gtk.gtk_stack_add_named(
        self.loved.songs_body.?,
        emptyPage("No Loved Songs", "Love a song with the heart beside its title."),
        "empty",
    );
    return body;
}

pub fn build(self: *App) *gtk.Widget {
    const views = adw.adw_view_stack_new();
    const stack = gtk.cast(adw.ViewStack, views);
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildAlbums(self), "albums", "Albums", "media-optical-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildSongs(self), "songs", "Songs", "audio-x-generic-symbolic");

    const switcher = adw.adw_view_switcher_new();
    adw.adw_view_switcher_set_stack(gtk.cast(adw.ViewSwitcher, switcher), stack);
    adw.adw_view_switcher_set_policy(gtk.cast(adw.ViewSwitcher, switcher), adw.VIEW_SWITCHER_POLICY_WIDE);
    const header = adw.adw_header_bar_new();
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), switcher);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), views);

    const navigation = adw.adw_navigation_view_new();
    self.loved.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Loved");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(self.loved.navigation.?, root);
    return navigation;
}
