//! The Artists page: every Artist, searchable, and a page for each with their
//! best-rated songs and their albums.

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
const page_ui = @import("page.zig");
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const loved = @import("loved.zig");
const track_model = @import("track_model.zig");
const browse = @import("browse.zig");
const window = @import("window.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const thumb_pixels: c_int = 40;
const hero_pixels: c_int = 240;
const tile_pixels: c_int = 148;
const song_thumb_pixels: c_int = 40;
const top_song_limit = 5;
const queue_limit = 10_000;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(row, "artist-row");
    const thumb = art.newCover(self, art.initialsPlaceholder(), thumb_pixels);
    gtk.gtk_widget_add_css_class(thumb, "artist-thumb");
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
    gtk.gtk_widget_add_css_class(detail, "meta");
    gtk.gtk_widget_add_css_class(detail, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), thumb);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), labels);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, rowMenu, self);
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

fn firstRelease(self: *App, artist_id: i64) ?i64 {
    const library = self.library orelse return null;
    var page = self.runtime.libraryReleasePage(library, .{
        .album_artist_id = artist_id,
        .sort = .artist,
        .limit = 1,
    }) catch return null;
    defer page.deinit();
    if (page.items.len == 0) return null;
    return page.items[0].id;
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const artist: *BrowseObject = @ptrCast(@alignCast(object));
    const row = gtk.gtk_list_item_get_child(list_item) orelse return;
    const thumb = gtk.gtk_widget_get_first_child(row) orelse return;
    const labels = gtk.gtk_widget_get_next_sibling(thumb) orelse return;
    const name = gtk.gtk_widget_get_first_child(labels) orelse return;
    const detail = gtk.gtk_widget_get_next_sibling(name) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, name), if (artist.name().len != 0) artist.name().ptr else "Unknown Artist");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), artist.detail().ptr);
    art.setInitials(thumb, artist.name());
    const release = if (artist.id()) |id| firstRelease(self, id) else null;
    if (release) |id| art.show(self, thumb, art.Key.release(id, .thumb)) else art.clear(self, thumb);
}

fn unbindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const thumb = gtk.gtk_widget_get_first_child(row) orelse return;
    art.forget(state(data), thumb);
}

pub fn reload(self: *App) void {
    const store = self.artist_list_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.artist_list_loaded = 0;
    self.artist_list_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryArtistCountMatching(library, .{ .filter = self.artist_list_filter.value }) catch 0;
    if (self.artist_list_meta) |meta| {
        var buffer: [48]u8 = undefined;
        const text: [:0]const u8 = if (total == 1) "1 artist" else strings.printZ(&buffer, "{d} artists", .{total}) catch "";
        gtk.gtk_label_set_text(meta, text.ptr);
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
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindRow), self);
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

    const header = page_ui.header();
    const title = page_ui.title("Artists");
    self.artist_list_meta = title.meta;
    const search = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, search), "Search artists");
    gtk.gtk_widget_set_size_request(search, 220, -1);
    self.artist_list_search = search;
    _ = gtk.signalConnect(search, "search-changed", gtk.callback(filterChanged), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), search);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), page_ui.withTitle(title, scroller));

    const navigation = adw.adw_navigation_view_new();
    self.artists_navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Artists");
    adw.adw_navigation_page_set_tag(root, "artists");
    adw.adw_navigation_view_add(self.artists_navigation.?, root);
    return navigation;
}

const Song = struct {
    target: feedback.Target,
    release_id: ?i64,
    artist_id: ?i64,
    row: ?*gtk.Widget = null,
    heart: ?*gtk.Widget = null,
};

pub const ArtistPage = struct {
    self: *App,
    navigation: *adw.NavigationView,
    artist_id: i64,
    name: [:0]u8,
    tracks: []i64,
    releases: []i64,
    songs: [top_song_limit]Song = undefined,
    song_ids: [top_song_limit]i64 = undefined,
    song_count: usize = 0,
    hero: ?*gtk.Widget = null,
    stats: ?*gtk.Widget = null,
    sections: ?*gtk.Widget = null,
    song_list: ?*gtk.Widget = null,
    details: ?*details.Panel = null,
};

fn pageData(data: ?*anyopaque) *ArtistPage {
    return @ptrCast(@alignCast(data.?));
}

fn pageDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const allocator = page.self.allocator;
    unregisterPage(page);
    allocator.free(page.name);
    allocator.free(page.tracks);
    allocator.free(page.releases);
    allocator.destroy(page);
}

fn registerPage(page: *ArtistPage) void {
    const self = page.self;
    if (self.open_artist_page_count == self.open_artist_pages.len) return;
    self.open_artist_pages[self.open_artist_page_count] = page;
    self.open_artist_page_count += 1;
}

fn unregisterPage(page: *ArtistPage) void {
    const self = page.self;
    for (self.open_artist_pages[0..self.open_artist_page_count], 0..) |open, index| {
        if (open != page) continue;
        self.open_artist_page_count -= 1;
        self.open_artist_pages[index] = self.open_artist_pages[self.open_artist_page_count];
        return;
    }
}

fn layOut(page: *ArtistPage) void {
    const narrow = page.self.window_narrow;
    const orientation: c_int = if (narrow) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL;
    if (page.hero) |hero| gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, hero), orientation);
    if (page.stats) |stats| gtk.gtk_widget_set_visible(stats, if (narrow) gtk.false_ else gtk.true_);
    if (page.sections) |sections| {
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, sections), orientation);
        gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, sections), if (narrow) gtk.false_ else gtk.true_);
    }
}

pub fn setNarrow(self: *App) void {
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| layOut(page);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const value = switch (change) {
        .feedback => |value| value,
        .rating => return,
    };
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        for (page.songs[0..page.song_count]) |*song| {
            const recording = song.target.recording_id orelse continue;
            if (!changed.contains(recording)) continue;
            song.target.feedback = value;
            if (song.heart) |heart| feedback.showRowButton(heart, value);
        }
    }
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        for (page.songs[0..page.song_count]) |song| {
            const row = song.row orelse continue;
            if (track_id == song.target.track_id)
                gtk.gtk_widget_add_css_class(row, "now-playing")
            else
                gtk.gtk_widget_remove_css_class(row, "now-playing");
        }
    }
}

fn play(page: *ArtistPage, shuffle: bool) void {
    if (page.tracks.len == 0) return page.self.toast("No song of theirs has a playable file");
    page.self.runtime.playerSetShuffle(page.self.player, shuffle) catch {};
    transport.playIds(page.self, page.tracks, 0);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    play(pageData(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    play(pageData(data), true);
}

fn heroMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setArtistContext(page.self, page.artist_id)) menu.popup(page.self, menu.gestureWidget(gesture), x, y);
}

fn heroMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setArtistContext(page.self, page.artist_id)) albums.popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn seeAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const self = page.self;
    browse.scopeToArtist(self, page.artist_id, page.name);
    window.showPage(self, .tracks);
    if (!self.window_narrow) if (self.browse_toggle) |toggle|
        gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle), gtk.true_);
}

fn marked(widget: ?*anyopaque) ?usize {
    const position = @intFromPtr(gtk.g_object_get_data(widget.?, "orca-position"));
    if (position == 0) return null;
    return position - 1;
}

fn markPosition(widget: *gtk.Widget, position: usize) void {
    gtk.g_object_set_data(widget, "orca-position", @ptrFromInt(position + 1));
}

fn albumActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= page.releases.len) return;
    albums.openAlbum(page.self, page.navigation, page.releases[@intCast(index)]);
}

fn albumMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const tile = menu.gestureWidget(gesture);
    const index = marked(tile) orelse return;
    if (index >= page.releases.len) return;
    if (albums.setAlbumContext(page.self, page.releases[index])) menu.popup(page.self, tile, x, y);
}

fn albumPlayClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = marked(button) orelse return;
    if (index >= page.releases.len) return;
    albums.playRelease(page.self, page.releases[index]);
}

fn albumMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = marked(button) orelse return;
    if (index >= page.releases.len) return;
    if (albums.setAlbumContext(page.self, page.releases[index])) albums.popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn tileLabel(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn albumTile(page: *ArtistPage, release: liborca.ReleaseSummary, position: usize) *gtk.Widget {
    const self = page.self;
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_set_size_request(tile, tile_pixels, -1);
    markPosition(tile, position);

    const cover = art.newCover(self, art.initialsPlaceholder(), tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release.id, .tile));
    const play_button = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    for ([_][*:0]const u8{ "tile-play", "tile-action", "circular" }) |class| gtk.gtk_widget_add_css_class(play_button, class);
    gtk.gtk_widget_set_halign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(play_button, "Play Album");
    markPosition(play_button, position);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(albumPlayClicked), page);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "album-cover-frame");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), play_button);

    var buffer: [512]u8 = undefined;
    const title = tileLabel(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr, "tile-title");
    const year = tileLabel(strings.terminated(&buffer, releaseYear(release)).ptr, "tile-year");
    gtk.gtk_widget_add_css_class(year, "numeric");
    gtk.gtk_widget_set_hexpand(year, gtk.true_);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    for ([_][*:0]const u8{ "flat", "tile-more", "tile-action" }) |class| gtk.gtk_widget_add_css_class(more, class);
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    markPosition(more, position);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(albumMoreClicked), page);
    const byline = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, byline), year);
    gtk.gtk_box_append(gtk.cast(gtk.Box, byline), more);

    for ([_]*gtk.Widget{ frame, title, byline }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), part);
    menu.onSecondaryClick(tile, albumMenu, page);
    return tile;
}

fn releaseYear(release: liborca.ReleaseSummary) []const u8 {
    const date = release.release_date orelse return "";
    return date[0..@min(date.len, 4)];
}

fn rowPosition(row: *gtk.Widget) ?usize {
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0) return null;
    return @intCast(index);
}

fn setSongContext(page: *ArtistPage, position: usize) bool {
    if (position >= page.song_count) return false;
    const self = page.self;
    const song = page.songs[position];
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, song.target.track_id, song.target.recording_id, song.target.feedback) catch return false;
    self.context.release_id = song.release_id;
    self.context.artist_id = song.artist_id orelse page.artist_id;
    return true;
}

fn songMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const row = menu.gestureWidget(gesture);
    const position = rowPosition(row) orelse return;
    if (setSongContext(page, position)) menu.popup(page.self, row, x, y);
}

fn songMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const position = marked(button) orelse return;
    if (setSongContext(page, position)) albums.popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn songHeartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const position = marked(button) orelse return;
    if (position >= page.song_count) return;
    feedback.toggle(page.self, page.songs[position].target);
}

fn songSelected(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const selected = row orelse return;
    const page = pageData(data);
    const position = rowPosition(gtk.cast(gtk.Widget, selected)) orelse return;
    if (position >= page.song_count) return;
    if (page.details) |panel| details.choose(panel, page.song_ids[position]);
}

fn songActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const position = rowPosition(gtk.cast(gtk.Widget, row)) orelse return;
    if (position >= page.song_count) return;
    const id = page.song_ids[position];
    page.self.runtime.playerSetShuffle(page.self.player, false) catch {};
    const start = std.mem.indexOfScalar(i64, page.tracks, id) orelse return transport.playIds(page.self, &.{id}, 0);
    transport.playIds(page.self, page.tracks, @intCast(start));
}

fn songRow(page: *ArtistPage, summary: liborca.TrackSummary, position: usize) *gtk.Widget {
    const self = page.self;
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "album-track-row");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "artist-song");

    const thumb = art.newCover(self, art.iconPlaceholder(song_thumb_pixels), song_thumb_pixels);
    gtk.gtk_widget_add_css_class(thumb, "artist-song-cover");
    art.show(self, thumb, if (summary.release_id) |release| art.Key.release(release, .thumb) else art.Key.track(summary.id, .thumb));

    var buffer: [512]u8 = undefined;
    const title = gtk.gtk_label_new(strings.terminated(&buffer, if (summary.title.len != 0) summary.title else "Untitled").ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_widget_add_css_class(title, "album-track-title");

    const heart = feedback.newRowButton(gtk.callback(songHeartClicked), page);
    feedback.showRowButton(heart, summary.feedback);
    markPosition(heart, position);

    const duration: [:0]const u8 = if (summary.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else "")
    else
        "";
    const duration_label = gtk.gtk_label_new(duration.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration_label), 1.0);
    gtk.gtk_widget_set_size_request(duration_label, 44, -1);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "dim-label");

    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    markPosition(more, position);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(songMoreClicked), page);

    for ([_]*gtk.Widget{ thumb, title, heart, duration_label, more }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, box), part);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) gtk.gtk_widget_set_sensitive(row, gtk.false_);
    menu.onSecondaryClick(row, songMenu, page);
    page.songs[position] = .{
        .target = .{ .track_id = summary.id, .recording_id = summary.recording_id, .feedback = summary.feedback },
        .release_id = summary.release_id,
        .artist_id = summary.artist_id,
        .row = row,
        .heart = heart,
    };
    page.song_ids[position] = summary.id;
    return row;
}

fn sectionTitle(text: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_widget_set_hexpand(label, gtk.true_);
    gtk.gtk_widget_add_css_class(label, "section-title");
    return label;
}

fn songsSection(page: *ArtistPage, top: []const liborca.TrackSummary) *gtk.Widget {
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(section, "artist-section");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "artist-section-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), sectionTitle("Songs"));
    const see_all = gtk.gtk_button_new_with_label("See All");
    gtk.gtk_widget_add_css_class(see_all, "flat");
    gtk.gtk_widget_add_css_class(see_all, "see-all");
    gtk.gtk_widget_set_valign(see_all, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(see_all, "Show their songs in Songs");
    _ = gtk.signalConnect(see_all, "clicked", gtk.callback(seeAllClicked), page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), see_all);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), heading);

    const list = gtk.gtk_list_box_new();
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_SINGLE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.false_);
    gtk.gtk_widget_add_css_class(list, "album-tracks");
    gtk.gtk_widget_add_css_class(list, "artist-songs");
    _ = gtk.signalConnect(list, "row-selected", gtk.callback(songSelected), page);
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(songActivated), page);
    for (top, 0..) |summary, position| gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list), songRow(page, summary, position));
    page.song_count = top.len;
    page.song_list = list;
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), list);
    return section;
}

fn albumsSection(page: *ArtistPage, releases: []const liborca.ReleaseSummary) *gtk.Widget {
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(section, "artist-section");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "artist-section-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), sectionTitle("Albums"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), heading);

    const flow = gtk.gtk_flow_box_new();
    const box = gtk.cast(gtk.FlowBox, flow);
    gtk.gtk_flow_box_set_selection_mode(box, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_min_children_per_line(box, 1);
    gtk.gtk_flow_box_set_max_children_per_line(box, 8);
    gtk.gtk_flow_box_set_column_spacing(box, 4);
    gtk.gtk_flow_box_set_row_spacing(box, 4);
    gtk.gtk_flow_box_set_activate_on_single_click(box, gtk.true_);
    gtk.gtk_widget_set_halign(flow, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(flow, "artist-albums");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(albumActivated), page);
    for (releases, 0..) |release, position| gtk.gtk_flow_box_append(box, albumTile(page, release, position));
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), flow);
    return section;
}

const Totals = struct {
    tracks: std.ArrayList(i64) = .empty,
    duration_ms: u64 = 0,
};

fn artistTotals(self: *App, library: liborca.LibraryHandle, artist_id: i64) Totals {
    var totals: Totals = .{};
    var offset: u32 = 0;
    while (true) {
        var page = self.runtime.libraryTrackQuery(library, "", .{
            .artist_id = artist_id,
            .sort = .album,
            .limit = app.page_size,
            .offset = offset,
        }) catch break;
        defer page.deinit();
        for (page.items) |item| {
            if (item.duration_ms) |ms| totals.duration_ms += @intCast(@max(ms, 0));
            if (!item.has_playable_file or totals.tracks.items.len == queue_limit) continue;
            totals.tracks.append(self.allocator, item.id) catch {};
        }
        if (page.items.len < app.page_size) break;
        offset += app.page_size;
    }
    return totals;
}

fn setNumber(label: *gtk.Label, buffer: []u8, value: anytype) void {
    const text: [:0]const u8 = strings.printZ(buffer, "{d}", .{value}) catch "";
    gtk.gtk_label_set_text(label, text.ptr);
}

fn statColumn(artist: liborca.ArtistSummary, duration_ms: u64) *gtk.Widget {
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(column, "loved-stats");
    gtk.gtk_widget_add_css_class(column, "artist-stats");
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_END);
    var buffer: [32]u8 = undefined;

    const album_stat = loved.stat(if (artist.release_count == 1) "ALBUM" else "ALBUMS");
    setNumber(album_stat.number, &buffer, artist.release_count);
    const song_stat = loved.stat(if (artist.track_count == 1) "SONG" else "SONGS");
    setNumber(song_stat.number, &buffer, artist.track_count);

    const minutes = (duration_ms + 30_000) / 60_000;
    const time_stat = loved.stat(if (minutes >= 60) "HRS IN YOUR LIBRARY" else "MIN IN YOUR LIBRARY");
    const time: [:0]const u8 = if (minutes >= 60)
        strings.printZ(&buffer, "{d:.1}", .{@as(f64, @floatFromInt(duration_ms)) / 3_600_000.0}) catch ""
    else
        strings.printZ(&buffer, "{d}", .{minutes}) catch "";
    gtk.gtk_label_set_text(time_stat.number, time.ptr);

    for ([_]*gtk.Widget{ album_stat.widget, song_stat.widget, time_stat.widget }) |stat| gtk.gtk_box_append(gtk.cast(gtk.Box, column), stat);
    return column;
}

fn yearsActive(buffer: []u8, releases: []const liborca.ReleaseSummary) [:0]const u8 {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    for (releases) |release| {
        const year = releaseYear(release);
        if (year.len == 0) continue;
        if (first == null or std.mem.order(u8, year, first.?) == .lt) first = year;
        if (last == null or std.mem.order(u8, year, last.?) == .gt) last = year;
    }
    const from = first orelse return "";
    const to = last.?;
    if (std.mem.eql(u8, from, to)) return strings.printZ(buffer, "{s}", .{from}) catch "";
    return strings.printZ(buffer, "{s} – {s}", .{ from, to }) catch "";
}

pub fn openArtist(self: *App, navigation: *adw.NavigationView, artist_id: i64) void {
    const library = self.library orelse return;
    const artist = (self.runtime.libraryArtist(library, artist_id) catch null) orelse return;
    defer artist.deinit(self.allocator);
    var releases = self.runtime.libraryReleasePage(library, .{
        .album_artist_id = artist_id,
        .sort = .year,
        .limit = app.page_size,
    }) catch return;
    defer releases.deinit();
    var top = self.runtime.libraryTrackQuery(library, "", .{
        .artist_id = artist_id,
        .sort = .rating,
        .direction = .descending,
        .limit = top_song_limit,
    }) catch return;
    defer top.deinit();
    var totals = artistTotals(self, library, artist_id);
    defer totals.tracks.deinit(self.allocator);

    const page = self.allocator.create(ArtistPage) catch return;
    page.* = .{
        .self = self,
        .navigation = navigation,
        .artist_id = artist_id,
        .name = undefined,
        .tracks = &.{},
        .releases = &.{},
    };
    page.name = self.allocator.dupeSentinel(u8, if (artist.name.len != 0) artist.name else "Unknown Artist", 0) catch {
        self.allocator.destroy(page);
        return;
    };
    page.tracks = totals.tracks.toOwnedSlice(self.allocator) catch {
        self.allocator.free(page.name);
        self.allocator.destroy(page);
        return;
    };
    page.releases = self.allocator.alloc(i64, releases.items.len) catch {
        self.allocator.free(page.name);
        self.allocator.free(page.tracks);
        self.allocator.destroy(page);
        return;
    };
    for (page.releases, releases.items) |*id, release| id.* = release.id;

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 36);
    gtk.gtk_widget_add_css_class(content, "album-page");
    gtk.gtk_widget_add_css_class(content, "album-detail");
    gtk.gtk_widget_add_css_class(content, "artist-page");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(hero, "album-hero");
    page.hero = hero;
    const cover = art.newCover(self, art.initialsPlaceholder(), hero_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    gtk.gtk_widget_add_css_class(cover, "hero-cover");
    gtk.gtk_widget_set_halign(cover, gtk.ALIGN_START);
    art.setInitials(cover, page.name);
    if (releases.items.len != 0) art.show(self, cover, art.Key.release(releases.items[0].id, .tile));
    menu.onSecondaryClick(cover, heroMenu, page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), cover);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const kind = gtk.gtk_label_new("ARTIST");
    gtk.gtk_widget_add_css_class(kind, "album-kind");
    const title = gtk.gtk_label_new(page.name.ptr);
    gtk.gtk_widget_add_css_class(title, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    menu.onSecondaryClick(title, heroMenu, page);
    for ([_]*gtk.Widget{ kind, title }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), label);
    }
    var buffer: [64]u8 = undefined;
    const years = yearsActive(&buffer, releases.items);
    if (years.len != 0) {
        const meta = gtk.gtk_label_new(years.ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0.0);
        gtk.gtk_widget_add_css_class(meta, "meta");
        gtk.gtk_widget_add_css_class(meta, "numeric");
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), meta);
    }
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    const play_button = albums.pill("Play", "media-playback-start-symbolic", true);
    const shuffle = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(heroMoreClicked), page);
    for ([_]*gtk.Widget{ play_button, shuffle, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    const stat_column = statColumn(artist, totals.duration_ms);
    page.stats = stat_column;
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), stat_column);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), hero);

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 40);
    gtk.gtk_widget_add_css_class(sections, "artist-sections");
    page.sections = sections;
    if (top.items.len != 0) gtk.gtk_box_append(gtk.cast(gtk.Box, sections), songsSection(page, top.items));
    if (releases.items.len != 0) gtk.gtk_box_append(gtk.cast(gtk.Box, sections), albumsSection(page, releases.items));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), sections);
    layOut(page);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 1200);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), albums.newBackdrop(cover));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), clamp);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), clamp, gtk.true_);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), layers);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);
    registerPage(page);
    markPlaying(self, self.shown_track_id);

    const header = page_ui.pushedHeader(navigation, page.name.ptr);
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    const beside = details.besideContent(self, header, scroller, .{ .ids = page.song_ids[0..page.song_count] });
    page.details = beside.panel;
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), beside.widget);
    adw.adw_navigation_view_push(navigation, adw.adw_navigation_page_new(view, page.name.ptr));
    _ = gtk.gtk_widget_grab_focus(play_button);
}
