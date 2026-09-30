//! The Artists page: every Artist, searchable, and a page for each with their
//! albums.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const albums = @import("albums.zig");
const browse_model = @import("browse_model.zig");
const transport = @import("transport.zig");
const menu = @import("menu.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const avatar_pixels: c_int = 40;
const hero_pixels: c_int = 160;
const tile_pixels: c_int = 160;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(row, "artist-row");
    const avatar = adw.adw_avatar_new(avatar_pixels, null, gtk.true_);
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    const name = gtk.gtk_label_new(null);
    const detail = gtk.gtk_label_new(null);
    for ([_]*gtk.Widget{ name, detail }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
        gtk.gtk_box_append(gtk.cast(gtk.Box, labels), label);
    }
    gtk.gtk_widget_add_css_class(name, "artist-name");
    gtk.gtk_widget_add_css_class(detail, "caption");
    gtk.gtk_widget_add_css_class(detail, "dim-label");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), avatar);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), labels);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, rowMenu, state(data));
}

/// Everything a menu needs to act on an Artist: their playable tracks, album
/// by album.
pub fn setArtistContext(self: *App, artist_id: i64) bool {
    const library = self.library orelse return false;
    self.context.reset(.artist);
    self.context.artist_id = artist_id;
    var tracks = self.runtime.libraryTrackQuery(library, "", .{
        .artist_id = artist_id,
        .sort = .album,
        .limit = app.page_size,
    }) catch return false;
    defer tracks.deinit();
    for (tracks.items) |item| {
        if (item.has_playable_file) self.context.addTrack(self.allocator, item.id, item.recording_id, item.feedback) catch return false;
    }
    return true;
}

fn rowMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const artist: *BrowseObject = @ptrCast(@alignCast(object));
    const id = artist.id() orelse return;
    if (setArtistContext(self, id)) menu.popup(self, row, x, y);
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const artist: *BrowseObject = @ptrCast(@alignCast(object));
    const row = gtk.gtk_list_item_get_child(list_item) orelse return;
    const avatar = gtk.gtk_widget_get_first_child(row) orelse return;
    const labels = gtk.gtk_widget_get_next_sibling(avatar) orelse return;
    const name = gtk.gtk_widget_get_first_child(labels) orelse return;
    const detail = gtk.gtk_widget_get_next_sibling(name) orelse return;
    adw.adw_avatar_set_text(gtk.cast(adw.Avatar, avatar), artist.name().ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, name), if (artist.name().len != 0) artist.name().ptr else "Unknown Artist");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), artist.detail().ptr);
}

pub fn reload(self: *App) void {
    const store = self.artist_list_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.artist_list_loaded = 0;
    self.artist_list_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryArtistCountMatching(library, .{ .filter = self.artist_list_filter.value }) catch 0;
    if (self.artist_list_title) |title| {
        var buffer: [48]u8 = undefined;
        const text: [:0]const u8 = if (total == 1) "1 artist" else strings.printZ(&buffer, "{d} artists", .{total}) catch "";
        adw.adw_window_title_set_subtitle(title, text.ptr);
    }
    loadNextPage(self);
}

fn loadNextPage(self: *App) void {
    const store = self.artist_list_store orelse return;
    if (self.artist_list_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryArtistPage(library, .{
        .filter = self.artist_list_filter.value,
        .limit = app.page_size,
        .offset = self.artist_list_loaded,
    }) catch {
        self.artist_list_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.artist_list_exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    var buffer: [96]u8 = undefined;
    for (page.items) |artist| {
        const detail = std.fmt.bufPrint(&buffer, "{d} {s} · {d} {s}", .{
            artist.release_count,
            if (artist.release_count == 1) "album" else "albums",
            artist.track_count,
            if (artist.track_count == 1) "song" else "songs",
        }) catch "";
        const row = browse_model.new(artist.id, artist.name, detail) orelse continue;
        additions.append(self.allocator, row) catch {
            gtk.g_object_unref(row);
            break;
        };
    }
    if (additions.items.len != 0) {
        gtk.g_list_store_splice(
            store,
            gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
            0,
            additions.items.ptr,
            @intCast(additions.items.len),
        );
        for (additions.items) |row| gtk.g_object_unref(row);
    }
    self.artist_list_loaded += @intCast(page.items.len);
}

fn scrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.artist_list_exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page * 2) loadNextPage(self);
}

fn filterChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const text = gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry));
    self.artist_list_filter.set(self.allocator, std.mem.span(text));
    reload(self);
}

fn rowActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.artist_list_store orelse return;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *BrowseObject = @ptrCast(@alignCast(item));
    const id = row.id() orelse return;
    const navigation = self.artists_navigation orelse return;
    openArtist(self, navigation, id);
}

pub fn build(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.artist_list_store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindRow), self);
    const list = gtk.gtk_list_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(list, "artist-list");
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, list), gtk.true_);
    _ = gtk.signalConnect(list, "activate", gtk.callback(rowActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(scrolled),
        self,
    );

    const header = adw.adw_header_bar_new();
    const title = adw.adw_window_title_new("Artists", "");
    self.artist_list_title = gtk.cast(adw.WindowTitle, title);
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), title);
    const search = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, search), "Search artists");
    gtk.gtk_widget_set_size_request(search, 220, -1);
    self.artist_list_search = search;
    _ = gtk.signalConnect(search, "search-changed", gtk.callback(filterChanged), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), search);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), scroller);

    const navigation = adw.adw_navigation_view_new();
    self.artists_navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Artists");
    adw.adw_navigation_page_set_tag(root, "artists");
    adw.adw_navigation_view_add(self.artists_navigation.?, root);
    return navigation;
}

const ArtistPage = struct {
    self: *App,
    navigation: *adw.NavigationView,
    artist_id: i64,
    tracks: []i64,
    releases: []i64,
};

fn pageData(data: ?*anyopaque) *ArtistPage {
    return @ptrCast(@alignCast(data.?));
}

fn pageDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const allocator = page.self.allocator;
    allocator.free(page.tracks);
    allocator.free(page.releases);
    allocator.destroy(page);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    page.self.runtime.playerSetShuffle(page.self.player, false) catch {};
    transport.playIds(page.self, page.tracks, 0);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    page.self.runtime.playerSetShuffle(page.self.player, true) catch {};
    transport.playIds(page.self, page.tracks, 0);
}

fn albumActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= page.releases.len) return;
    albums.openAlbum(page.self, page.navigation, page.releases[@intCast(index)]);
}

fn heroMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setArtistContext(page.self, page.artist_id)) menu.popup(page.self, menu.gestureWidget(gesture), x, y);
}

fn albumMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const tile = menu.gestureWidget(gesture);
    const child = gtk.gtk_widget_get_parent(tile) orelse return;
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= page.releases.len) return;
    if (albums.setAlbumContext(page.self, page.releases[@intCast(index)])) menu.popup(page.self, tile, x, y);
}

fn albumTile(page: *ArtistPage, release: liborca.ReleaseSummary) *gtk.Widget {
    const self = page.self;
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    const cover = art.newCover(self, art.initialsPlaceholder(), tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release.id, .tile));
    var buffer: [512]u8 = undefined;
    const title = gtk.gtk_label_new(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr);
    const year = if (release.release_date) |date| date[0..@min(date.len, 4)] else "";
    const detail = gtk.gtk_label_new(strings.terminated(&buffer, year).ptr);
    for ([_]*gtk.Widget{ title, detail }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_set_size_request(label, tile_pixels, -1);
    }
    gtk.gtk_widget_add_css_class(title, "tile-title");
    gtk.gtk_widget_add_css_class(detail, "tile-artist");
    gtk.gtk_widget_set_margin_top(title, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), cover);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), detail);
    menu.onSecondaryClick(tile, albumMenu, page);
    return tile;
}

pub fn openArtist(self: *App, navigation: *adw.NavigationView, artist_id: i64) void {
    const library = self.library orelse return;
    const artist = (self.runtime.libraryArtist(library, artist_id) catch null) orelse return;
    defer artist.deinit(self.allocator);
    var releases = self.runtime.libraryReleasePage(library, .{
        .album_artist_id = artist_id,
        .sort = .artist,
        .limit = app.page_size,
    }) catch return;
    defer releases.deinit();
    var tracks = self.runtime.libraryTrackQuery(library, "", .{
        .artist_id = artist_id,
        .sort = .album,
        .limit = app.page_size,
    }) catch return;
    defer tracks.deinit();

    const page = self.allocator.create(ArtistPage) catch return;
    page.* = .{ .self = self, .navigation = navigation, .artist_id = artist_id, .tracks = &.{}, .releases = &.{} };
    page.tracks = self.allocator.alloc(i64, tracks.items.len) catch {
        self.allocator.destroy(page);
        return;
    };
    page.releases = self.allocator.alloc(i64, releases.items.len) catch {
        self.allocator.free(page.tracks);
        self.allocator.destroy(page);
        return;
    };
    var playable: usize = 0;
    for (tracks.items) |item| {
        if (!item.has_playable_file) continue;
        page.tracks[playable] = item.id;
        playable += 1;
    }
    page.tracks = self.allocator.realloc(page.tracks, playable) catch page.tracks[0..playable];
    for (page.releases, releases.items) |*id, release| id.* = release.id;

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 24);
    gtk.gtk_widget_add_css_class(content, "album-page");
    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    var buffer: [512]u8 = undefined;
    var name_buffer: [512]u8 = undefined;
    const name = strings.terminated(&name_buffer, if (artist.name.len != 0) artist.name else "Unknown Artist");
    const avatar = art.newCover(self, adw.adw_avatar_new(hero_pixels, name.ptr, gtk.true_), hero_pixels);
    gtk.gtk_widget_add_css_class(avatar, "artist-hero");
    menu.onSecondaryClick(avatar, heroMenu, page);
    if (releases.items.len != 0) art.show(self, avatar, art.Key.release(releases.items[0].id, .tile));
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), avatar);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    const kind = gtk.gtk_label_new("ARTIST");
    gtk.gtk_widget_add_css_class(kind, "album-kind");
    const title = gtk.gtk_label_new(name.ptr);
    gtk.gtk_widget_add_css_class(title, "album-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    const meta_text: [:0]const u8 = strings.printZ(&buffer, "{d} {s} · {d} {s}", .{
        artist.release_count,
        if (artist.release_count == 1) "album" else "albums",
        artist.track_count,
        if (artist.track_count == 1) "song" else "songs",
    }) catch "";
    const meta = gtk.gtk_label_new(meta_text.ptr);
    gtk.gtk_widget_add_css_class(meta, "album-meta");
    for ([_]*gtk.Widget{ kind, title, meta }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), label);
    }
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_margin_top(actions, 10);
    const play = albums.pill("Play", "media-playback-start-symbolic", true);
    const shuffle = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), play);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), shuffle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), hero);

    if (releases.items.len != 0) {
        const heading = gtk.gtk_label_new("Albums");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0.0);
        gtk.gtk_widget_add_css_class(heading, "section-heading");
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), heading);
        const flow = gtk.gtk_flow_box_new();
        const box = gtk.cast(gtk.FlowBox, flow);
        gtk.gtk_flow_box_set_selection_mode(box, gtk.SELECTION_NONE);
        gtk.gtk_flow_box_set_homogeneous(box, gtk.true_);
        gtk.gtk_flow_box_set_min_children_per_line(box, 2);
        gtk.gtk_flow_box_set_max_children_per_line(box, 8);
        gtk.gtk_flow_box_set_column_spacing(box, 8);
        gtk.gtk_flow_box_set_row_spacing(box, 8);
        gtk.gtk_flow_box_set_activate_on_single_click(box, gtk.true_);
        gtk.gtk_widget_add_css_class(flow, "artist-albums");
        _ = gtk.signalConnect(flow, "child-activated", gtk.callback(albumActivated), page);
        for (releases.items) |release| gtk.gtk_flow_box_append(box, albumTile(page, release));
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), flow);
    }

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 1100);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), clamp);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), adw.adw_header_bar_new());
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), scroller);
    adw.adw_navigation_view_push(navigation, adw.adw_navigation_page_new(view, name.ptr));
}
