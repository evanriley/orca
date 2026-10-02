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
const page_ui = @import("page.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const ratings = @import("ratings.zig");
const artists = @import("artists.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const tile_pixels: c_int = 148;
const hero_pixels: c_int = 260;
const backdrop_height: c_int = 440;
const number_column_pixels: c_int = 28;
const duration_column_pixels: c_int = 44;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.ReleaseSort }{
    .{ .label = "Artist", .sort = .artist },
    .{ .label = "Title", .sort = .title },
    .{ .label = "Year", .sort = .year },
    .{ .label = "Recently Added", .sort = .recently_added },
};

const Chip = enum { all, recently_added, loved };

const chip_labels = std.enums.EnumArray(Chip, [*:0]const u8).init(.{
    .all = "All Albums",
    .recently_added = "Recently Added",
    .loved = "Loved",
});

fn tilePart(tile: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    const part = gtk.g_object_get_data(tile, key) orelse return null;
    return gtk.cast(gtk.Widget, part);
}

fn tileLabel(text: ?[*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn setupTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(tile, tile_pixels, -1);

    const cover = art.newCover(self, art.initialsPlaceholder(), tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    const play = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    gtk.gtk_widget_add_css_class(play, "tile-play");
    gtk.gtk_widget_add_css_class(play, "tile-action");
    gtk.gtk_widget_add_css_class(play, "circular");
    gtk.gtk_widget_set_halign(play, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(play, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(play, "Play Album");
    _ = gtk.signalConnect(play, "clicked", gtk.callback(tilePlayClicked), self);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "album-cover-frame");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), play);

    const title = tileLabel(null, "tile-title");
    const artist = tileLabel(null, "tile-artist");
    gtk.gtk_widget_set_hexpand(artist, gtk.true_);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "tile-more");
    gtk.gtk_widget_add_css_class(more, "tile-action");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(tileMoreClicked), self);
    const byline = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, byline), artist);
    gtk.gtk_box_append(gtk.cast(gtk.Box, byline), more);
    const year = tileLabel(null, "tile-year");
    gtk.gtk_widget_add_css_class(year, "numeric");

    for ([_]*gtk.Widget{ frame, title, byline, year }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), part);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    for ([_]*gtk.Widget{ tile, play, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-cover", cover);
    gtk.g_object_set_data(tile, "orca-title", title);
    gtk.g_object_set_data(tile, "orca-artist", artist);
    gtk.g_object_set_data(tile, "orca-year", year);
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
        self.context.release_loved = release.loved;
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

fn tileRelease(widget: *gtk.Widget) ?i64 {
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    return row.id();
}

fn tileMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = menu.gestureWidget(gesture);
    const id = tileRelease(tile) orelse return;
    if (setAlbumContext(self, id)) menu.popup(self, tile, x, y);
}

pub fn popupBelow(self: *App, widget: *gtk.Widget) void {
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popup(self, widget, x, y);
}

fn tileMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const id = tileRelease(widget) orelse return;
    if (setAlbumContext(self, id)) popupBelow(self, widget);
}

pub fn playRelease(self: *App, release_id: i64) void {
    if (!setAlbumContext(self, release_id)) return;
    self.runtime.playerSetShuffle(self.player, false) catch {};
    menu.play(self);
}

fn tilePlayClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const id = tileRelease(gtk.cast(gtk.Widget, button.?)) orelse return;
    playRelease(self, id);
}

fn bindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    const tile = gtk.gtk_list_item_get_child(list_item) orelse return;
    const cover = tilePart(tile, "orca-cover") orelse return;
    const title = tilePart(tile, "orca-title") orelse return;
    const artist = tilePart(tile, "orca-artist") orelse return;
    const year = tilePart(tile, "orca-year") orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), if (row.name().len != 0) row.name().ptr else "Untitled");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), row.detail().ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, year), row.caption().ptr);
    art.setInitials(cover, row.name());
    const id = row.id() orelse return;
    art.show(self, cover, art.Key.release(id, .tile));
}

fn unbindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const cover = tilePart(tile, "orca-cover") orelse return;
    art.forget(self, cover);
}

fn request(self: *App, offset: u32) liborca.ReleaseQuery {
    return .{
        .sort = self.album_sort,
        .loved_only = self.album_loved_only,
        .limit = app.page_size,
        .offset = offset,
    };
}

pub fn reload(self: *App) void {
    const store = self.album_store orelse return;
    gtk.g_list_store_remove_all(store);
    self.albums_loaded = 0;
    self.albums_exhausted = false;
    const library = self.library orelse return;
    const total = self.runtime.libraryReleaseCountMatching(library, request(self, 0)) catch 0;
    if (self.albums_meta) |meta| {
        var buffer: [48]u8 = undefined;
        const text: [:0]const u8 = if (total == 1)
            "1 album"
        else
            strings.printZ(&buffer, "{d} albums", .{total}) catch "";
        gtk.gtk_label_set_text(meta, text.ptr);
    }
    if (self.albums_empty) |empty| {
        adw.adw_status_page_set_title(empty, if (self.album_loved_only) "No loved albums" else "No albums yet");
        adw.adw_status_page_set_description(empty, if (self.album_loved_only)
            "Love an album from its page or its menu."
        else
            "Add a music folder from the main menu.");
    }
    if (self.albums_body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "grid");
    loadNextPage(self);
}

fn loadNextPage(self: *App) void {
    const store = self.album_store orelse return;
    if (self.albums_exhausted) return;
    const loaded = appendReleasePage(self, store, request(self, self.albums_loaded)) orelse {
        self.albums_exhausted = true;
        return;
    };
    if (loaded < app.page_size) self.albums_exhausted = true;
    self.albums_loaded += loaded;
}

fn releaseYear(release: liborca.ReleaseSummary) []const u8 {
    const date = release.release_date orelse return "";
    return date[0..@min(date.len, 4)];
}

pub fn appendReleasePage(self: *App, store: *gtk.ListStore, query: liborca.ReleaseQuery) ?u32 {
    const library = self.library orelse return null;
    var page = self.runtime.libraryReleasePage(library, query) catch return null;
    defer page.deinit();
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    for (page.items) |release| {
        const row = browse_model.newWithCaption(release.id, release.title, release.album_artist, releaseYear(release)) orelse continue;
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
    return @intCast(page.items.len);
}

fn scrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page * 2) loadNextPage(self);
}

fn activeChip(self: *const App) Chip {
    if (self.album_loved_only) return .loved;
    if (self.album_sort == .recently_added) return .recently_added;
    return .all;
}

fn syncControls(self: *App) void {
    self.albums_syncing_controls = true;
    defer self.albums_syncing_controls = false;
    if (self.album_sort_control) |control| {
        for (sorts, 0..) |entry, index| {
            if (entry.sort == self.album_sort) gtk.gtk_drop_down_set_selected(control, @intCast(index));
        }
    }
    const chip = self.album_chips[@intFromEnum(activeChip(self))] orelse return;
    gtk.gtk_toggle_button_set_active(chip, gtk.true_);
}

fn sortChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_syncing_controls) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= sorts.len) return;
    if (sorts[selected].sort == self.album_sort) return;
    self.album_sort = sorts[selected].sort;
    if (self.album_sort != .recently_added) self.album_shelf_sort = self.album_sort;
    syncControls(self);
    reload(self);
}

fn chipToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_syncing_controls) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    const chip: Chip = for (self.album_chips, 0..) |candidate, index| {
        if (candidate == toggle) break @enumFromInt(index);
    } else return;
    switch (chip) {
        .all => {
            self.album_loved_only = false;
            if (self.album_sort == .recently_added) self.album_sort = self.album_shelf_sort;
        },
        .recently_added => {
            self.album_loved_only = false;
            self.album_sort = .recently_added;
        },
        .loved => self.album_loved_only = true,
    }
    syncControls(self);
    reload(self);
}

fn newChips(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(row, "album-chips");
    var group: ?*gtk.ToggleButton = null;
    for (std.enums.values(Chip)) |chip| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), chip_labels.get(chip));
        gtk.gtk_widget_add_css_class(button, "album-chip");
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        self.album_chips[@intFromEnum(chip)] = toggle;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(chipToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
    }
    return row;
}

fn tileActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.album_store orelse return;
    const id = releaseAt(store, position) orelse return;
    const navigation = self.albums_navigation orelse return;
    openAlbum(self, navigation, id);
}

pub fn newGrid(self: *App, store: *gtk.ListStore, activated: gtk.GCallback) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupTile), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindTile), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const grid = gtk.gtk_grid_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 2);
    gtk.gtk_grid_view_set_tab_behavior(gtk.cast(gtk.GridView, grid), gtk.LIST_TAB_ITEM);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", activated, self);
    return grid;
}

pub fn releaseAt(store: *gtk.ListStore, position: c_uint) ?i64 {
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return null;
    defer gtk.g_object_unref(item);
    const row: *BrowseObject = @ptrCast(@alignCast(item));
    return row.id();
}

pub fn build(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.album_store = store;
    const grid = newGrid(self, store, gtk.callback(tileActivated));
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
    self.albums_empty = gtk.cast(adw.StatusPage, empty);
    adw.adw_status_page_set_icon_name(self.albums_empty.?, "media-optical-symbolic");
    adw.adw_status_page_set_title(self.albums_empty.?, "No albums yet");
    adw.adw_status_page_set_description(self.albums_empty.?, "Add a music folder from the main menu.");
    const body = gtk.gtk_stack_new();
    self.albums_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.albums_body.?, scroller, "grid");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, empty, "empty");
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    const listing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), newChips(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), body);

    const header = page_ui.header();
    const title = page_ui.title("Albums");
    self.albums_meta = title.meta;
    var labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| labels[index] = entry.label;
    labels[sorts.len] = null;
    const sort_label = gtk.gtk_label_new("Sort by");
    gtk.gtk_widget_add_css_class(sort_label, "meta");
    gtk.gtk_widget_set_valign(sort_label, gtk.ALIGN_CENTER);
    const sort = gtk.gtk_drop_down_new_from_strings(&labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort albums");
    gtk.gtk_widget_add_css_class(sort, "sort-dropdown");
    self.album_sort_control = gtk.cast(gtk.DropDown, sort);
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    title.add(sort_label);
    title.add(sort);
    syncControls(self);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), page_ui.withTitle(title, listing));

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
    loved: bool,
    love_button: ?*gtk.Widget = null,
    hero: ?*gtk.Widget = null,
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
        const playing = track_id == id;
        if (playing)
            gtk.gtk_widget_add_css_class(row, "now-playing")
        else
            gtk.gtk_widget_remove_css_class(row, "now-playing");
        const number = gtk.g_object_get_data(row, "orca-number") orelse continue;
        gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, number), if (playing) "playing" else "number");
    }
}

fn layOutHero(page: *AlbumPage) void {
    const hero = page.hero orelse return;
    gtk.gtk_orientable_set_orientation(
        gtk.cast(gtk.Orientable, hero),
        if (page.self.window_narrow) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL,
    );
}

pub fn setNarrow(self: *App) void {
    for (self.open_album_pages[0..self.open_album_page_count]) |page| layOutHero(page);
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

pub fn setReleaseLove(self: *App, release_id: i64, release_loved: bool) void {
    const library = self.library orelse return;
    const result = self.runtime.librarySetReleaseLove(library, &.{release_id}, release_loved) catch
        return self.toast("Could not save that");
    if (result.skipped != 0) return self.toast("That album is no longer in the library");
    for (self.open_album_pages[0..self.open_album_page_count]) |page| {
        if (page.release_id != release_id) continue;
        page.loved = release_loved;
        if (page.love_button) |button| feedback.showAlbumButton(button, release_loved);
    }
}

fn albumHeartClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    setReleaseLove(page.self, page.release_id, !page.loved);
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    for (self.open_album_pages[0..self.open_album_page_count]) |page| markRows(page, track_id);
}

fn heroMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setAlbumContext(page.self, page.release_id)) menu.popup(page.self, menu.gestureWidget(gesture), x, y);
}

fn heroMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (setAlbumContext(page.self, page.release_id)) popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn rowPosition(row: *gtk.Widget) ?usize {
    const name = gtk.gtk_widget_get_name(row);
    return std.fmt.parseInt(usize, std.mem.span(name), 10) catch null;
}

fn setTrackContext(page: *AlbumPage, position: usize) bool {
    if (position >= page.ids.len) return false;
    const self = page.self;
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, page.ids[position], page.songs[position].recording_id, page.songs[position].feedback) catch return false;
    self.context.release_id = page.release_id;
    self.context.artist_id = page.artists[position] orelse page.album_artist_id;
    return true;
}

fn trackMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const row = menu.gestureWidget(gesture);
    const position = rowPosition(row) orelse return;
    if (setTrackContext(page, position)) menu.popup(page.self, row, x, y);
}

fn trackMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-position"));
    if (marked == 0) return;
    if (setTrackContext(page, marked - 1)) popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
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
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number_label), 1.0);
    gtk.gtk_widget_add_css_class(number_label, "numeric");
    gtk.gtk_widget_add_css_class(number_label, "album-track-number");
    const playing_glyph = gtk.gtk_image_new_from_icon_name("media-playback-start-symbolic");
    gtk.gtk_widget_set_halign(playing_glyph, gtk.ALIGN_END);
    gtk.gtk_widget_add_css_class(playing_glyph, "album-track-playing");
    const number_column = gtk.gtk_stack_new();
    gtk.gtk_widget_set_size_request(number_column, number_column_pixels, -1);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, number_column), number_label, "number");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, number_column), playing_glyph, "playing");
    gtk.g_object_set_data(row, "orca-number", number_column);

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
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration_label), 1.0);
    gtk.gtk_widget_set_size_request(duration_label, duration_column_pixels, -1);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "dim-label");
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    gtk.g_object_set_data(more, "orca-position", @ptrFromInt(position + 1));
    _ = gtk.signalConnect(more, "clicked", gtk.callback(trackMoreClicked), page);

    gtk.gtk_box_append(gtk.cast(gtk.Box, box), number_column);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), more);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), duration_label);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) {
        gtk.gtk_widget_set_sensitive(row, gtk.false_);
    }
    return row;
}

fn trackHeader() *gtk.Widget {
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(header, "album-tracks-header");
    const number = gtk.gtk_label_new("#");
    gtk.gtk_widget_set_size_request(number, number_column_pixels, -1);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 1.0);
    const title = gtk.gtk_label_new("TITLE");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const duration = gtk.gtk_image_new_from_icon_name("document-open-recent-symbolic");
    gtk.gtk_widget_set_tooltip_text(duration, "Duration");
    gtk.gtk_widget_set_halign(duration, gtk.ALIGN_END);
    for ([_]*gtk.Widget{ number, title, duration }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, header), part);
    return header;
}

fn coverPainted(picture: ?*anyopaque, _: ?*anyopaque, image: ?*anyopaque) callconv(.c) void {
    const paintable = gtk.gtk_image_get_paintable(gtk.cast(gtk.Image, image.?));
    const backdrop = if (paintable) |texture| art.blurredBackdrop(std.heap.smp_allocator, gtk.cast(gtk.GdkTexture, texture)) else null;
    defer if (backdrop) |texture| gtk.g_object_unref(texture);
    gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, picture.?), if (backdrop) |texture| gtk.cast(gtk.GdkPaintable, texture) else null);
}

pub fn newBackdrop(cover: *gtk.Widget) *gtk.Widget {
    const band = adw.adw_clamp_new();
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, band), gtk.ORIENTATION_VERTICAL);
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, band), backdrop_height);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, band), backdrop_height);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, band), newBackdropLayers(cover));
    gtk.gtk_widget_set_valign(band, gtk.ALIGN_START);
    gtk.gtk_widget_set_can_target(band, gtk.false_);
    return band;
}

pub fn newBackdropLayers(cover: *gtk.Widget) *gtk.Widget {
    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, picture), gtk.CONTENT_FIT_COVER);
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, picture), gtk.true_);
    gtk.gtk_widget_add_css_class(picture, "album-backdrop-art");
    if (gtk.gtk_stack_get_child_by_name(gtk.cast(gtk.Stack, cover), "art")) |image| {
        _ = gtk.g_signal_connect_object(image, "notify::paintable", gtk.callback(coverPainted), picture, gtk.CONNECT_SWAPPED);
        coverPainted(picture, null, image);
    }
    const fade = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(fade, "album-backdrop-fade");
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(layers, "album-backdrop");
    gtk.gtk_widget_set_overflow(layers, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), picture);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), fade);
    gtk.gtk_widget_set_can_target(layers, gtk.false_);
    return layers;
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
        .loved = release.loved,
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

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 28);
    gtk.gtk_widget_add_css_class(content, "album-page");
    gtk.gtk_widget_add_css_class(content, "album-detail");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(hero, "album-hero");
    page.hero = hero;
    const cover = art.newCover(self, art.initialsPlaceholder(), hero_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    gtk.gtk_widget_add_css_class(cover, "hero-cover");
    gtk.gtk_widget_set_halign(cover, gtk.ALIGN_START);
    menu.onSecondaryClick(cover, heroMenu, page);
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release_id, .tile));
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), cover);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    var buffer: [512]u8 = undefined;
    const kind = gtk.gtk_label_new(if (release.is_compilation) "COMPILATION" else "ALBUM");
    gtk.gtk_widget_add_css_class(kind, "album-kind");
    const title = gtk.gtk_label_new(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr);
    gtk.gtk_widget_add_css_class(title, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
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
    const year = releaseYear(release);
    const meta_text = if (year.len != 0)
        strings.printZ(&buffer, "{s} · {s} · {d} min", .{ year, songs, minutes }) catch ""
    else
        strings.printZ(&buffer, "{s} · {d} min", .{ songs, minutes }) catch "";
    const meta = gtk.gtk_label_new(meta_text.ptr);
    gtk.gtk_widget_add_css_class(meta, "album-meta");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, kind), 0.0);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0.0);
    for ([_]*gtk.Widget{ kind, title, artist, meta }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, facts), widget);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    const play = pill("Play", "media-playback-start-symbolic", true);
    const shuffle = pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    const heart = feedback.newAlbumButton(gtk.callback(albumHeartClicked), page);
    feedback.showAlbumButton(heart, release.loved);
    page.love_button = heart;
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(heroMoreClicked), page);
    for ([_]*gtk.Widget{ play, shuffle, heart, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), hero);
    layOutHero(page);

    const listing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), trackHeader());
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
                gtk.gtk_widget_add_css_class(heading, "album-disc");
                gtk.gtk_box_append(gtk.cast(gtk.Box, listing), heading);
            }
            const box = gtk.gtk_list_box_new();
            gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, box), gtk.SELECTION_SINGLE);
            gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, box), gtk.false_);
            gtk.gtk_widget_add_css_class(box, "album-tracks");
            _ = gtk.signalConnect(box, "row-selected", gtk.callback(trackSelected), page);
            _ = gtk.signalConnect(box, "row-activated", gtk.callback(trackActivated), page);
            page.disc_lists.append(self.allocator, box) catch {};
            gtk.gtk_box_append(gtk.cast(gtk.Box, listing), box);
            list = box;
        }
        const row = trackRow(page, summary, release.album_artist, position) orelse continue;
        menu.onSecondaryClick(row, trackMenu, page);
        gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list.?), row);
        page.rows[position] = row;
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), listing);
    markRows(page, self.shown_track_id);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 1040);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), newBackdrop(cover));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), clamp);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), clamp, gtk.true_);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), layers);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);
    registerPage(page);

    const title_text = strings.printZ(&buffer, "{s}", .{if (release.title.len != 0) release.title else "Album"}) catch "Album";
    const header = page_ui.pushedHeader(navigation, title_text.ptr);
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    const beside = details.besideContent(self, header, scroller, .{ .ids = page.ids });
    page.details = beside.panel;
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), beside.widget);
    adw.adw_navigation_view_push(navigation, adw.adw_navigation_page_new(view, title_text.ptr));
    _ = gtk.gtk_widget_grab_focus(play);
}
