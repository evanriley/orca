//! The Albums page: a grid of covers, and a page for each album.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const browse_model = @import("browse_model.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const details = @import("details.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const ratings = @import("ratings.zig");
const artists = @import("artists.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const tile_pixels: c_int = 180;
const hero_pixels: c_int = 220;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.ReleaseSort }{
    .{ .label = "Artist", .sort = .artist },
    .{ .label = "Title", .sort = .title },
    .{ .label = "Year", .sort = .year },
    .{ .label = "Recently Added", .sort = .recently_added },
};

fn setupTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    const cover = art.newCover(self, art.initialsPlaceholder(), tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    const title = gtk.gtk_label_new(null);
    const artist = gtk.gtk_label_new(null);
    for ([_]*gtk.Widget{ title, artist }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_set_size_request(label, tile_pixels, -1);
    }
    gtk.gtk_widget_add_css_class(title, "tile-title");
    gtk.gtk_widget_add_css_class(artist, "tile-artist");
    gtk.gtk_widget_set_margin_top(title, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), cover);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), artist);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    gtk.g_object_set_data(tile, "orca-list-item", item);
    menu.onSecondaryClick(tile, tileMenu, self);
}

/// Everything a menu needs to act on a whole Release: its tracks in
/// listening order, and who it is by.
pub fn setAlbumContext(self: *App, release_id: i64) bool {
    const library = self.library orelse return false;
    self.context.reset(.album);
    self.context.release_id = release_id;
    if (self.runtime.libraryRelease(library, release_id) catch null) |release| {
        defer release.deinit(self.allocator);
        self.context.artist_id = release.album_artist_id;
    }
    var tracks = self.runtime.libraryTrackQuery(library, "", .{
        .release_id = release_id,
        .sort = .track_number,
        .limit = app.page_size,
    }) catch return false;
    defer tracks.deinit();
    for (tracks.items) |item| {
        if (item.has_playable_file) self.context.addTrack(self.allocator, item.id, item.recording_id, item.feedback) catch return false;
    }
    return true;
}

fn tileMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(tile, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    const id = row.id() orelse return;
    if (setAlbumContext(self, id)) menu.popup(self, tile, x, y);
}

fn bindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    const tile = gtk.gtk_list_item_get_child(list_item) orelse return;
    const cover = gtk.gtk_widget_get_first_child(tile) orelse return;
    const title = gtk.gtk_widget_get_next_sibling(cover) orelse return;
    const artist = gtk.gtk_widget_get_next_sibling(title) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), if (row.name().len != 0) row.name().ptr else "Untitled");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), row.detail().ptr);
    art.setInitials(cover, row.name());
    const id = row.id() orelse return;
    art.show(self, cover, art.Key.release(id, .tile));
}

fn unbindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const cover = gtk.gtk_widget_get_first_child(tile) orelse return;
    art.forget(self, cover);
}

fn request(self: *App, offset: u32) liborca.ReleaseQuery {
    return .{ .sort = self.album_sort, .limit = app.page_size, .offset = offset };
}

pub fn reload(self: *App) void {
    const store = self.album_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.albums_loaded = 0;
    self.albums_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryReleaseCount(library) catch 0;
    if (self.albums_title) |title| {
        var buffer: [48]u8 = undefined;
        const text: [:0]const u8 = if (total == 1)
            "1 album"
        else
            strings.printZ(&buffer, "{d} albums", .{total}) catch "";
        adw.adw_window_title_set_subtitle(title, text.ptr);
    }
    if (self.albums_body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "grid");
    loadNextPage(self);
}

fn loadNextPage(self: *App) void {
    const store = self.album_store orelse return;
    if (self.albums_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryReleasePage(library, request(self, self.albums_loaded)) catch {
        self.albums_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.albums_exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    for (page.items) |release| {
        const row = browse_model.new(release.id, release.title, release.album_artist) orelse continue;
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
    self.albums_loaded += @intCast(page.items.len);
}

fn scrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page * 2) loadNextPage(self);
}

fn sortChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= sorts.len) return;
    if (sorts[selected].sort == self.album_sort) return;
    self.album_sort = sorts[selected].sort;
    reload(self);
}

fn tileActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.album_store orelse return;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *BrowseObject = @ptrCast(@alignCast(item));
    const id = row.id() orelse return;
    const navigation = self.albums_navigation orelse return;
    openAlbum(self, navigation, id);
}

pub fn build(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.album_store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupTile), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindTile), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const grid = gtk.gtk_grid_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 12);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 2);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", gtk.callback(tileActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), grid);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(scrolled),
        self,
    );

    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "media-optical-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "No albums yet");
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, empty), "Add a music folder from the main menu.");
    const body = gtk.gtk_stack_new();
    self.albums_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.albums_body.?, scroller, "grid");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, empty, "empty");

    const header = adw.adw_header_bar_new();
    const title = adw.adw_window_title_new("Albums", "");
    self.albums_title = gtk.cast(adw.WindowTitle, title);
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), title);
    var labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| labels[index] = entry.label;
    labels[sorts.len] = null;
    const sort = gtk.gtk_drop_down_new_from_strings(&labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort albums");
    gtk.gtk_widget_add_css_class(sort, "flat");
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), sort);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);

    const navigation = adw.adw_navigation_view_new();
    self.albums_navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Albums");
    adw.adw_navigation_page_set_tag(root, "albums");
    adw.adw_navigation_view_add(self.albums_navigation.?, root);
    return navigation;
}

/// What an open album page plays: its tracks in listening order, and whose
/// they are, index-aligned.
pub const AlbumPage = struct {
    self: *App,
    navigation: *adw.NavigationView,
    ids: []i64,
    songs: []feedback.Target,
    artists: []?i64,
    rows: []?*gtk.Widget,
    disc_lists: std.ArrayList(*gtk.Widget) = .empty,
    release_id: i64,
    album_artist_id: ?i64,
    details: ?*details.Panel = null,
};

fn pageData(data: ?*anyopaque) *AlbumPage {
    return @ptrCast(@alignCast(data.?));
}

fn pageDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const allocator = page.self.allocator;
    unregisterPage(page);
    page.disc_lists.deinit(allocator);
    allocator.free(page.ids);
    allocator.free(page.songs);
    allocator.free(page.artists);
    allocator.free(page.rows);
    allocator.destroy(page);
}

fn registerPage(page: *AlbumPage) void {
    const self = page.self;
    if (self.open_album_page_count == self.open_album_pages.len) return;
    self.open_album_pages[self.open_album_page_count] = page;
    self.open_album_page_count += 1;
}

fn unregisterPage(page: *AlbumPage) void {
    const self = page.self;
    for (self.open_album_pages[0..self.open_album_page_count], 0..) |open, index| {
        if (open != page) continue;
        self.open_album_page_count -= 1;
        self.open_album_pages[index] = self.open_album_pages[self.open_album_page_count];
        return;
    }
}

fn markRows(page: *AlbumPage, track_id: ?i64) void {
    for (page.ids, page.rows) |id, maybe_row| {
        const row = maybe_row orelse continue;
        if (track_id == id)
            gtk.gtk_widget_add_css_class(row, "now-playing")
        else
            gtk.gtk_widget_remove_css_class(row, "now-playing");
    }
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    for (self.open_album_pages[0..self.open_album_page_count]) |page| {
        for (page.songs, page.rows) |*song, maybe_row| {
            const recording = song.recording_id orelse continue;
            if (!changed.contains(recording)) continue;
            switch (change) {
                .feedback => |value| {
                    song.feedback = value;
                    const row = maybe_row orelse continue;
                    const heart = gtk.g_object_get_data(row, "orca-heart") orelse continue;
                    feedback.showRowButton(gtk.cast(gtk.Widget, heart), value);
                },
                .rating => |value| {
                    const row = maybe_row orelse continue;
                    const stars = gtk.g_object_get_data(row, "orca-stars") orelse continue;
                    ratings.show(gtk.cast(gtk.Widget, stars), value);
                },
            }
        }
    }
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    for (self.open_album_pages[0..self.open_album_page_count]) |page| markRows(page, track_id);
}

fn heroMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setAlbumContext(page.self, page.release_id)) menu.popup(page.self, menu.gestureWidget(gesture), x, y);
}

fn rowPosition(row: *gtk.Widget) ?usize {
    const name = gtk.gtk_widget_get_name(row);
    return std.fmt.parseInt(usize, std.mem.span(name), 10) catch null;
}

fn trackMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const row = menu.gestureWidget(gesture);
    const position = rowPosition(row) orelse return;
    if (position >= page.ids.len) return;
    const self = page.self;
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, page.ids[position], page.songs[position].recording_id, page.songs[position].feedback) catch return;
    self.context.release_id = page.release_id;
    self.context.artist_id = page.artists[position] orelse page.album_artist_id;
    menu.popup(self, row, x, y);
}

fn artistClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const id = page.album_artist_id orelse return;
    artists.openArtist(page.self, page.navigation, id);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    page.self.runtime.playerSetShuffle(page.self.player, false) catch {};
    transport.playIds(page.self, page.ids, 0);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    page.self.runtime.playerSetShuffle(page.self.player, true) catch {};
    transport.playIds(page.self, page.ids, 0);
}

fn trackSelected(box: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const selected = row orelse return;
    const page = pageData(data);
    for (page.disc_lists.items) |other| {
        if (@as(?*anyopaque, other) != box) gtk.gtk_list_box_unselect_all(gtk.cast(gtk.ListBox, other));
    }
    const position = rowPosition(gtk.cast(gtk.Widget, selected)) orelse return;
    if (position >= page.ids.len) return;
    if (page.details) |panel| details.choose(panel, page.ids[position]);
}

fn trackActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const start = rowPosition(gtk.cast(gtk.Widget, row)) orelse return;
    if (start >= page.ids.len) return;
    transport.playIds(page.self, page.ids, @intCast(start));
}

fn heartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-position"));
    if (marked == 0 or marked > page.songs.len) return;
    feedback.toggle(page.self, page.songs[marked - 1]);
}

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const stars = ratings.starsOf(button) orelse return;
    const marked = @intFromPtr(gtk.g_object_get_data(stars, "orca-position"));
    if (marked == 0 or marked > page.songs.len) return;
    ratings.change(page.self, &.{page.songs[marked - 1]}, ratings.chosen(button));
}

fn trackRow(page: *AlbumPage, summary: liborca.TrackSummary, album_artist: []const u8, position: usize) ?*gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "album-track-row");
    var name_buffer: [24]u8 = undefined;
    const name = strings.printZ(&name_buffer, "{d}", .{position}) catch return null;
    gtk.gtk_widget_set_name(row, name.ptr);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "album-track");
    var buffer: [512]u8 = undefined;
    const number: [:0]const u8 = if (summary.track_number) |value|
        strings.printZ(&buffer, "{d}", .{value}) catch ""
    else
        "";
    const number_label = gtk.gtk_label_new(number.ptr);
    gtk.gtk_widget_set_size_request(number_label, 28, -1);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number_label), 1.0);
    gtk.gtk_widget_add_css_class(number_label, "numeric");
    gtk.gtk_widget_add_css_class(number_label, "dim-label");

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title_text = strings.printZ(&buffer, "{s}", .{summary.title}) catch "";
    const title = gtk.gtk_label_new(title_text.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(title, "album-track-title");

    const heart = feedback.newRowButton(gtk.callback(heartClicked), page);
    feedback.showRowButton(heart, summary.feedback);
    gtk.g_object_set_data(heart, "orca-position", @ptrFromInt(position + 1));
    gtk.g_object_set_data(row, "orca-heart", heart);
    const stars = ratings.newRowStars(gtk.callback(starClicked), page);
    ratings.show(stars, summary.rating);
    gtk.g_object_set_data(stars, "orca-position", @ptrFromInt(position + 1));
    gtk.g_object_set_data(row, "orca-stars", stars);
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const title_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), heart);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), stars);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), spacer);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title_row);
    if (summary.artist.len != 0 and !std.mem.eql(u8, summary.artist, album_artist)) {
        const artist_text = strings.printZ(&buffer, "{s}", .{summary.artist}) catch "";
        const artist = gtk.gtk_label_new(artist_text.ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, artist), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, artist), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_add_css_class(artist, "caption");
        gtk.gtk_widget_add_css_class(artist, "dim-label");
        gtk.gtk_box_append(gtk.cast(gtk.Box, labels), artist);
    }
    const duration: [:0]const u8 = if (summary.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else "")
    else
        "";
    const duration_label = gtk.gtk_label_new(duration.ptr);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "dim-label");

    gtk.gtk_box_append(gtk.cast(gtk.Box, box), number_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), duration_label);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) {
        gtk.gtk_widget_set_sensitive(row, gtk.false_);
    }
    return row;
}

pub fn pill(label: [*:0]const u8, icon: [*:0]const u8, suggested: bool) *gtk.Widget {
    const button = gtk.gtk_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_image_new_from_icon_name(icon));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(label));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "pill");
    if (suggested) gtk.gtk_widget_add_css_class(button, "suggested-action");
    return button;
}

fn plural(buffer: []u8, count: usize, one: []const u8, many: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) one else many }) catch "";
}

pub fn openAlbum(self: *App, navigation: *adw.NavigationView, release_id: i64) void {
    const library = self.library orelse return;
    const release = (self.runtime.libraryRelease(library, release_id) catch null) orelse return;
    defer release.deinit(self.allocator);
    var tracks = self.runtime.libraryTrackQuery(library, "", .{
        .release_id = release_id,
        .sort = .track_number,
        .limit = app.page_size,
    }) catch return;
    defer tracks.deinit();

    const page = self.allocator.create(AlbumPage) catch return;
    page.* = .{
        .self = self,
        .navigation = navigation,
        .ids = &.{},
        .songs = &.{},
        .artists = &.{},
        .rows = &.{},
        .release_id = release_id,
        .album_artist_id = release.album_artist_id,
    };
    page.ids = self.allocator.alloc(i64, tracks.items.len) catch {
        self.allocator.destroy(page);
        return;
    };
    page.songs = self.allocator.alloc(feedback.Target, tracks.items.len) catch {
        self.allocator.free(page.ids);
        self.allocator.destroy(page);
        return;
    };
    page.artists = self.allocator.alloc(?i64, tracks.items.len) catch {
        self.allocator.free(page.ids);
        self.allocator.free(page.songs);
        self.allocator.destroy(page);
        return;
    };
    page.rows = self.allocator.alloc(?*gtk.Widget, tracks.items.len) catch {
        self.allocator.free(page.ids);
        self.allocator.free(page.songs);
        self.allocator.free(page.artists);
        self.allocator.destroy(page);
        return;
    };
    for (page.ids, page.songs, page.artists, page.rows, tracks.items) |*id, *song, *artist_id, *row, item| {
        id.* = item.id;
        song.* = .{ .track_id = item.id, .recording_id = item.recording_id, .feedback = item.feedback };
        artist_id.* = item.artist_id;
        row.* = null;
    }

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 24);
    gtk.gtk_widget_add_css_class(content, "album-page");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    const cover = art.newCover(self, art.initialsPlaceholder(), hero_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    gtk.gtk_widget_add_css_class(cover, "hero-cover");
    menu.onSecondaryClick(cover, heroMenu, page);
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release_id, .tile));
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), cover);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_END);
    var buffer: [512]u8 = undefined;
    const kind = gtk.gtk_label_new(if (release.is_compilation) "COMPILATION" else "ALBUM");
    gtk.gtk_widget_add_css_class(kind, "album-kind");
    const title = gtk.gtk_label_new(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr);
    gtk.gtk_widget_add_css_class(title, "album-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    menu.onSecondaryClick(title, heroMenu, page);
    const artist = gtk.gtk_button_new_with_label(strings.terminated(&buffer, release.album_artist).ptr);
    gtk.gtk_widget_add_css_class(artist, "album-artist");
    gtk.gtk_widget_add_css_class(artist, "flat");
    gtk.gtk_widget_set_halign(artist, gtk.ALIGN_START);
    _ = gtk.signalConnect(artist, "clicked", gtk.callback(artistClicked), page);
    var songs_buffer: [32]u8 = undefined;
    const songs = plural(&songs_buffer, tracks.items.len, "song", "songs");
    const minutes: u64 = @intCast(@divTrunc(@max(release.total_duration_ms, 0) + 30_000, 60_000));
    const year = if (release.release_date) |date| date[0..@min(date.len, 4)] else "";
    const meta_text = if (year.len != 0)
        strings.printZ(&buffer, "{s} · {s} · {d} min", .{ year, songs, minutes }) catch ""
    else
        strings.printZ(&buffer, "{s} · {d} min", .{ songs, minutes }) catch "";
    const meta = gtk.gtk_label_new(meta_text.ptr);
    gtk.gtk_widget_add_css_class(meta, "album-meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, kind), 0.0);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0.0);
    for ([_]*gtk.Widget{ kind, title, artist, meta }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, facts), widget);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_margin_top(actions, 10);
    const play = pill("Play", "media-playback-start-symbolic", true);
    const shuffle = pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), play);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), shuffle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), hero);

    const discs = release.disc_count orelse 1;
    var current_disc: ?i64 = null;
    var list: ?*gtk.Widget = null;
    for (tracks.items, 0..) |summary, position| {
        const disc = summary.disc_number orelse 1;
        if (list == null or (discs > 1 and !std.meta.eql(current_disc, disc))) {
            current_disc = disc;
            if (discs > 1) {
                const disc_text: [:0]const u8 = strings.printZ(&buffer, "Disc {d}", .{disc}) catch "";
                const heading = gtk.gtk_label_new(disc_text.ptr);
                gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0.0);
                gtk.gtk_widget_add_css_class(heading, "heading");
                gtk.gtk_box_append(gtk.cast(gtk.Box, content), heading);
            }
            const box = gtk.gtk_list_box_new();
            gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, box), gtk.SELECTION_SINGLE);
            gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, box), gtk.false_);
            gtk.gtk_widget_add_css_class(box, "boxed-list");
            _ = gtk.signalConnect(box, "row-selected", gtk.callback(trackSelected), page);
            _ = gtk.signalConnect(box, "row-activated", gtk.callback(trackActivated), page);
            page.disc_lists.append(self.allocator, box) catch {};
            gtk.gtk_box_append(gtk.cast(gtk.Box, content), box);
            list = box;
        }
        const row = trackRow(page, summary, release.album_artist, position) orelse continue;
        menu.onSecondaryClick(row, trackMenu, page);
        gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list.?), row);
        page.rows[position] = row;
    }
    markRows(page, self.shown_track_id);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 880);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), clamp);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);
    registerPage(page);

    const header = adw.adw_header_bar_new();
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    const beside = details.besideContent(self, header, scroller, .{ .ids = page.ids });
    page.details = beside.panel;
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), beside.widget);
    const title_text = strings.printZ(&buffer, "{s}", .{if (release.title.len != 0) release.title else "Album"}) catch "Album";
    adw.adw_navigation_view_push(navigation, adw.adw_navigation_page_new(view, title_text.ptr));
}
