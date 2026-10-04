//! The Loved page: the loved tracks, albums and artists, most recently loved
//! first.
//!
//! liborca keeps every kind of love and orders it; this asks for a page at a
//! time and shows it. The page is reread whenever it is shown, so a heart
//! cleared on it leaves its row in place until then.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const artist_page = @import("artist_page.zig");
const art = @import("art.zig");
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const menu = @import("menu.zig");
const page_ui = @import("page.zig");
const strings = @import("strings.zig");
const browse_model = @import("browse_model.zig");
const track_table = @import("track_table.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const queue_limit = 10_000;
const artist_pixels: c_int = 148;
const cover_pixels: c_int = 34;
const cover_column_width: c_int = 48;
const track_columns = track_table.ColumnSet.initMany(&.{ .number, .title, .artist, .album, .rating, .last_played, .duration, .more });
const ColumnWidth = struct { column: track_table.Column, pixels: c_int };
const column_widths = [_]ColumnWidth{
    .{ .column = .number, .pixels = 48 },
    .{ .column = .rating, .pixels = 122 },
    .{ .column = .last_played, .pixels = 150 },
    .{ .column = .duration, .pixels = 70 },
};

const Tab = enum { tracks, albums, artists };
const tab_labels = std.EnumArray(Tab, [*:0]const u8).init(.{ .tracks = "Tracks", .albums = "Albums", .artists = "Artists" });
const tab_icons = std.EnumArray(Tab, [*:0]const u8).init(.{
    .tracks = "orca-tracks-symbolic",
    .albums = "orca-albums-symbolic",
    .artists = "orca-artists-symbolic",
});

pub const navigation_tag = "loved";

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    album_store: ?*gtk.ListStore = null,
    albums_loaded: u32 = 0,
    albums_exhausted: bool = false,
    albums_body: ?*gtk.Stack = null,
    albums_empty: ?*adw.StatusPage = null,
    tracks: track_table.Table = .{},
    tracks_loaded: u32 = 0,
    tracks_exhausted: bool = false,
    tracks_body: ?*gtk.Stack = null,
    tracks_empty: ?*adw.StatusPage = null,
    artist_store: ?*gtk.ListStore = null,
    artists_loaded: u32 = 0,
    artists_exhausted: bool = false,
    artists_body: ?*gtk.Stack = null,
    artists_empty: ?*adw.StatusPage = null,
    stats: ?*gtk.Widget = null,
    tabs: ?*gtk.Stack = null,
    track_count: ?*gtk.Label = null,
    album_count: ?*gtk.Label = null,
    artist_count: ?*gtk.Label = null,
    actions: ?*gtk.Widget = null,
    filter: app.OwnedText = .{},
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

pub fn setFilter(self: *App, text: []const u8) void {
    if (std.mem.eql(u8, text, self.loved.filter.value)) return;
    self.loved.filter.set(self.allocator, text);
    reload(self);
}

fn showTotals(self: *App) void {
    const library = self.library orelse return;
    const tracks = self.runtime.libraryTrackMatchCount(library, .{ .loved_only = true }) catch 0;
    showCount(self.loved.track_count, tracks);
    showCount(self.loved.album_count, self.runtime.libraryReleaseCountMatching(library, .{ .loved_only = true }) catch 0);
    showCount(self.loved.artist_count, self.runtime.libraryArtistCountMatching(library, .{ .loved_only = true }) catch 0);
    if (self.loved.actions) |actions| gtk.gtk_widget_set_sensitive(actions, if (tracks == 0) gtk.false_ else gtk.true_);
}

fn showEmpty(self: *App, tab: Tab) void {
    const page = switch (tab) {
        .tracks => self.loved.tracks_empty,
        .albums => self.loved.albums_empty,
        .artists => self.loved.artists_empty,
    } orelse return;
    const searching = self.loved.filter.value.len != 0;
    const title: [*:0]const u8, const description: [*:0]const u8 = switch (tab) {
        .tracks => if (searching)
            .{ "No matching loved tracks", "Try another search." }
        else
            .{ "No Loved Tracks", "Love a track with the heart in its row." },
        .albums => if (searching)
            .{ "No matching loved albums", "Try another search." }
        else
            .{ "No Loved Albums", "Love an album with the heart on its page or from its menu." },
        .artists => if (searching)
            .{ "No matching loved artists", "Try another search." }
        else
            .{ "No Loved Artists", "Love an artist with the heart on their page." },
    };
    adw.adw_status_page_set_title(page, title);
    adw.adw_status_page_set_description(page, description);
}

pub fn reload(self: *App) void {
    showTotals(self);
    reloadAlbums(self);
    reloadTracks(self);
    reloadArtists(self);
}

pub fn releaseChanged(self: *App, release_id: i64) void {
    releaseMoved(self, release_id, release_id);
}

pub fn releaseMoved(self: *App, old_id: i64, new_id: i64) void {
    if (self.loved.album_store) |store| switch (albums.refreshReleaseRow(self, store, old_id, new_id)) {
        .release_gone, .merged => {
            const scroll = page_ui.visibleScroll(self.loved.albums_body);
            const loaded = self.loved.albums_loaded;
            reloadAlbums(self);
            while (!self.loved.albums_exhausted and self.loved.albums_loaded < loaded) {
                const before = self.loved.albums_loaded;
                loadNextAlbums(self);
                if (self.loved.albums_loaded == before) break;
            }
            if (scroll) |kept| page_ui.restoreScroll(self, kept);
        },
        .not_listed, .replaced => {},
    };
    track_table.refreshRelease(&self.loved.tracks, old_id);
    if (new_id != old_id) track_table.refreshRelease(&self.loved.tracks, new_id);
}

fn reloadAlbums(self: *App) void {
    const store = self.loved.album_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.albums_loaded = 0;
    self.loved.albums_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryReleaseCountMatching(library, .{ .loved_only = true, .text = self.loved.filter.value }) catch 0;
    showEmpty(self, .albums);
    if (self.loved.albums_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "grid");
    loadNextAlbums(self);
}

fn loadNextAlbums(self: *App) void {
    const store = self.loved.album_store orelse return;
    if (self.loved.albums_exhausted) return;
    const loaded = albums.appendReleasePage(self, store, .{
        .loved_only = true,
        .text = self.loved.filter.value,
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

fn reloadTracks(self: *App) void {
    const store = self.loved.tracks.store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.tracks_loaded = 0;
    self.loved.tracks_exhausted = false;
    const library = self.library orelse return;
    const total = if (self.runtime.libraryTrackQueryTotals(library, self.loved.filter.value, .{ .loved_only = true })) |totals| totals.count else |_| 0;
    showEmpty(self, .tracks);
    if (self.loved.tracks_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");
    loadNextTracks(self);
}

fn loadNextTracks(self: *App) void {
    const store = self.loved.tracks.store orelse return;
    if (self.loved.tracks_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryTrackQuery(library, self.loved.filter.value, .{
        .loved_only = true,
        .sort = .loved,
        .limit = app.page_size,
        .offset = self.loved.tracks_loaded,
    }) catch {
        self.loved.tracks_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.loved.tracks_exhausted = true;
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
    appendRows(store, additions.items);
    self.loved.tracks_loaded += @intCast(page.items.len);
}

fn appendRows(store: *gtk.ListStore, rows: []?*anyopaque) void {
    if (rows.len == 0) return;
    gtk.g_list_store_splice(
        store,
        gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
        0,
        rows.ptr,
        @intCast(rows.len),
    );
}

fn reloadArtists(self: *App) void {
    const store = self.loved.artist_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.artists_loaded = 0;
    self.loved.artists_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryArtistCountMatching(library, .{ .loved_only = true, .filter = self.loved.filter.value }) catch 0;
    showEmpty(self, .artists);
    if (self.loved.artists_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "grid");
    loadNextArtists(self);
}

fn loadNextArtists(self: *App) void {
    const store = self.loved.artist_store orelse return;
    if (self.loved.artists_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryArtistPage(library, .{
        .loved_only = true,
        .filter = self.loved.filter.value,
        .sort = .recently_loved,
        .limit = app.page_size,
        .offset = self.loved.artists_loaded,
    }) catch {
        self.loved.artists_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.loved.artists_exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (additions.items) |row| gtk.g_object_unref(row);
        additions.deinit(self.allocator);
    }
    var buffer: [96]u8 = undefined;
    for (page.items) |artist| {
        const detail = std.fmt.bufPrint(&buffer, "{d} {s} · {d} {s}", .{
            artist.release_count,
            if (artist.release_count == 1) "album" else "albums",
            artist.track_count,
            if (artist.track_count == 1) "track" else "tracks",
        }) catch "";
        const row = browse_model.newArtist(artist.id, artist.name, detail, .{ .has_photo = artist.has_photo }) orelse continue;
        additions.append(self.allocator, row) catch {
            gtk.g_object_unref(row);
            break;
        };
    }
    appendRows(store, additions.items);
    self.loved.artists_loaded += @intCast(page.items.len);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    track_table.repaint(&self.loved.tracks, changed, change);
}

fn eachPlayable(self: *App, context: anytype, comptime visit: fn (@TypeOf(context), liborca.TrackSummary) bool) void {
    const library = self.library orelse return;
    var offset: u32 = 0;
    var seen: usize = 0;
    while (seen < queue_limit) {
        var page = self.runtime.libraryTrackQuery(library, "", .{
            .loved_only = true,
            .sort = .loved,
            .limit = app.page_size,
            .offset = offset,
        }) catch return;
        defer page.deinit();
        for (page.items) |item| {
            if (seen == queue_limit) return;
            if (!item.has_playable_file) continue;
            seen += 1;
            if (!visit(context, item)) return;
        }
        if (page.items.len < app.page_size) return;
        offset += app.page_size;
    }
}

const IdList = struct {
    app: *App,
    ids: std.ArrayList(i64) = .empty,

    fn add(self: *IdList, item: liborca.TrackSummary) bool {
        self.ids.append(self.app.allocator, item.id) catch return false;
        return true;
    }
};

fn addToContext(self: *App, item: liborca.TrackSummary) bool {
    self.context.addTrack(self.allocator, item.id, item.recording_id, item.feedback) catch return false;
    return true;
}

fn playLoved(self: *App, shuffle: bool) void {
    var list: IdList = .{ .app = self };
    defer list.ids.deinit(self.allocator);
    eachPlayable(self, &list, IdList.add);
    if (list.ids.items.len == 0) return self.toast("No loved track has a playable file");
    self.runtime.playerSetShuffle(self.player, shuffle) catch {};
    transport.playIds(self, list.ids.items, 0);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playLoved(state(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playLoved(state(data), true);
}

fn moreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.context.reset(.tracks);
    eachPlayable(self, self, addToContext);
    if (self.context.tracks.items.len == 0) return self.toast("No loved track has a playable file");
    albums.popupBelow(self, gtk.cast(gtk.Widget, button.?));
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

fn tracksScrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (!self.loved.tracks_exhausted and nearEnd(adjustment)) loadNextTracks(self);
}

fn artistsScrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (!self.loved.artists_exhausted and nearEnd(adjustment)) loadNextArtists(self);
}

fn albumActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.loved.album_store orelse return;
    const id = albums.releaseAt(store, position) orelse return;
    albums.openAlbum(self, self.loved.navigation orelse return, id);
}

fn artistActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.loved.artist_store orelse return;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *BrowseObject = @ptrCast(@alignCast(item));
    artist_page.openArtist(self, self.loved.navigation orelse return, row.id() orelse return);
}

fn emptyPage(slot: *?*adw.StatusPage, title: [*:0]const u8, description: [*:0]const u8) *gtk.Widget {
    const page = adw.adw_status_page_new();
    slot.* = gtk.cast(adw.StatusPage, page);
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

fn bodyFor(slot: *?*gtk.Stack, content: *gtk.Widget, content_name: [*:0]const u8, empty: *gtk.Widget) *gtk.Widget {
    const body = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(body, "loved-body");
    slot.* = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(slot.*.?, content, content_name);
    _ = gtk.gtk_stack_add_named(slot.*.?, empty, "empty");
    return body;
}

fn buildAlbums(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.loved.album_store = store;
    const grid = albums.newGrid(self, store, gtk.callback(albumActivated));
    return bodyFor(
        &self.loved.albums_body,
        scrollerFor(grid, gtk.callback(albumsScrolled), self),
        "grid",
        emptyPage(&self.loved.albums_empty, "No Loved Albums", "Love an album with the heart on its page or from its menu."),
    );
}

fn tileArtist(tile: *gtk.Widget) ?*BrowseObject {
    const item = gtk.g_object_get_data(tile, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    return @ptrCast(@alignCast(object));
}

fn tilePart(tile: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    return gtk.cast(gtk.Widget, gtk.g_object_get_data(tile, key) orelse return null);
}

fn artistMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = menu.gestureWidget(gesture);
    const artist = tileArtist(tile) orelse return;
    if (artists.setArtistContext(self, artist.id() orelse return)) menu.popup(self, tile, x, y);
}

fn tileLabel(class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn setupArtist(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "loved-artist");
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(tile, artist_pixels, -1);
    const photo = art.newCover(self, art.initialsPlaceholder(), artist_pixels);
    gtk.gtk_widget_add_css_class(photo, "loved-artist-photo");
    const name = tileLabel("tile-title");
    const detail = tileLabel("tile-year");
    for ([_]*gtk.Widget{ photo, name, detail }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), part);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    gtk.g_object_set_data(tile, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-photo", photo);
    gtk.g_object_set_data(tile, "orca-name", name);
    gtk.g_object_set_data(tile, "orca-detail", detail);
    menu.onSecondaryClick(tile, artistMenu, self);
}

fn bindArtist(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const artist = tileArtist(tile) orelse return;
    const photo = tilePart(tile, "orca-photo") orelse return;
    const name: [:0]const u8 = if (artist.name().len != 0) artist.name() else "Unknown Artist";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, tilePart(tile, "orca-name") orelse return), name.ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, tilePart(tile, "orca-detail") orelse return), artist.detail().ptr);
    art.setInitials(photo, name);
    const id = artist.id() orelse return art.clear(self, photo);
    art.showArtist(self, photo, id, if (artist.artist().has_photo) .stored else .absent, null, .tile);
}

fn unbindArtist(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    art.forget(state(data), tilePart(tile, "orca-photo") orelse return);
}

fn buildArtists(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.loved.artist_store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupArtist), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindArtist), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindArtist), self);
    const grid = gtk.gtk_grid_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 2);
    gtk.gtk_grid_view_set_tab_behavior(gtk.cast(gtk.GridView, grid), gtk.LIST_TAB_ITEM);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", gtk.callback(artistActivated), self);
    return bodyFor(
        &self.loved.artists_body,
        scrollerFor(grid, gtk.callback(artistsScrolled), self),
        "grid",
        emptyPage(&self.loved.artists_empty, "No Loved Artists", "Love an artist with the heart on their page."),
    );
}

fn setupCover(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cover = art.newCover(state(data), art.iconPlaceholder(cover_pixels), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "row-cover");
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), cover);
}

fn bindCover(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const cover = gtk.gtk_list_item_get_child(list_item) orelse return;
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *track_model.TrackObject = @ptrCast(@alignCast(object));
    const key = if (row.releaseId()) |id| art.Key.release(id, .thumb) else art.Key.track(row.id(), .thumb);
    art.show(state(data), cover, key);
}

fn unbindCover(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    art.forget(state(data), gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return);
}

fn insertCover(self: *App) ?*gtk.ColumnViewColumn {
    const view = self.loved.tracks.view orelse return null;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupCover), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindCover), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindCover), self);
    const cover = gtk.gtk_column_view_column_new("", factory);
    gtk.gtk_column_view_column_set_resizable(cover, gtk.false_);
    gtk.gtk_column_view_column_set_fixed_width(cover, cover_column_width);
    gtk.gtk_column_view_insert_column(view, 1, cover);
    gtk.g_object_unref(cover);
    return cover;
}

fn buildTracks(self: *App) *gtk.Widget {
    const view = track_table.build(&self.loved.tracks, self, .{
        .multiple = false,
        .sortable = false,
        .columns = track_columns,
        .duration_icon = true,
        .relative_dates = true,
        .title_heart = true,
    });
    self.loved.tracks.positions = true;
    for (column_widths) |width| {
        const header = self.loved.tracks.header(width.column) orelse continue;
        gtk.gtk_column_view_column_set_fixed_width(header, width.pixels);
    }
    const cover = insertCover(self);
    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    const scroller = scrollerFor(view, gtk.callback(tracksScrolled), self);
    gtk.gtk_widget_add_css_class(scroller, "loved-tracks");
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), scroller);
    if (cover) |column| hideBelow(bin, "max-width: 620px", &.{column});
    return bodyFor(
        &self.loved.tracks_body,
        bin,
        "list",
        emptyPage(&self.loved.tracks_empty, "No Loved Tracks", "Love a track with the heart in its row."),
    );
}

fn stat(label: [*:0]const u8) struct { widget: *gtk.Widget, number: *gtk.Label } {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(box, "loved-stat");
    const number = gtk.gtk_label_new("0");
    gtk.gtk_widget_add_css_class(number, "loved-stat-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 0);
    const caption = gtk.gtk_label_new(label);
    gtk.gtk_widget_add_css_class(caption, "loved-stat-label");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, caption), 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), number);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), caption);
    return .{ .widget = box, .number = gtk.cast(gtk.Label, number) };
}

fn buildActions(self: *App) *gtk.Widget {
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    self.loved.actions = actions;
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "artist-actions");
    gtk.gtk_widget_add_css_class(actions, "loved-actions");
    const play = albums.pill("Play", "orca-play-symbolic", true);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    const shuffle = albums.pill("Shuffle", "orca-shuffle-symbolic", false);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    for ([_]*gtk.Widget{ play, shuffle, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    return actions;
}

fn buildStats(self: *App) *gtk.Widget {
    const stats = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(stats, "loved-stats");
    self.loved.stats = stats;
    const tracks = stat("Tracks");
    self.loved.track_count = tracks.number;
    const loved_albums = stat("Albums");
    self.loved.album_count = loved_albums.number;
    const loved_artists = stat("Artists");
    self.loved.artist_count = loved_artists.number;
    for ([_]*gtk.Widget{ tracks.widget, loved_albums.widget, loved_artists.widget }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, stats), widget);
    return stats;
}

fn buildHeader(self: *App) *gtk.Widget {
    const title = page_ui.title("Loved");
    gtk.gtk_widget_add_css_class(title.widget, "loved-header");
    gtk.gtk_label_set_text(title.meta, "Everything you\u{2019}ve marked with a heart. Ratings are separate and live alongside.");
    const lead = gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, title.title)).?;
    gtk.gtk_box_append(gtk.cast(gtk.Box, lead), buildActions(self));
    title.add(buildStats(self));
    return title.widget;
}

fn tabToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) == 0) return;
    const index = @intFromPtr(gtk.g_object_get_data(button.?, "orca-tab") orelse return) - 1;
    const tab: Tab = @enumFromInt(index);
    gtk.gtk_stack_set_visible_child_name(self.loved.tabs orelse return, @tagName(tab));
}

fn tabButton(tab: Tab) *gtk.Widget {
    const button = gtk.gtk_toggle_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const icon = gtk.gtk_image_new_from_icon_name(tab_icons.get(tab));
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 16);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(tab_labels.get(tab)));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "loved-tab");
    gtk.gtk_widget_set_focus_on_click(button, gtk.false_);
    return button;
}

fn buildTabs(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, "loved-tabs");
    var group: ?*gtk.ToggleButton = null;
    for (std.enums.values(Tab)) |tab| {
        const button = tabButton(tab);
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        gtk.g_object_set_data(button, "orca-tab", @ptrFromInt(@intFromEnum(tab) + 1));
        _ = gtk.signalConnect(button, "toggled", gtk.callback(tabToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
    }
    if (group) |first| gtk.gtk_toggle_button_set_active(first, gtk.true_);
    return row;
}

fn hideBelow(bin: *gtk.Widget, condition: [*:0]const u8, objects: []const *anyopaque) void {
    const parsed = adw.adw_breakpoint_condition_parse(condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(parsed);
    var hidden: gtk.GValue = .{};
    _ = gtk.g_value_init(&hidden, gtk.G_TYPE_BOOLEAN);
    gtk.g_value_set_boolean(&hidden, gtk.false_);
    for (objects) |object| adw.adw_breakpoint_add_setter(breakpoint, object, "visible", &hidden);
    gtk.g_value_unset(&hidden);
    adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
}

pub fn build(self: *App) *gtk.Widget {
    const pages = gtk.gtk_stack_new();
    self.loved.tabs = gtk.cast(gtk.Stack, pages);
    _ = gtk.gtk_stack_add_named(self.loved.tabs.?, buildTracks(self), @tagName(Tab.tracks));
    _ = gtk.gtk_stack_add_named(self.loved.tabs.?, buildAlbums(self), @tagName(Tab.albums));
    _ = gtk.gtk_stack_add_named(self.loved.tabs.?, buildArtists(self), @tagName(Tab.artists));
    gtk.gtk_widget_set_vexpand(pages, gtk.true_);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "loved-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildHeader(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildTabs(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), pages);

    const navigation = adw.adw_navigation_view_new();
    self.loved.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(column, "Loved");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(self.loved.navigation.?, root);
    return navigation;
}
