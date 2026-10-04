//! The Artists page: every Artist, or only those a Release is filed under, as
//! a grid of photos or a list, sorted and searchable. `artist_page.zig` holds
//! the page each one opens.

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
const menu = @import("menu.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const artist_page = @import("artist_page.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const thumb_pixels: c_int = 40;
const min_tile_pixels: c_int = 132;
const grid_min_columns = 2;
const pending_info_limit = 8;
const fallback_note = "No artist photo? Orca uses artwork from one of their albums, then a monochrome monogram.";

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.ArtistSort }{
    .{ .label = "Name", .sort = .name },
    .{ .label = "Most tracks", .sort = .track_count },
    .{ .label = "Recently loved", .sort = .recently_loved },
    .{ .label = "Recently added", .sort = .recently_added },
};

const roles = [_]struct { label: [*:0]const u8, role: liborca.ArtistRole }{
    .{ .label = "All artists", .role = .all },
    .{ .label = "Album artists", .role = .album_artists },
};

/// Artist info fetches: each Artist is asked about at most once a session
/// unless the user asks again, and the jobs still running are polled from
/// `tick`. `role` is which Artists the Artists page lists.
pub const Info = struct {
    requested: std.AutoHashMapUnmanaged(i64, void) = .empty,
    pending: [pending_info_limit]Pending = undefined,
    pending_count: usize = 0,
    closed: bool = false,
    role: liborca.ArtistRole = .album_artists,

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
    const playing = albums.playingBadge();
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), playing);
    const name = centredLabel("artist-tile-name");
    const detail = centredLabel("artist-tile-meta");
    gtk.gtk_widget_add_css_class(detail, "numeric");
    for ([_]*gtk.Widget{ frame, name, detail }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    gtk.g_object_set_data(tile, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-playing", playing);
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
    const count = artist.artist().release_count;
    var buffer: [32]u8 = undefined;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), strings.printZ(&buffer, "{d} {s}", .{
        count,
        if (count == 1) "album" else "albums",
    }) catch "");
    art.setInitials(cover, artist.name());
    albums.showPlaying(tile, self.playing().matches(.artist, artist.id()));
    showFace(self, cover, artist, tileArtSize(self));
}

fn tileArtSize(self: *App) art.Size {
    return albums.coverArtSize(if (self.artist_grid) |grid| gtk.cast(gtk.Widget, grid) else null, self.artist_tile_pixels);
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
    albums.showPlaying(row, self.playing().matches(.artist, artist.id()));
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

pub fn mostPlayedRelease(self: *App, artist_id: i64) ?i64 {
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
        .role = self.artist_info.role,
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
        var buffer: [64]u8 = undefined;
        gtk.gtk_label_set_text(meta, strings.printZ(&buffer, "{d} {s}{s}", .{
            total,
            if (total == 1) "artist" else "artists",
            if (self.artist_info.role == .album_artists) " \u{00B7} album artists only" else "",
        }) catch "");
    }
    if (self.artists_empty) |empty| {
        const searching = self.artist_list_filter.value.len != 0;
        adw.adw_status_page_set_title(empty, if (searching) "No matching artists" else "No artists yet");
        adw.adw_status_page_set_description(empty, if (searching) "Try another search." else "Add a music folder in Settings › Library.");
    }
    if (self.artists_body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else @tagName(self.artist_layout));
    loadNextPage(self);
}

pub fn reloadKeepingScroll(self: *App) void {
    const scroll = page_ui.visibleScroll(self.artists_body);
    const loaded = self.artist_list_loaded;
    reload(self);
    while (!self.artist_list_exhausted and self.artist_list_loaded < loaded) {
        const before = self.artist_list_loaded;
        loadNextPage(self);
        if (self.artist_list_loaded == before) break;
    }
    if (scroll) |kept| page_ui.restoreScroll(self, kept);
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
            .release_count = artist.release_count,
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

fn activated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.artist_list_store orelse return;
    const id = albums.releaseAt(store, position) orelse return;
    const navigation = self.artists_navigation orelse return;
    artist_page.openArtist(self, navigation, id);
}

fn applyGridColumns(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.artist_grid_idle = 0;
    const grid = self.artist_grid orelse return gtk.SOURCE_REMOVE;
    gtk.gtk_grid_view_set_min_columns(grid, self.artist_grid_columns);
    gtk.gtk_grid_view_set_max_columns(grid, self.artist_grid_columns);
    const size = tileArtSize(self);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, grid));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        const tile = gtk.gtk_widget_get_first_child(cell) orelse continue;
        albums.sizeTile(tile, self.artist_tile_pixels);
        resizeFace(self, tile, size);
    }
    return gtk.SOURCE_REMOVE;
}

fn resizeFace(self: *App, tile: *gtk.Widget, size: art.Size) void {
    const item = gtk.g_object_get_data(tile, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const cover = part(tile, "orca-cover") orelse return;
    showFace(self, cover, @ptrCast(@alignCast(object)), size);
}

fn gridDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.artist_grid_idle != 0) _ = gtk.g_source_remove(self.artist_grid_idle);
    self.artist_grid_idle = 0;
    self.artist_grid = null;
}

fn gridResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    const columns = albums.gridColumns(width, min_tile_pixels);
    const pixels = albums.gridTilePixels(width, columns);
    if (columns == self.artist_grid_columns and pixels == self.artist_tile_pixels) return;
    self.artist_grid_columns = columns;
    self.artist_tile_pixels = pixels;
    if (self.artist_grid_idle == 0) self.artist_grid_idle = gtk.g_idle_add(applyGridColumns, self);
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

fn footerFollows(adjustment: ?*anyopaque, footer: ?*anyopaque) callconv(.c) void {
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + gtk.gtk_adjustment_get_page_size(value));
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, footer.?), if (remaining < 1) gtk.true_ else gtk.false_);
}

fn withFallbackNote(scroller: *gtk.Widget) *gtk.Widget {
    const note = gtk.gtk_label_new(fallback_note);
    gtk.gtk_widget_add_css_class(note, "artists-note");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, note), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note), gtk.true_);
    gtk.gtk_widget_set_valign(note, gtk.ALIGN_END);
    gtk.gtk_widget_set_can_target(note, gtk.false_);
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
    for ([_][*:0]const u8{ "value-changed", "changed" }) |signal|
        _ = gtk.g_signal_connect_object(adjustment, signal, gtk.callback(footerFollows), note, 0);
    const overlay = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, overlay), scroller);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), note);
    return overlay;
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
    albums.watchView(self, grid, .artist);
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
    albums.watchView(self, list, .artist);
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

fn roleChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.artists_syncing_controls) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= roles.len) return;
    if (roles[selected].role == self.artist_info.role) return;
    self.artist_info.role = roles[selected].role;
    settings.save(self);
    reload(self);
}

fn newRoleControl(self: *App) *gtk.Widget {
    var labels: [roles.len + 1]?[*:0]const u8 = undefined;
    for (roles, 0..) |entry, index| labels[index] = entry.label;
    labels[roles.len] = null;
    const control = gtk.gtk_drop_down_new_from_strings(&labels);
    gtk.gtk_widget_set_tooltip_text(control, "Which artists to show");
    gtk.gtk_widget_add_css_class(control, "btn-dropdown");
    gtk.gtk_widget_set_valign(control, gtk.ALIGN_CENTER);
    for (roles, 0..) |entry, index| {
        if (entry.role == self.artist_info.role) gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, control), @intCast(index));
    }
    _ = gtk.signalConnect(control, "notify::selected", gtk.callback(roleChanged), self);
    return control;
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
    gtk.gtk_widget_add_css_class(box, "segmented");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    const choices = [_]struct { layout: albums.Layout, icon: [*:0]const u8, tooltip: [*:0]const u8 }{
        .{ .layout = .grid, .icon = "orca-grid-symbolic", .tooltip = "Grid view" },
        .{ .layout = .list, .icon = "orca-list-symbolic", .tooltip = "List view" },
    };
    var group: ?*gtk.ToggleButton = null;
    for (choices) |choice| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), choice.icon);
        gtk.gtk_widget_set_tooltip_text(button, choice.tooltip);
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, choice.tooltip, @as(c_int, -1));
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
    _ = gtk.signalConnect(grid, "destroy", gtk.callback(gridDestroyed), self);
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
    _ = gtk.gtk_stack_add_named(self.artists_body.?, withFallbackNote(grid_scroller), "grid");
    _ = gtk.gtk_stack_add_named(self.artists_body.?, withFallbackNote(list_scroller), "list");
    _ = gtk.gtk_stack_add_named(self.artists_body.?, empty, "empty");
    gtk.gtk_widget_set_vexpand(body, gtk.true_);

    const title = page_ui.title("Artists");
    self.artist_list_meta = title.meta;
    var labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| labels[index] = entry.label;
    labels[sorts.len] = null;
    const sort_label = gtk.gtk_label_new("Sort by");
    gtk.gtk_widget_add_css_class(sort_label, "sort-label");
    gtk.gtk_widget_set_valign(sort_label, gtk.ALIGN_CENTER);
    const sort = gtk.gtk_drop_down_new_from_strings(&labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort artists");
    gtk.gtk_widget_add_css_class(sort, "btn-dropdown");
    gtk.gtk_widget_set_valign(sort, gtk.ALIGN_CENTER);
    self.artist_sort_control = gtk.cast(gtk.DropDown, sort);
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    adw.adw_wrap_box_set_child_spacing(title.end, 10);
    title.add(sort_label);
    title.add(sort);
    title.add(newRoleControl(self));
    title.add(newLayoutSwitch(self));
    syncControls(self);
    gtk.gtk_stack_set_visible_child_name(self.artists_body.?, @tagName(self.artist_layout));
    const view = page_ui.withTitle(title, body);

    const navigation = adw.adw_navigation_view_new();
    self.artists_navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Artists");
    adw.adw_navigation_page_set_tag(root, "artists");
    adw.adw_navigation_view_add(self.artists_navigation.?, root);
    return navigation;
}
