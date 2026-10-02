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
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const strings = @import("strings.zig");
const browse_model = @import("browse_model.zig");
const page_ui = @import("page.zig");
const song_table = @import("song_table.zig");

const App = app.App;

const queue_limit = 10_000;

pub const navigation_tag = "loved";

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    album_store: ?*gtk.ListStore = null,
    albums_loaded: u32 = 0,
    albums_exhausted: bool = false,
    albums_body: ?*gtk.Stack = null,
    songs: song_table.Table = .{},
    songs_loaded: u32 = 0,
    songs_exhausted: bool = false,
    songs_body: ?*gtk.Stack = null,
    stats: ?*gtk.Widget = null,
    song_count: ?*gtk.Label = null,
    album_count: ?*gtk.Label = null,
    actions: ?*gtk.Widget = null,
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
    showCount(self.loved.album_count, total);
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

fn showCount(label: ?*gtk.Label, count: u64) void {
    var buffer: [24]u8 = undefined;
    const text = strings.printZ(&buffer, "{d}", .{count}) catch return;
    gtk.gtk_label_set_text(label orelse return, text.ptr);
}

fn reloadSongs(self: *App) void {
    const store = self.loved.songs.store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.songs_loaded = 0;
    self.loved.songs_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryTrackMatchCount(library, .{ .loved_only = true }) catch 0;
    showCount(self.loved.song_count, total);
    if (self.loved.actions) |actions| gtk.gtk_widget_set_sensitive(actions, if (total == 0) gtk.false_ else gtk.true_);
    if (self.loved.songs_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");
    loadNextSongs(self);
}

fn loadNextSongs(self: *App) void {
    const store = self.loved.songs.store orelse return;
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
    song_table.repaint(&self.loved.songs, changed, change);
}

fn lovedIds(self: *App) std.ArrayList(i64) {
    var ids: std.ArrayList(i64) = .empty;
    const library = self.library orelse return ids;
    var offset: u32 = 0;
    while (ids.items.len < queue_limit) {
        var page = self.runtime.libraryTrackQuery(library, "", .{
            .loved_only = true,
            .sort = .loved,
            .limit = app.page_size,
            .offset = offset,
        }) catch break;
        defer page.deinit();
        for (page.items) |item| {
            if (ids.items.len == queue_limit) break;
            if (!item.has_playable_file) continue;
            ids.append(self.allocator, item.id) catch break;
        }
        if (page.items.len < app.page_size) break;
        offset += app.page_size;
    }
    return ids;
}

fn playLoved(self: *App, shuffle: bool) void {
    var ids = lovedIds(self);
    defer ids.deinit(self.allocator);
    if (ids.items.len == 0) return self.toast("No loved song has a playable file");
    self.runtime.playerSetShuffle(self.player, shuffle) catch {};
    transport.playIds(self, ids.items, 0);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playLoved(state(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playLoved(state(data), true);
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
    const view = song_table.build(&self.loved.songs, self, .{ .multiple = false, .sortable = false });
    const body = gtk.gtk_stack_new();
    self.loved.songs_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.loved.songs_body.?, scrollerFor(view, gtk.callback(songsScrolled), self), "list");
    _ = gtk.gtk_stack_add_named(
        self.loved.songs_body.?,
        emptyPage("No Loved Songs", "Love a song with the heart in its row."),
        "empty",
    );
    return body;
}

pub fn stat(label: [*:0]const u8) struct { widget: *gtk.Widget, number: *gtk.Label } {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(box, "loved-stat");
    const number = gtk.gtk_label_new("0");
    gtk.gtk_widget_add_css_class(number, "loved-stat-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 1);
    const caption = gtk.gtk_label_new(label);
    gtk.gtk_widget_add_css_class(caption, "loved-stat-label");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, caption), 1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), number);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), caption);
    return .{ .widget = box, .number = gtk.cast(gtk.Label, number) };
}

fn buildHero(self: *App) *gtk.Widget {
    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 24);
    gtk.gtk_widget_add_css_class(hero, "loved-hero");

    const lead = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_set_hexpand(lead, gtk.true_);
    gtk.gtk_widget_set_valign(lead, gtk.ALIGN_END);
    const name = gtk.gtk_label_new("Loved");
    gtk.gtk_widget_add_css_class(name, "display-hero");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    self.loved.actions = actions;
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    const play = albums.pill("Play", "media-playback-start-symbolic", true);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    const shuffle = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), play);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), shuffle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, lead), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, lead), actions);

    const stats = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    self.loved.stats = stats;
    gtk.gtk_widget_add_css_class(stats, "loved-stats");
    gtk.gtk_widget_set_valign(stats, gtk.ALIGN_END);
    const songs = stat("LOVED SONGS");
    self.loved.song_count = songs.number;
    const loved_albums = stat("LOVED ALBUMS");
    self.loved.album_count = loved_albums.number;
    gtk.gtk_box_append(gtk.cast(gtk.Box, stats), songs.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, stats), loved_albums.widget);

    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), lead);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), stats);
    return hero;
}

pub fn build(self: *App) *gtk.Widget {
    const views = adw.adw_view_stack_new();
    const stack = gtk.cast(adw.ViewStack, views);
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildSongs(self), "songs", "Loved Songs", "audio-x-generic-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildAlbums(self), "albums", "Loved Albums", "media-optical-symbolic");
    gtk.gtk_widget_set_vexpand(views, gtk.true_);

    const switcher = adw.adw_view_switcher_new();
    adw.adw_view_switcher_set_stack(gtk.cast(adw.ViewSwitcher, switcher), stack);
    adw.adw_view_switcher_set_policy(gtk.cast(adw.ViewSwitcher, switcher), adw.VIEW_SWITCHER_POLICY_WIDE);
    gtk.gtk_widget_add_css_class(switcher, "loved-tabs");
    gtk.gtk_widget_set_halign(switcher, gtk.ALIGN_START);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildHero(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), switcher);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), views);

    const header = page_ui.header();
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(
        gtk.cast(adw.ToolbarView, view),
        details.besideContent(self, header, column, .{ .selection = self.loved.songs.selection.? }).widget,
    );

    const navigation = adw.adw_navigation_view_new();
    self.loved.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Loved");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(self.loved.navigation.?, root);
    return navigation;
}
