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
const mosaic_pixels: c_int = 200;
const artist_pixels: c_int = 148;
const cover_pixels: c_int = 24;
const cover_column_width: c_int = 40;
const track_columns = track_table.ColumnSet.initMany(&.{ .number, .title, .artist, .album, .duration, .loved, .rating, .last_played, .more });
const mosaic_keys = [_][*:0]const u8{ "orca-cover-0", "orca-cover-1", "orca-cover-2", "orca-cover-3" };

pub const navigation_tag = "loved";

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    album_store: ?*gtk.ListStore = null,
    albums_loaded: u32 = 0,
    albums_exhausted: bool = false,
    albums_body: ?*gtk.Stack = null,
    tracks: track_table.Table = .{},
    tracks_loaded: u32 = 0,
    tracks_exhausted: bool = false,
    tracks_body: ?*gtk.Stack = null,
    artist_store: ?*gtk.ListStore = null,
    artists_loaded: u32 = 0,
    artists_exhausted: bool = false,
    artists_body: ?*gtk.Stack = null,
    stats: ?*gtk.Widget = null,
    mosaic: ?*gtk.Widget = null,
    track_count: ?*gtk.Label = null,
    album_count: ?*gtk.Label = null,
    artist_count: ?*gtk.Label = null,
    actions: ?*gtk.Widget = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

pub fn reload(self: *App) void {
    reloadAlbums(self);
    reloadTracks(self);
    reloadArtists(self);
    showMosaic(self);
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
    showMosaic(self);
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

fn reloadTracks(self: *App) void {
    const store = self.loved.tracks.store orelse return;
    gtk.g_list_store_remove_all(store);
    self.loved.tracks_loaded = 0;
    self.loved.tracks_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryTrackMatchCount(library, .{ .loved_only = true }) catch 0;
    showCount(self.loved.track_count, total);
    if (self.loved.actions) |actions| gtk.gtk_widget_set_sensitive(actions, if (total == 0) gtk.false_ else gtk.true_);
    if (self.loved.tracks_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");
    loadNextTracks(self);
}

fn loadNextTracks(self: *App) void {
    const store = self.loved.tracks.store orelse return;
    if (self.loved.tracks_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryTrackQuery(library, "", .{
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
    const total = self.runtime.libraryArtistCountMatching(library, .{ .loved_only = true }) catch 0;
    showCount(self.loved.artist_count, total);
    if (self.loved.artists_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "grid");
    loadNextArtists(self);
}

fn loadNextArtists(self: *App) void {
    const store = self.loved.artist_store orelse return;
    if (self.loved.artists_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryArtistPage(library, .{
        .loved_only = true,
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

fn mosaicPart(mosaic: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    return gtk.cast(gtk.Widget, gtk.g_object_get_data(mosaic, key) orelse return null);
}

fn addCover(covers: *std.ArrayList(i64), release_id: ?i64) void {
    const id = release_id orelse return;
    if (covers.items.len == covers.capacity) return;
    for (covers.items) |present| if (present == id) return;
    covers.appendAssumeCapacity(id);
}

fn showMosaic(self: *App) void {
    const mosaic = self.loved.mosaic orelse return;
    var storage: [mosaic_keys.len]i64 = undefined;
    var covers: std.ArrayList(i64) = .initBuffer(&storage);
    if (self.library) |library| {
        if (self.runtime.libraryReleasePage(library, .{ .loved_only = true, .sort = .loved, .limit = mosaic_keys.len })) |page| {
            var releases = page;
            defer releases.deinit();
            for (releases.items) |release| addCover(&covers, release.id);
        } else |_| {}
        if (covers.items.len < storage.len) {
            if (self.runtime.libraryTrackQuery(library, "", .{ .loved_only = true, .sort = .loved, .limit = app.page_size })) |page| {
                var tracks = page;
                defer tracks.deinit();
                for (tracks.items) |track| addCover(&covers, track.release_id);
            } else |_| {}
        }
    }
    gtk.gtk_widget_set_visible(mosaic, if (covers.items.len == 0) gtk.false_ else gtk.true_);
    const tiled = covers.items.len == mosaic_keys.len;
    const single = mosaicPart(mosaic, "orca-single") orelse return;
    if (tiled or covers.items.len == 0) art.clear(self, single) else art.show(self, single, art.Key.release(covers.items[0], .tile));
    for (mosaic_keys, 0..) |key, index| {
        const cell = mosaicPart(mosaic, key) orelse continue;
        if (tiled) art.show(self, cell, art.Key.release(covers.items[index], .tile)) else art.clear(self, cell);
    }
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, mosaic), if (tiled) "grid" else "single");
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
    artists.openArtist(self, self.loved.navigation orelse return, row.id() orelse return);
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

fn bodyFor(slot: *?*gtk.Stack, content: *gtk.Widget, content_name: [*:0]const u8, empty: *gtk.Widget) *gtk.Widget {
    const body = gtk.gtk_stack_new();
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
        emptyPage("No Loved Albums", "Love an album with the heart on its page or from its menu."),
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
        emptyPage("No Loved Artists", "Love an artist with the heart on their page."),
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

fn arrangeColumns(self: *App) ?*gtk.ColumnViewColumn {
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
    const duration = self.loved.tracks.header(.duration) orelse return cover;
    const loved = self.loved.tracks.header(.loved) orelse return cover;
    const columns = gtk.gtk_column_view_get_columns(view);
    var index: c_uint = 0;
    while (gtk.g_list_model_get_item(columns, index)) |column| : (index += 1) {
        gtk.g_object_unref(column);
        if (column == @as(*anyopaque, loved)) break;
    }
    gtk.gtk_column_view_insert_column(view, index, duration);
    return cover;
}

fn buildTracks(self: *App) *gtk.Widget {
    const view = track_table.build(&self.loved.tracks, self, .{
        .multiple = false,
        .sortable = false,
        .columns = track_columns,
        .duration_icon = true,
        .relative_dates = true,
    });
    self.loved.tracks.positions = true;
    gtk.gtk_widget_add_css_class(view, "loved-tracks");
    const cover = arrangeColumns(self);
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
        emptyPage("No Loved Tracks", "Love a track with the heart in its row."),
    );
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

fn heroLabel(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(label, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    return label;
}

fn mosaicPlaceholder(pixels: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(feedback.filled_icon);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), @divTrunc(pixels, 3));
    gtk.gtk_widget_add_css_class(icon, "loved-heart");
    return icon;
}

fn newMosaic(self: *App) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(stack, "loved-mosaic");
    gtk.gtk_widget_set_overflow(stack, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_valign(stack, gtk.ALIGN_CENTER);
    const single = art.newCover(self, mosaicPlaceholder(mosaic_pixels), mosaic_pixels);
    gtk.gtk_widget_add_css_class(single, "mosaic-cell");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), single, "single");
    gtk.g_object_set_data(stack, "orca-single", single);
    const half = @divTrunc(mosaic_pixels, 2);
    const grid = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for (0..2) |row_index| {
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        for (0..2) |column| {
            const cell = art.newCover(self, mosaicPlaceholder(half), half);
            gtk.gtk_widget_add_css_class(cell, "mosaic-cell");
            gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            gtk.g_object_set_data(stack, mosaic_keys[row_index * 2 + column], cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
    }
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), grid, "grid");
    return stack;
}

fn buildHero(self: *App) *gtk.Widget {
    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(hero, "loved-hero");

    const lead = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_valign(lead, gtk.ALIGN_CENTER);
    const name = gtk.gtk_label_new("Loved");
    gtk.gtk_widget_add_css_class(name, "loved-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    const tagline = heroLabel("The music you love, all in one place.", "loved-tagline");
    const description = heroLabel(
        "Tracks, albums, and artists you\u{2019}ve liked, collected and come back to. A reflection of what moves you.",
        "loved-description",
    );
    const description_clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, description_clamp), 600);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, description_clamp), 600);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, description_clamp), description);
    gtk.gtk_widget_set_halign(description_clamp, gtk.ALIGN_START);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    self.loved.actions = actions;
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "loved-actions");
    const play = albums.pill("Play", "media-playback-start-symbolic", true);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    const shuffle = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "circular");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    for ([_]*gtk.Widget{ play, shuffle, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    for ([_]*gtk.Widget{ name, tagline, description_clamp, actions }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, lead), part);

    const aside = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    self.loved.stats = aside;
    gtk.gtk_widget_set_valign(aside, gtk.ALIGN_CENTER);
    const mosaic = newMosaic(self);
    self.loved.mosaic = mosaic;
    const stats = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_add_css_class(stats, "loved-stats");
    gtk.gtk_widget_set_valign(stats, gtk.ALIGN_CENTER);
    const tracks = stat("LOVED TRACKS");
    self.loved.track_count = tracks.number;
    const loved_albums = stat("LOVED ALBUMS");
    self.loved.album_count = loved_albums.number;
    const loved_artists = stat("LOVED ARTISTS");
    self.loved.artist_count = loved_artists.number;
    for ([_]*gtk.Widget{ tracks.widget, loved_albums.widget, loved_artists.widget }) |widget| {
        var child = gtk.gtk_widget_get_first_child(widget);
        while (child) |label| : (child = gtk.gtk_widget_get_next_sibling(label)) gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, stats), widget);
    }
    const mosaic_slot = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, mosaic_slot), mosaic);
    gtk.gtk_box_append(gtk.cast(gtk.Box, aside), mosaic_slot);
    gtk.gtk_box_append(gtk.cast(gtk.Box, aside), stats);

    gtk.gtk_widget_set_halign(aside, gtk.ALIGN_END);

    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    gtk.gtk_widget_set_hexpand(bin, gtk.true_);
    gtk.gtk_widget_set_valign(bin, gtk.ALIGN_CENTER);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), aside);
    hideBelow(bin, "max-width: 340px", &.{mosaic_slot});
    hideBelow(bin, "max-width: 110px", &.{ mosaic_slot, stats });

    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), lead);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), bin);
    return hero;
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
    const views = adw.adw_view_stack_new();
    const stack = gtk.cast(adw.ViewStack, views);
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildTracks(self), "tracks", "Loved Tracks", "audio-x-generic-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildAlbums(self), "albums", "Loved Albums", "media-optical-symbolic");
    _ = adw.adw_view_stack_add_titled_with_icon(stack, buildArtists(self), "artists", "Loved Artists", "avatar-default-symbolic");
    gtk.gtk_widget_set_vexpand(views, gtk.true_);

    const switcher = adw.adw_view_switcher_new();
    adw.adw_view_switcher_set_stack(gtk.cast(adw.ViewSwitcher, switcher), stack);
    adw.adw_view_switcher_set_policy(gtk.cast(adw.ViewSwitcher, switcher), adw.VIEW_SWITCHER_POLICY_WIDE);
    gtk.gtk_widget_add_css_class(switcher, "underline-tabs");
    gtk.gtk_widget_set_halign(switcher, gtk.ALIGN_START);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildHero(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), switcher);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), views);

    const navigation = adw.adw_navigation_view_new();
    self.loved.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(column, "Loved");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(self.loved.navigation.?, root);
    return navigation;
}
