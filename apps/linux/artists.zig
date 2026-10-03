//! The Artists page: every Artist as a grid of photos or a list, sorted and
//! searchable, and a page for each with their photo and biography, their top
//! tracks, their albums and the artists related to them.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const art = @import("art.zig");
const albums = @import("albums.zig");
const browse_model = @import("browse_model.zig");
const transport = @import("transport.zig");
const menu = @import("menu.zig");
const page_ui = @import("page.zig");
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const track_model = @import("track_model.zig");
const browse = @import("browse.zig");
const window = @import("window.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const thumb_pixels: c_int = 40;
const tile_pixels: c_int = 150;
const grid_gutter_pixels = 72;
const grid_cell_pixels = 182;
const grid_min_columns = 2;
const min_tile_pixels = 72;
const photo_width: c_int = 300;
const photo_height: c_int = 330;
const biography_max_pixels = 480;
const biography_lines = 4;
const album_pixels: c_int = 128;
const release_row_limit = 8;
const song_cover_pixels: c_int = 44;
const related_pixels: c_int = 80;
const related_limit = 6;
const related_tile_pixels: c_int = 96;
const top_song_limit = 5;
const queue_limit = 10_000;
const pending_info_limit = 8;
const musicbrainz_artist_url = "https://musicbrainz.org/artist/";

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.ArtistSort }{
    .{ .label = "Name", .sort = .name },
    .{ .label = "Most tracks", .sort = .track_count },
    .{ .label = "Recently loved", .sort = .recently_loved },
    .{ .label = "Recently added", .sort = .recently_added },
};

/// Artist info fetches: each Artist is asked about at most once a session
/// unless the user asks again, and the jobs still running are polled from
/// `tick`.
pub const Info = struct {
    requested: std.AutoHashMapUnmanaged(i64, void) = .empty,
    pending: [pending_info_limit]Pending = undefined,
    pending_count: usize = 0,
    closed: bool = false,

    const Pending = struct {
        artist_id: i64,
        job: liborca.JobHandle,
    };

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        self.requested.deinit(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn part(widget: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    const found = gtk.g_object_get_data(widget, key) orelse return null;
    return gtk.cast(gtk.Widget, found);
}

fn centredLabel(class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn setupTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "artist-tile");
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(tile, self.artist_tile_pixels, -1);
    const cover = art.newCover(self, art.initialsPlaceholder(), self.artist_tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "artist-photo");
    const name = centredLabel("artist-tile-name");
    const detail = centredLabel("artist-tile-meta");
    gtk.gtk_widget_add_css_class(detail, "numeric");
    for ([_]*gtk.Widget{ cover, name, detail }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    gtk.g_object_set_data(tile, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-cover", cover);
    gtk.g_object_set_data(tile, "orca-name", name);
    gtk.g_object_set_data(tile, "orca-detail", detail);
    menu.onSecondaryClick(tile, rowMenu, self);
}

fn showFace(self: *App, cover: *gtk.Widget, artist: *BrowseObject, size: art.Size) void {
    const id = artist.id() orelse return art.clear(self, cover);
    const face = artist.artist();
    art.showArtist(self, cover, id, if (face.has_photo) .stored else .absent, face.cover_release_id, size);
}

fn bindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const artist: *BrowseObject = @ptrCast(@alignCast(object));
    const tile = gtk.gtk_list_item_get_child(list_item) orelse return;
    const cover = part(tile, "orca-cover") orelse return;
    const name = part(tile, "orca-name") orelse return;
    const detail = part(tile, "orca-detail") orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, name), if (artist.name().len != 0) artist.name().ptr else "Unknown Artist");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), artist.detail().ptr);
    art.setInitials(cover, artist.name());
    showFace(self, cover, artist, .tile);
}

fn unbindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const cover = part(tile, "orca-cover") orelse return;
    art.forget(state(data), cover);
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
    gtk.g_object_set_data(row, "orca-cover", thumb);
    gtk.g_object_set_data(row, "orca-name", name);
    gtk.g_object_set_data(row, "orca-detail", detail);
    menu.onSecondaryClick(row, rowMenu, self);
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const artist: *BrowseObject = @ptrCast(@alignCast(object));
    const row = gtk.gtk_list_item_get_child(list_item) orelse return;
    const thumb = part(row, "orca-cover") orelse return;
    const name = part(row, "orca-name") orelse return;
    const detail = part(row, "orca-detail") orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, name), if (artist.name().len != 0) artist.name().ptr else "Unknown Artist");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), artist.detail().ptr);
    art.setInitials(thumb, artist.name());
    showFace(self, thumb, artist, .thumb);
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

pub fn firstRelease(self: *App, artist_id: i64) ?i64 {
    return artistRelease(self, artist_id, .artist);
}

fn mostPlayedRelease(self: *App, artist_id: i64) ?i64 {
    return artistRelease(self, artist_id, .most_played);
}

fn artistRelease(self: *App, artist_id: i64, sort: liborca.ReleaseSort) ?i64 {
    return firstReleaseMatching(self, artist_id, sort, true) orelse firstReleaseMatching(self, artist_id, sort, false);
}

fn firstReleaseMatching(self: *App, artist_id: i64, sort: liborca.ReleaseSort, own_releases_only: bool) ?i64 {
    const library = self.library orelse return null;
    var page = self.runtime.libraryReleasePage(library, .{
        .album_artist_id = artist_id,
        .own_releases_only = own_releases_only,
        .sort = sort,
        .limit = 1,
    }) catch return null;
    defer page.deinit();
    if (page.items.len == 0) return null;
    return page.items[0].id;
}

fn request(self: *App, offset: u32) liborca.ArtistQuery {
    return .{
        .filter = self.artist_list_filter.value,
        .genre_id = self.artist_list_genre,
        .sort = self.artist_sort,
        .limit = app.page_size,
        .offset = offset,
    };
}

pub fn reload(self: *App) void {
    const store = self.artist_list_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.artist_list_loaded = 0;
    self.artist_list_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryArtistCountMatching(library, request(self, 0)) catch 0;
    if (self.artist_list_meta) |meta| {
        var buffer: [48]u8 = undefined;
        const text: [:0]const u8 = if (total == 1) "1 artist" else strings.printZ(&buffer, "{d} artists", .{total}) catch "";
        gtk.gtk_label_set_text(meta, text.ptr);
    }
    if (self.artists_empty) |empty| {
        const searching = self.artist_list_filter.value.len != 0 or self.artist_list_genre != null;
        adw.adw_status_page_set_title(empty, if (searching) "No matching artists" else "No artists yet");
        adw.adw_status_page_set_description(empty, if (searching) "Try another search." else "Add a music folder from the main menu.");
    }
    if (self.artists_body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else @tagName(self.artist_layout));
    loadNextPage(self);
}

fn loadNextPage(self: *App) void {
    const store = self.artist_list_store orelse return;
    if (self.artist_list_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryArtistPage(library, request(self, self.artist_list_loaded)) catch {
        self.artist_list_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.artist_list_exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    var buffer: [96]u8 = undefined;
    for (page.items) |artist| {
        const detail = std.fmt.bufPrint(&buffer, "{d} {s} • {d} {s}", .{
            artist.release_count,
            if (artist.release_count == 1) "album" else "albums",
            artist.track_count,
            if (artist.track_count == 1) "track" else "tracks",
        }) catch "";
        const row = browse_model.newArtist(artist.id, artist.name, detail, .{
            .has_photo = artist.has_photo,
            .cover_release_id = artist.cover_release_id,
        }) orelse continue;
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

pub fn setFilter(self: *App, text: []const u8) void {
    if (std.mem.eql(u8, text, self.artist_list_filter.value)) return;
    self.artist_list_filter.set(self.allocator, text);
    reload(self);
}

fn showGenreChip(self: *App) void {
    const chip = self.artist_genre_chip orelse return;
    const name = self.artist_list_genre_name.value;
    if (self.artist_list_genre == null) return gtk.gtk_widget_set_visible(chip, gtk.false_);
    var buffer: [256]u8 = undefined;
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, chip), strings.printZ(&buffer, "Genre: {s}  \u{2715}", .{
        if (name.len != 0) name else "Unknown",
    }) catch "Genre");
    gtk.gtk_widget_set_visible(chip, gtk.true_);
}

fn genreChipClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.artist_list_genre = null;
    self.artist_list_genre_name.clear(self.allocator);
    showGenreChip(self);
    reload(self);
}

pub fn showGenre(self: *App, genre_id: i64, name: []const u8) void {
    self.artist_list_genre = genre_id;
    self.artist_list_genre_name.set(self.allocator, name);
    window.clearSearch(self);
    self.artist_list_filter.clear(self.allocator);
    showGenreChip(self);
    reload(self);
    window.showPage(self, .artists);
    if (self.artists_navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, "artists");
}

fn activated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.artist_list_store orelse return;
    const id = albums.releaseAt(store, position) orelse return;
    const navigation = self.artists_navigation orelse return;
    openArtist(self, navigation, id);
}

fn gridColumns(width: f64) c_uint {
    const fitting = @floor((width - grid_gutter_pixels) / grid_cell_pixels);
    if (!(fitting > grid_min_columns)) return grid_min_columns;
    return @intFromFloat(@min(fitting, 16));
}

fn gridTilePixels(width: f64) c_int {
    const cell = @floor((width - grid_gutter_pixels) / grid_min_columns);
    if (!(cell < grid_cell_pixels)) return tile_pixels;
    return @intFromFloat(@max(cell - (grid_cell_pixels - tile_pixels), min_tile_pixels));
}

fn applyGridColumns(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const grid = self.artist_grid orelse return gtk.false_;
    gtk.gtk_grid_view_set_min_columns(grid, self.artist_grid_columns);
    gtk.gtk_grid_view_set_max_columns(grid, self.artist_grid_columns);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, grid));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        if (gtk.gtk_widget_get_first_child(cell)) |tile| albums.sizeTile(tile, self.artist_tile_pixels);
    }
    return gtk.false_;
}

fn gridResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    const columns = gridColumns(width);
    const pixels = gridTilePixels(width);
    if (columns == self.artist_grid_columns and pixels == self.artist_tile_pixels) return;
    self.artist_grid_columns = columns;
    self.artist_tile_pixels = pixels;
    _ = gtk.g_idle_add(applyGridColumns, self);
}

fn pagingScroller(self: *App, child: *gtk.Widget) *gtk.Widget {
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), child);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(scrolled),
        self,
    );
    return scroller;
}

fn newGrid(self: *App, store: *gtk.ListStore) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupTile), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindTile), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const grid = gtk.gtk_grid_view_new(albums.newSelection(store), factory);
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_widget_add_css_class(grid, "artist-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), grid_min_columns);
    gtk.gtk_grid_view_set_tab_behavior(gtk.cast(gtk.GridView, grid), gtk.LIST_TAB_ITEM);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", gtk.callback(activated), self);
    return grid;
}

fn newList(self: *App, store: *gtk.ListStore) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindRow), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const list = gtk.gtk_list_view_new(albums.newSelection(store), factory);
    gtk.gtk_widget_add_css_class(list, "artist-list");
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, list), gtk.LIST_TAB_ITEM);
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, list), gtk.true_);
    _ = gtk.signalConnect(list, "activate", gtk.callback(activated), self);
    return list;
}

fn syncControls(self: *App) void {
    self.artists_syncing_controls = true;
    defer self.artists_syncing_controls = false;
    if (self.artist_sort_control) |control| {
        for (sorts, 0..) |entry, index| {
            if (entry.sort == self.artist_sort) gtk.gtk_drop_down_set_selected(control, @intCast(index));
        }
    }
    if (self.artist_layout_toggles[@intFromEnum(self.artist_layout)]) |toggle|
        gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
}

fn showLayout(self: *App) void {
    const body = self.artists_body orelse return;
    const visible = gtk.gtk_stack_get_visible_child_name(body) orelse return;
    if (std.mem.eql(u8, std.mem.span(visible), "empty")) return;
    gtk.gtk_stack_set_visible_child_name(body, @tagName(self.artist_layout));
}

fn sortChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.artists_syncing_controls) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= sorts.len) return;
    if (sorts[selected].sort == self.artist_sort) return;
    self.artist_sort = sorts[selected].sort;
    settings.save(self);
    reload(self);
}

fn layoutToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.artists_syncing_controls) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    const layout: albums.Layout = for (self.artist_layout_toggles, 0..) |candidate, index| {
        if (candidate == toggle) break @enumFromInt(index);
    } else return;
    if (layout == self.artist_layout) return;
    self.artist_layout = layout;
    showLayout(self);
    settings.save(self);
}

fn newLayoutSwitch(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "linked");
    gtk.gtk_widget_add_css_class(box, "view-switch");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    const choices = [_]struct { layout: albums.Layout, icon: [*:0]const u8, tooltip: [*:0]const u8 }{
        .{ .layout = .grid, .icon = "view-grid-symbolic", .tooltip = "Grid" },
        .{ .layout = .list, .icon = "view-list-symbolic", .tooltip = "List" },
    };
    var group: ?*gtk.ToggleButton = null;
    for (choices) |choice| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), choice.icon);
        gtk.gtk_widget_set_tooltip_text(button, choice.tooltip);
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        self.artist_layout_toggles[@intFromEnum(choice.layout)] = toggle;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(layoutToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
}

pub fn build(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.artist_list_store = store;
    const grid = newGrid(self, store);
    self.artist_grid = gtk.cast(gtk.GridView, grid);
    const grid_scroller = pagingScroller(self, grid);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, grid_scroller)),
        "changed",
        gtk.callback(gridResized),
        self,
    );
    const list_scroller = pagingScroller(self, newList(self, store));

    const empty = adw.adw_status_page_new();
    self.artists_empty = gtk.cast(adw.StatusPage, empty);
    adw.adw_status_page_set_icon_name(self.artists_empty.?, "avatar-default-symbolic");
    const body = gtk.gtk_stack_new();
    self.artists_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.artists_body.?, grid_scroller, "grid");
    _ = gtk.gtk_stack_add_named(self.artists_body.?, list_scroller, "list");
    _ = gtk.gtk_stack_add_named(self.artists_body.?, empty, "empty");
    gtk.gtk_widget_set_vexpand(body, gtk.true_);

    const chip = gtk.gtk_button_new_with_label("Genre");
    gtk.gtk_widget_add_css_class(chip, "album-chip");
    gtk.gtk_widget_add_css_class(chip, "genre-chip");
    gtk.gtk_widget_add_css_class(chip, "artists-genre-chip");
    gtk.gtk_widget_set_halign(chip, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(chip, "Show every genre");
    gtk.gtk_widget_set_visible(chip, gtk.false_);
    _ = gtk.signalConnect(chip, "clicked", gtk.callback(genreChipClicked), self);
    self.artist_genre_chip = chip;
    const listing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), chip);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), body);

    const title = page_ui.title("Artists");
    self.artist_list_meta = title.meta;
    var labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| labels[index] = entry.label;
    labels[sorts.len] = null;
    const sort_label = gtk.gtk_label_new("Sort by");
    gtk.gtk_widget_add_css_class(sort_label, "meta");
    gtk.gtk_widget_set_valign(sort_label, gtk.ALIGN_CENTER);
    const sort = gtk.gtk_drop_down_new_from_strings(&labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort artists");
    gtk.gtk_widget_add_css_class(sort, "sort-dropdown");
    self.artist_sort_control = gtk.cast(gtk.DropDown, sort);
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    title.add(sort_label);
    title.add(sort);
    title.add(newLayoutSwitch(self));
    syncControls(self);
    gtk.gtk_stack_set_visible_child_name(self.artists_body.?, @tagName(self.artist_layout));
    const view = page_ui.withTitle(title, listing);

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

const Related = struct {
    library_artist_id: ?i64,
    mbid: [36]u8,
    mbid_len: u8,
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
    related: [related_limit]Related = undefined,
    related_count: usize = 0,
    loved: bool = false,
    hero: ?*gtk.Widget = null,
    stats: ?*gtk.Widget = null,
    sections: ?*gtk.Widget = null,
    scroller: ?*gtk.Widget = null,
    photo: ?*gtk.Widget = null,
    genres: ?*gtk.Widget = null,
    biography: ?*gtk.Widget = null,
    biography_label: ?*gtk.Widget = null,
    listeners: ?*gtk.Widget = null,
    listeners_number: ?*gtk.Label = null,
    credit: ?*gtk.Widget = null,
    related_section: ?*gtk.Widget = null,
    related_flow: ?*gtk.Widget = null,
    love_button: ?*gtk.Widget = null,
};

fn pageData(data: ?*anyopaque) *ArtistPage {
    return @ptrCast(@alignCast(data.?));
}

fn pageDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const allocator = page.self.allocator;
    unregisterPage(page);
    details.forgetIds(page.self, page.song_ids[0..]);
    allocator.free(page.name);
    allocator.free(page.tracks);
    allocator.free(page.releases);
    allocator.destroy(page);
}

/// What the inspector follows while `pushed`, an artist page, shows.
pub fn inspectorSource(self: *App, pushed: *adw.NavigationPage) ?details.Source {
    const child = adw.adw_navigation_page_get_child(pushed) orelse return null;
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        if (page.scroller != child) continue;
        return .{ .artist = .{ .ids = page.song_ids[0..], .artist_id = page.artist_id } };
    }
    return null;
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
    const stacked = narrow or page.self.header_compact;
    const orientation: c_int = if (stacked) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL;
    if (page.hero) |hero| {
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, hero), orientation);
        if (gtk.gtk_widget_get_parent(hero)) |block| {
            if (stacked) gtk.gtk_widget_add_css_class(block, "stacked") else gtk.gtk_widget_remove_css_class(block, "stacked");
        }
    }
    if (page.stats) |stats| {
        gtk.gtk_widget_set_visible(stats, @intFromBool(!narrow));
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, stats), if (stacked) gtk.ORIENTATION_HORIZONTAL else gtk.ORIENTATION_VERTICAL);
        gtk.gtk_box_set_spacing(gtk.cast(gtk.Box, stats), if (stacked) 40 else 16);
        gtk.gtk_widget_set_halign(stats, if (stacked) gtk.ALIGN_START else gtk.ALIGN_FILL);
    }
    if (page.sections) |sections| {
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, sections), orientation);
        gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, sections), @intFromBool(!stacked));
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

fn setArtistLove(self: *App, artist_id: i64, artist_loved: bool) void {
    const library = self.library orelse return;
    const result = self.runtime.librarySetArtistLove(library, &.{artist_id}, artist_loved) catch
        return self.toast("Could not save that");
    if (result.skipped != 0) return self.toast("That artist is no longer in the library");
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        if (page.artist_id != artist_id) continue;
        page.loved = artist_loved;
        if (page.love_button) |button| feedback.showArtistButton(button, artist_loved);
    }
    if (self.artist_sort == .recently_loved) reload(self);
}

fn loveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    setArtistLove(page.self, page.artist_id, !page.loved);
}

fn heroMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setArtistContext(page.self, page.artist_id)) menu.popup(page.self, menu.gestureWidget(gesture), x, y);
}

fn heroMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setArtistContext(page.self, page.artist_id)) albums.popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn biographyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    details.revealArtist(page.self, page.artist_id);
}

fn seeAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const self = page.self;
    browse.scopeToArtist(self, page.artist_id, page.name);
    self.browse.sort = .play_count;
    self.browse.direction = .descending;
    window.showSort(self);
    self.reload();
    window.showPage(self, .tracks);
}

fn marked(widget: ?*anyopaque) ?usize {
    const position = @intFromPtr(gtk.g_object_get_data(widget.?, "orca-position"));
    if (position == 0) return null;
    return position - 1;
}

fn markPosition(widget: *gtk.Widget, position: usize) void {
    gtk.g_object_set_data(widget, "orca-position", @ptrFromInt(position + 1));
}

fn releaseSeeAllClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const scope = std.enums.fromInt(albums.ArtistScope, marked(button) orelse return) orelse return;
    albums.showArtist(page.self, page.artist_id, page.name, scope);
}

fn albumActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const tile = gtk.gtk_flow_box_child_get_child(gtk.cast(gtk.FlowBoxChild, child)) orelse return;
    const index = marked(tile) orelse return;
    if (index >= page.releases.len) return;
    albums.openAlbum(page.self, page.navigation, page.releases[index]);
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
    gtk.gtk_widget_set_size_request(tile, album_pixels, -1);
    markPosition(tile, position);

    const cover = art.newCover(self, art.initialsPlaceholder(), album_pixels);
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
    const artist = tileLabel(strings.terminated(&buffer, release.album_artist).ptr, "tile-artist");
    gtk.gtk_widget_set_hexpand(artist, gtk.true_);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    for ([_][*:0]const u8{ "flat", "tile-more", "tile-action" }) |class| gtk.gtk_widget_add_css_class(more, class);
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    markPosition(more, position);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(albumMoreClicked), page);
    const byline = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, byline), artist);
    gtk.gtk_box_append(gtk.cast(gtk.Box, byline), more);
    const year = tileLabel(strings.terminated(&buffer, releaseYear(release)).ptr, "tile-year");
    gtk.gtk_widget_add_css_class(year, "numeric");

    for ([_]*gtk.Widget{ frame, title, byline, year }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
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
    details.choose(page.self, page.song_ids[0..], page.song_ids[position]);
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

fn explicitBadge() *gtk.Widget {
    const badge = gtk.gtk_label_new("E");
    gtk.gtk_widget_add_css_class(badge, "explicit-badge");
    gtk.gtk_widget_set_tooltip_text(badge, "Explicit");
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_CENTER);
    return badge;
}

fn songRow(page: *ArtistPage, summary: liborca.TrackSummary, position: usize) *gtk.Widget {
    const self = page.self;
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "album-track-row");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "artist-song");

    var buffer: [512]u8 = undefined;
    const number = gtk.gtk_label_new(strings.format(&buffer, "{d}", .{position + 1}).ptr);
    gtk.gtk_widget_set_size_request(number, 16, -1);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 0.5);
    gtk.gtk_widget_add_css_class(number, "artist-song-number");
    gtk.gtk_widget_add_css_class(number, "numeric");

    const thumb = art.newCover(self, art.iconPlaceholder(song_cover_pixels), song_cover_pixels);
    gtk.gtk_widget_add_css_class(thumb, "artist-song-cover");
    art.show(self, thumb, if (summary.release_id) |release| art.Key.release(release, .thumb) else art.Key.track(summary.id, .thumb));

    const title = gtk.gtk_label_new(strings.terminated(&buffer, if (summary.title.len != 0) summary.title else "Untitled").ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(title, "album-track-title");
    const title_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_hexpand(title_box, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_box), title);
    if (summary.explicit == .explicit) gtk.gtk_box_append(gtk.cast(gtk.Box, title_box), explicitBadge());

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

    for ([_]*gtk.Widget{ number, thumb, title_box, heart, duration_label, more }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
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

fn sectionHeading(text: [*:0]const u8, subtitle: ?[*:0]const u8) *gtk.Widget {
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "artist-section-heading");
    const titles = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(titles, gtk.true_);
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_widget_add_css_class(label, "section-title");
    gtk.gtk_box_append(gtk.cast(gtk.Box, titles), label);
    if (subtitle) |words| {
        const caption = gtk.gtk_label_new(words);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, caption), 0.0);
        gtk.gtk_widget_add_css_class(caption, "artist-section-subtitle");
        gtk.gtk_box_append(gtk.cast(gtk.Box, titles), caption);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), titles);
    return heading;
}

fn section() *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(box, "artist-section");
    return box;
}

fn songsSection(page: *ArtistPage, top: []const liborca.TrackSummary, by_rating: bool) *gtk.Widget {
    const box = section();
    const heading = sectionHeading("Top Tracks", if (by_rating) "By rating" else "Most played in your library");
    const see_all = gtk.gtk_button_new_with_label("See All");
    gtk.gtk_widget_add_css_class(see_all, "flat");
    gtk.gtk_widget_add_css_class(see_all, "see-all");
    gtk.gtk_widget_set_valign(see_all, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(see_all, "Show their tracks in Tracks, most played first");
    _ = gtk.signalConnect(see_all, "clicked", gtk.callback(seeAllClicked), page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), see_all);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);

    const list = gtk.gtk_list_box_new();
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_SINGLE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.false_);
    gtk.gtk_widget_add_css_class(list, "album-tracks");
    gtk.gtk_widget_add_css_class(list, "artist-songs");
    _ = gtk.signalConnect(list, "row-selected", gtk.callback(songSelected), page);
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(songActivated), page);
    for (top, 0..) |summary, position| gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list), songRow(page, summary, position));
    page.song_count = top.len;
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), list);
    return box;
}

const ReleaseRow = struct {
    scope: albums.ArtistScope,
    count: u64,
    releases: liborca.ReleasePage,
    first_position: usize = 0,

    fn title(self: *const ReleaseRow) [*:0]const u8 {
        return switch (self.scope) {
            .albums => "Albums",
            .eps_and_singles => "EPs & Singles",
            .appearances => "Appearances",
        };
    }

    fn tooltip(self: *const ReleaseRow) [*:0]const u8 {
        return switch (self.scope) {
            .albums => "Show their albums in Albums",
            .eps_and_singles => "Show their EPs and singles in Albums",
            .appearances => "Show the releases they appear on in Albums",
        };
    }
};

fn loadReleaseRow(self: *App, library: liborca.LibraryHandle, artist_id: i64, scope: albums.ArtistScope, known_count: ?u64) ?ReleaseRow {
    var query: liborca.ReleaseQuery = switch (scope) {
        .albums => .{ .album_artist_id = artist_id, .own_releases_only = true, .release_kind = .album },
        .eps_and_singles => .{ .album_artist_id = artist_id, .own_releases_only = true, .release_kind = .ep_or_single },
        .appearances => .{ .appearing_artist_id = artist_id },
    };
    const count = known_count orelse (self.runtime.libraryReleaseCountMatching(library, query) catch return null);
    if (count == 0) return null;
    query.sort = .year;
    query.limit = release_row_limit;
    const releases = self.runtime.libraryReleasePage(library, query) catch return null;
    return .{ .scope = scope, .count = count, .releases = releases };
}

fn albumsSection(page: *ArtistPage, row: *const ReleaseRow) *gtk.Widget {
    const box = section();
    var buffer: [64]u8 = undefined;
    const subtitle = strings.format(&buffer, "{d} in your library", .{row.count});
    const heading = sectionHeading(row.title(), subtitle.ptr);
    const see_all = gtk.gtk_button_new_with_label("See All");
    gtk.gtk_widget_add_css_class(see_all, "flat");
    gtk.gtk_widget_add_css_class(see_all, "see-all");
    gtk.gtk_widget_set_valign(see_all, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(see_all, row.tooltip());
    markPosition(see_all, @intFromEnum(row.scope));
    _ = gtk.signalConnect(see_all, "clicked", gtk.callback(releaseSeeAllClicked), page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), see_all);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);
    const flow = gtk.gtk_flow_box_new();
    const flow_box = gtk.cast(gtk.FlowBox, flow);
    gtk.gtk_flow_box_set_selection_mode(flow_box, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_min_children_per_line(flow_box, 2);
    gtk.gtk_flow_box_set_max_children_per_line(flow_box, 8);
    gtk.gtk_flow_box_set_column_spacing(flow_box, 4);
    gtk.gtk_flow_box_set_row_spacing(flow_box, 4);
    gtk.gtk_flow_box_set_activate_on_single_click(flow_box, gtk.true_);
    gtk.gtk_widget_set_halign(flow, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(flow, "artist-albums");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(albumActivated), page);
    for (row.releases.items, row.first_position..) |release, position| gtk.gtk_flow_box_append(flow_box, albumTile(page, release, position));
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), flow);
    return box;
}

fn launched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_uri_launcher_launch_finish(gtk.cast(gtk.UriLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open MusicBrainz");
}

fn relatedClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = marked(button) orelse return;
    if (index >= page.related_count) return;
    const related = page.related[index];
    if (related.library_artist_id) |id| return openArtist(page.self, page.navigation, id);
    var buffer: [128]u8 = undefined;
    const url = strings.printZ(&buffer, musicbrainz_artist_url ++ "{s}", .{related.mbid[0..related.mbid_len]}) catch return;
    const launcher = gtk.gtk_uri_launcher_new(url.ptr);
    gtk.gtk_uri_launcher_launch(launcher, page.self.window, null, launched, page.self);
    gtk.g_object_unref(launcher);
}

fn relatedTile(page: *ArtistPage, related: liborca.RelatedArtist, position: usize) *gtk.Widget {
    const self = page.self;
    const button = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "related-artist");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_START);
    const cover = art.newCover(self, art.initialsPlaceholder(), related_pixels);
    gtk.gtk_widget_add_css_class(cover, "artist-photo");
    art.setInitials(cover, related.name);
    var shows_related_photo = false;
    if (related.library_artist_id) |id| {
        art.showArtist(self, cover, id, if (related.has_photo) .stored else .absent, null, .thumb);
    } else if (related.has_photo) {
        shows_related_photo = art.showRelated(self, cover, related.mbid, .thumb);
    }
    var buffer: [256]u8 = undefined;
    const name = gtk.gtk_label_new(strings.terminated(&buffer, related.name).ptr);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, name), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, name), gtk.WRAP_WORD);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, name), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_justify(gtk.cast(gtk.Label, name), gtk.JUSTIFY_CENTER);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, name), 10);
    gtk.gtk_widget_set_size_request(button, related_tile_pixels, -1);
    gtk.gtk_widget_add_css_class(name, "related-artist-name");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cover);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), name);
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), box);
    const action = if (related.library_artist_id != null) "Open in your library" else "Open on MusicBrainz";
    var tooltip: [640]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(button, relatedTooltip(self, related.mbid, shows_related_photo, action, &tooltip).ptr);
    markPosition(button, position);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(relatedClicked), page);
    return button;
}

fn relatedTooltip(self: *App, mbid: []const u8, shows_photo: bool, action: [:0]const u8, buffer: []u8) [:0]const u8 {
    if (!shows_photo) return action;
    const library = self.library orelse return action;
    var info = (self.runtime.libraryRelatedArtistPhotoInfo(library, mbid) catch return action) orelse return action;
    defer info.deinit();
    const author = std.mem.trim(u8, info.record.credit orelse "", " \n");
    const licence = std.mem.trim(u8, info.record.licence orelse "", " \n");
    if (author.len == 0 and licence.len == 0) return action;
    if (author.len != 0 and licence.len != 0) return strings.format(buffer, "{s}\nPhoto: {s} • {s}", .{ action, author, licence });
    return strings.format(buffer, "{s}\nPhoto: {s}", .{ action, if (author.len != 0) author else licence });
}

fn showRelated(page: *ArtistPage) void {
    const self = page.self;
    const section_box = page.related_section orelse return;
    const flow = page.related_flow orelse return;
    const library = self.library orelse return;
    gtk.gtk_flow_box_remove_all(gtk.cast(gtk.FlowBox, flow));
    page.related_count = 0;
    var related = self.runtime.libraryRelatedArtists(library, page.artist_id) catch {
        gtk.gtk_widget_set_visible(section_box, gtk.false_);
        return;
    };
    defer related.deinit();
    for (related.items) |item| {
        if (page.related_count == related_limit) break;
        if (item.mbid.len > 36) continue;
        var entry: Related = .{ .library_artist_id = item.library_artist_id, .mbid = undefined, .mbid_len = @intCast(item.mbid.len) };
        @memcpy(entry.mbid[0..item.mbid.len], item.mbid);
        page.related[page.related_count] = entry;
        gtk.gtk_flow_box_append(gtk.cast(gtk.FlowBox, flow), relatedTile(page, item, page.related_count));
        page.related_count += 1;
    }
    gtk.gtk_widget_set_visible(section_box, @intFromBool(page.related_count != 0));
}

fn relatedSection(page: *ArtistPage) *gtk.Widget {
    const box = section();
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), sectionHeading("Related Artists", null));
    const flow = gtk.gtk_flow_box_new();
    const flow_box = gtk.cast(gtk.FlowBox, flow);
    gtk.gtk_flow_box_set_selection_mode(flow_box, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_min_children_per_line(flow_box, 2);
    gtk.gtk_flow_box_set_max_children_per_line(flow_box, related_limit);
    gtk.gtk_flow_box_set_homogeneous(flow_box, gtk.true_);
    gtk.gtk_flow_box_set_column_spacing(flow_box, 4);
    gtk.gtk_flow_box_set_row_spacing(flow_box, 4);
    gtk.gtk_widget_set_halign(flow, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(flow, "related-artists");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), flow);
    page.related_section = box;
    page.related_flow = flow;
    return box;
}

fn playableTracks(self: *App, library: liborca.LibraryHandle, artist_id: i64) std.ArrayList(i64) {
    var tracks: std.ArrayList(i64) = .empty;
    var offset: u32 = 0;
    while (tracks.items.len < queue_limit) {
        var page = self.runtime.libraryTrackQuery(library, "", .{
            .artist_id = artist_id,
            .sort = .album,
            .limit = app.page_size,
            .offset = offset,
        }) catch break;
        defer page.deinit();
        for (page.items) |item| {
            if (!item.has_playable_file or tracks.items.len == queue_limit) continue;
            tracks.append(self.allocator, item.id) catch {};
        }
        if (page.items.len < app.page_size) break;
        offset += app.page_size;
    }
    return tracks;
}

const Stat = struct {
    widget: *gtk.Widget,
    number: *gtk.Label,
};

fn stat(number_text: [*:0]const u8, label_text: [*:0]const u8) Stat {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, "artist-stat");
    const number = gtk.gtk_label_new(number_text);
    gtk.gtk_widget_add_css_class(number, "artist-stat-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    const label = gtk.gtk_label_new(label_text);
    gtk.gtk_widget_add_css_class(label, "artist-stat-label");
    for ([_]*gtk.Widget{ number, label }) |piece| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, piece), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    }
    return .{ .widget = box, .number = gtk.cast(gtk.Label, number) };
}

fn compactCount(buffer: []u8, count: u64) [:0]const u8 {
    if (count < 1000) return strings.format(buffer, "{d}", .{count});
    const value: f64 = @floatFromInt(count);
    if (count < 999_950) return strings.format(buffer, "{d:.1}K", .{value / 1000.0});
    return strings.format(buffer, "{d:.1}M", .{value / 1_000_000.0});
}

fn statColumn(page: *ArtistPage, totals: liborca.ArtistTotals) *gtk.Widget {
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(column, "artist-stats");
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_CENTER);
    var buffer: [32]u8 = undefined;

    const listeners = stat("", "Listeners");
    gtk.gtk_widget_set_tooltip_text(listeners.widget, "Listeners on ListenBrainz");
    gtk.gtk_widget_set_visible(listeners.widget, gtk.false_);
    page.listeners = listeners.widget;
    page.listeners_number = listeners.number;
    const album_stat = stat(strings.format(&buffer, "{d}", .{totals.release_count}).ptr, if (totals.release_count == 1) "Album" else "Albums");
    const track_stat = stat(strings.format(&buffer, "{d}", .{totals.track_count}).ptr, if (totals.track_count == 1) "Track" else "Tracks");
    const minutes = (totals.duration_ms + 30_000) / 60_000;
    const time: [:0]const u8 = if (minutes >= 60)
        strings.format(&buffer, "{d:.1} hrs", .{@as(f64, @floatFromInt(totals.duration_ms)) / 3_600_000.0})
    else
        strings.format(&buffer, "{d} min", .{minutes});
    const time_stat = stat(time.ptr, "In Your Library");

    for ([_]*gtk.Widget{ listeners.widget, album_stat.widget, track_stat.widget, time_stat.widget }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, column), widget);
    return column;
}

fn showGenres(page: *ArtistPage) void {
    const self = page.self;
    const box = page.genres orelse return;
    const library = self.library orelse return;
    while (gtk.gtk_widget_get_first_child(box)) |child| gtk.gtk_box_remove(gtk.cast(gtk.Box, box), child);
    const genres = self.runtime.libraryArtistGenres(library, page.artist_id, 3) catch {
        gtk.gtk_widget_set_visible(box, gtk.false_);
        return;
    };
    defer genres.deinit();
    var buffer: [256]u8 = undefined;
    for (genres.items, 0..) |genre, index| {
        if (index != 0) {
            const separator = gtk.gtk_label_new("•");
            gtk.gtk_widget_add_css_class(separator, "artist-genre-separator");
            gtk.gtk_box_append(gtk.cast(gtk.Box, box), separator);
        }
        const label = gtk.gtk_label_new(strings.terminated(&buffer, genre.name).ptr);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_add_css_class(label, "artist-genre");
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), label);
    }
    gtk.gtk_widget_set_visible(box, @intFromBool(genres.items.len != 0));
}

fn showPhoto(page: *ArtistPage) void {
    const self = page.self;
    const photo = page.photo orelse return;
    art.showArtist(self, photo, page.artist_id, .unknown, mostPlayedRelease(self, page.artist_id), .tile);
}

fn showInfo(page: *ArtistPage) bool {
    const self = page.self;
    showPhoto(page);
    showGenres(page);
    showRelated(page);
    const library = self.library orelse return true;
    var stored = (self.runtime.libraryArtistInfo(library, page.artist_id) catch return true) orelse {
        if (page.biography) |biography| gtk.gtk_widget_set_visible(biography, gtk.false_);
        if (page.credit) |credit| gtk.gtk_widget_set_visible(credit, gtk.false_);
        return false;
    };
    defer stored.deinit();
    const record = stored.record;

    const text = std.mem.trim(u8, record.biography orelse "", " \n");
    if (page.biography) |biography| gtk.gtk_widget_set_visible(biography, @intFromBool(text.len != 0));
    if (text.len != 0) if (page.biography_label) |label| {
        const owned = self.allocator.dupeZ(u8, text) catch return true;
        defer self.allocator.free(owned);
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), owned.ptr);
    };

    if (page.listeners) |listeners| {
        gtk.gtk_widget_set_visible(listeners, @intFromBool(record.listeners != null));
        if (record.listeners) |count| {
            var buffer: [32]u8 = undefined;
            if (page.listeners_number) |number| gtk.gtk_label_set_text(number, compactCount(&buffer, count).ptr);
        }
    }

    if (page.credit) |credit| {
        const author = std.mem.trim(u8, record.photo_credit orelse "", " \n");
        const licence = std.mem.trim(u8, record.photo_licence orelse "", " \n");
        const url = record.photo_url orelse "";
        gtk.gtk_widget_set_visible(credit, @intFromBool(author.len != 0 or licence.len != 0));
        var buffer: [512]u8 = undefined;
        const label: [:0]const u8 = if (author.len != 0 and licence.len != 0)
            strings.format(&buffer, "Photo: {s} • {s}", .{ author, licence })
        else
            strings.format(&buffer, "Photo: {s}", .{if (author.len != 0) author else licence});
        if (gtk.gtk_button_get_child(gtk.cast(gtk.Button, credit))) |child|
            gtk.gtk_label_set_text(gtk.cast(gtk.Label, child), label.ptr);
        gtk.gtk_widget_set_sensitive(credit, @intFromBool(url.len != 0));
        if (url.len != 0) gtk.gtk_link_button_set_uri(gtk.cast(gtk.LinkButton, credit), strings.terminated(&buffer, url).ptr);
    }
    return true;
}

fn newPhoto(page: *ArtistPage) *gtk.Widget {
    const self = page.self;
    const photo = art.newCover(self, art.initialsPlaceholder(), photo_width);
    gtk.gtk_widget_add_css_class(photo, "artist-hero-art");
    gtk.gtk_widget_set_halign(photo, gtk.ALIGN_FILL);
    gtk.gtk_widget_set_valign(photo, gtk.ALIGN_FILL);
    art.setInitials(photo, page.name);
    page.photo = photo;
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "artist-hero-photo");
    gtk.gtk_widget_set_size_request(frame, photo_width, photo_height);
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(frame, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(frame, gtk.ALIGN_START);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), photo);
    const fitted = gtk.gtk_picture_new();
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, fitted), gtk.CONTENT_FIT_COVER);
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, fitted), gtk.true_);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), fitted);
    if (gtk.gtk_stack_get_child_by_name(gtk.cast(gtk.Stack, photo), "art")) |image| {
        _ = gtk.g_signal_connect_object(image, "notify::paintable", gtk.callback(photoPainted), fitted, gtk.CONNECT_SWAPPED);
        photoPainted(fitted, null, image);
    }
    const fade = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(fade, "artist-hero-fade");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), fade);
    gtk.gtk_widget_set_can_target(fitted, gtk.false_);
    gtk.gtk_widget_set_can_target(fade, gtk.false_);
    menu.onSecondaryClick(frame, heroMenu, page);
    return frame;
}

fn photoPainted(picture: ?*anyopaque, _: ?*anyopaque, image: ?*anyopaque) callconv(.c) void {
    const paintable = gtk.gtk_image_get_paintable(gtk.cast(gtk.Image, image.?));
    gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, picture.?), if (paintable) |found| gtk.cast(gtk.GdkPaintable, found) else null);
}

fn newBiography(page: *ArtistPage) *gtk.Widget {
    const label = gtk.gtk_label_new("");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, label), biography_lines);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1000);
    gtk.gtk_widget_add_css_class(label, "artist-biography-text");
    page.biography_label = label;
    const measure = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, measure), biography_max_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, measure), biography_max_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, measure), label);
    const button = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "artist-biography");
    gtk.gtk_widget_set_halign(button, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(button, "Show the full biography");
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), measure);
    gtk.gtk_widget_set_visible(button, gtk.false_);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(biographyClicked), page);
    page.biography = button;
    return button;
}

pub fn openArtist(self: *App, navigation: *adw.NavigationView, artist_id: i64) void {
    const library = self.library orelse return;
    const artist = (self.runtime.libraryArtist(library, artist_id) catch null) orelse return;
    defer artist.deinit(self.allocator);
    const totals = (self.runtime.libraryArtistTotals(library, artist_id) catch null) orelse return;
    var rows_buffer: [std.meta.fields(albums.ArtistScope).len]ReleaseRow = undefined;
    var row_count: usize = 0;
    defer for (rows_buffer[0..row_count]) |*row| row.releases.deinit();
    var release_total: usize = 0;
    for (std.enums.values(albums.ArtistScope)) |scope| {
        const known: ?u64 = if (scope == .appearances) totals.appearance_count else null;
        var row = loadReleaseRow(self, library, artist_id, scope, known) orelse continue;
        row.first_position = release_total;
        release_total += row.releases.items.len;
        rows_buffer[row_count] = row;
        row_count += 1;
    }
    const rows = rows_buffer[0..row_count];
    var top = self.runtime.libraryTrackQuery(library, "", .{
        .artist_id = artist_id,
        .sort = .play_count,
        .direction = .descending,
        .limit = top_song_limit,
    }) catch return;
    defer top.deinit();
    const by_rating = for (top.items) |item| {
        if (item.play_count != 0) break false;
    } else true;
    if (by_rating) {
        const rated = self.runtime.libraryTrackQuery(library, "", .{
            .artist_id = artist_id,
            .sort = .rating,
            .direction = .descending,
            .limit = top_song_limit,
        }) catch return;
        top.deinit();
        top = rated;
    }
    var tracks = playableTracks(self, library, artist_id);
    defer tracks.deinit(self.allocator);

    const page = self.allocator.create(ArtistPage) catch return;
    page.* = .{
        .self = self,
        .navigation = navigation,
        .artist_id = artist_id,
        .name = undefined,
        .tracks = &.{},
        .releases = &.{},
        .loved = self.runtime.libraryArtistLoved(library, artist_id) catch artist.loved,
    };
    page.name = self.allocator.dupeSentinel(u8, if (artist.name.len != 0) artist.name else "Unknown Artist", 0) catch {
        self.allocator.destroy(page);
        return;
    };
    page.tracks = tracks.toOwnedSlice(self.allocator) catch {
        self.allocator.free(page.name);
        self.allocator.destroy(page);
        return;
    };
    page.releases = self.allocator.alloc(i64, release_total) catch {
        self.allocator.free(page.name);
        self.allocator.free(page.tracks);
        self.allocator.destroy(page);
        return;
    };
    for (rows) |*row| {
        for (row.releases.items, page.releases[row.first_position..][0..row.releases.items.len]) |release, *id| id.* = release.id;
    }

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 32);
    gtk.gtk_widget_add_css_class(content, "artist-page");
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 28);

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(hero, "album-hero");
    gtk.gtk_widget_add_css_class(hero, "artist-hero");
    page.hero = hero;
    const photo_frame = newPhoto(page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), photo_frame);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(facts, "artist-facts");
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const kind = gtk.gtk_label_new("ARTIST");
    gtk.gtk_widget_add_css_class(kind, "album-kind");
    const title = gtk.gtk_label_new(page.name.ptr);
    gtk.gtk_widget_add_css_class(title, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
    gtk.gtk_widget_add_css_class(title, "artist-hero-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    menu.onSecondaryClick(title, heroMenu, page);
    for ([_]*gtk.Widget{ kind, title }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), label);
    }
    const genres = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(genres, "artist-genres");
    page.genres = genres;
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), genres);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), newBiography(page));

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    const play_button = albums.pill("Play", "media-playback-start-symbolic", true);
    const shuffle = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    const heart = feedback.newAlbumButton(gtk.callback(loveClicked), page);
    feedback.showArtistButton(heart, page.loved);
    page.love_button = heart;
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(heroMoreClicked), page);
    for ([_]*gtk.Widget{ play_button, shuffle, heart, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    const stat_column = statColumn(page, totals);
    page.stats = stat_column;
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), stat_column);

    const credit = gtk.gtk_link_button_new_with_label("https://commons.wikimedia.org/", "");
    gtk.gtk_widget_add_css_class(credit, "artist-photo-credit");
    gtk.gtk_widget_set_halign(credit, gtk.ALIGN_END);
    gtk.gtk_widget_set_visible(credit, gtk.false_);
    if (gtk.gtk_button_get_child(gtk.cast(gtk.Button, credit))) |child|
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, child), gtk.ELLIPSIZE_END);
    page.credit = credit;
    const hero_block = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero_block), hero);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero_block), credit);
    gtk.gtk_widget_add_css_class(hero_block, "artist-hero-block");
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), hero_block);

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 40);
    gtk.gtk_widget_add_css_class(sections, "artist-sections");
    page.sections = sections;
    if (top.items.len != 0) gtk.gtk_box_append(gtk.cast(gtk.Box, sections), songsSection(page, top.items, by_rating));
    const side = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 28);
    for (rows) |*row| gtk.gtk_box_append(gtk.cast(gtk.Box, side), albumsSection(page, row));
    gtk.gtk_box_append(gtk.cast(gtk.Box, side), relatedSection(page));
    gtk.gtk_box_append(gtk.cast(gtk.Box, sections), side);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), sections);
    layOut(page);
    if (!showInfo(page) and self.fetch_artist_info) requestInfo(self, artist_id, false);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 1600);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), 1600);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), clamp);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), albums.newBackdrop(page.photo.?));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), column);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), column, gtk.true_);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), layers);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);
    page.scroller = scroller;
    registerPage(page);
    markPlaying(self, self.shown_track_id);

    const pushed = adw.adw_navigation_page_new(scroller, page.name.ptr);
    window.markPushed(pushed, .{ .artist = artist_id });
    adw.adw_navigation_view_push(navigation, pushed);
    _ = gtk.gtk_widget_grab_focus(play_button);
}

pub fn infoPending(self: *const App, artist_id: i64) bool {
    const info = &self.artist_info;
    for (info.pending[0..info.pending_count]) |pending| {
        if (pending.artist_id == artist_id) return true;
    }
    return false;
}

pub fn requestInfo(self: *App, artist_id: i64, force: bool) void {
    const info = &self.artist_info;
    if (info.closed or infoPending(self, artist_id)) return;
    if (!force and info.requested.contains(artist_id)) return;
    if (info.pending_count == info.pending.len) return;
    const library = self.library orelse return;
    info.requested.put(self.allocator, artist_id, {}) catch return;
    const job = self.runtime.startArtistInfoFetch(library, artist_id, .{ .force = force }) catch
        return self.toast("Could not look this artist up");
    info.pending[info.pending_count] = .{ .artist_id = artist_id, .job = job };
    info.pending_count += 1;
}

pub fn tick(self: *App) void {
    const info = &self.artist_info;
    var index: usize = 0;
    while (index < info.pending_count) {
        const pending = info.pending[index];
        if (self.runtime.jobSnapshotSynced(pending.job)) |snapshot| switch (snapshot.state) {
            .succeeded, .failed, .cancelled => {},
            else => {
                index += 1;
                continue;
            },
        } else |_| {}
        info.pending_count -= 1;
        info.pending[index] = info.pending[info.pending_count];
        art.refreshArtist(self, pending.artist_id);
        for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
            if (page.artist_id == pending.artist_id) _ = showInfo(page);
        }
        details.artistInfoChanged(self, pending.artist_id);
    }
}

pub fn shutdown(self: *App) void {
    const info = &self.artist_info;
    info.closed = true;
    for (info.pending[0..info.pending_count]) |pending| self.runtime.cancelJob(pending.job) catch {};
    info.pending_count = 0;
}
