//! The Albums page: a grid of covers, and a page for each album.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
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
const album_filters = @import("album_filters.zig");
const signal_path = @import("signal_path.zig");
const window = @import("window.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const list_cover_pixels: c_int = 32;
const hero_pixels: c_int = 260;
const backdrop_height: c_int = 440;
const number_column_pixels: c_int = 28;
const duration_column_pixels: c_int = 44;
const format_column_pixels: c_int = 96;
const rate_column_pixels: c_int = 64;
const stars_column_pixels: c_int = 96;
const grid_padding_pixels = 36;
const grid_cell_padding_pixels = 17;
const grid_min_columns = 2;
const min_tile_pixels = 72;
const description_max_pixels = 520;
const description_lines = 3;
const pending_info_limit = 8;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.ReleaseSort }{
    .{ .label = "Artist", .sort = .artist },
    .{ .label = "Title", .sort = .title },
    .{ .label = "Year", .sort = .year },
    .{ .label = "Recently Added", .sort = .recently_added },
};

pub const Chip = enum { all, recently_added, loved, high_resolution, needs_review };

pub const ArtistScope = enum { albums, eps_and_singles, appearances };

pub const ArtistFilter = struct {
    artist_id: i64,
    scope: ArtistScope,
};

const artist_scope_labels = std.enums.EnumArray(ArtistScope, []const u8).init(.{
    .albums = "Albums",
    .eps_and_singles = "EPs & Singles",
    .appearances = "Appearances",
});

const chip_labels = std.enums.EnumArray(Chip, [*:0]const u8).init(.{
    .all = "All Albums",
    .recently_added = "Recently Added",
    .loved = "Loved",
    .high_resolution = "High Resolution",
    .needs_review = "Needs Review",
});

/// Which Releases the page lists; Recently Added is an order, not a shelf.
pub const Shelf = enum { all, loved, high_resolution, needs_review };

pub const Layout = enum { grid, list };

/// The optional columns of an album page's track list; `[view]
/// album_columns` keeps which are shown.
pub const Column = enum { rating, format, sample_rate };
pub const ColumnSet = std.EnumSet(Column);

const column_labels = std.enums.EnumArray(Column, [*:0]const u8).init(.{
    .rating = "Rating",
    .format = "Format",
    .sample_rate = "Sample Rate",
});

const column_keys = std.enums.EnumArray(Column, [*:0]const u8).init(.{
    .rating = "orca-column-rating",
    .format = "orca-column-format",
    .sample_rate = "orca-column-sample-rate",
});

/// `rating,format` as settings keep it; names it does not know are skipped.
pub fn parseColumns(text: []const u8) ColumnSet {
    var result: ColumnSet = .initEmpty();
    var names = std.mem.splitScalar(u8, text, ',');
    while (names.next()) |name| {
        const column = std.meta.stringToEnum(Column, std.mem.trim(u8, name, " ")) orelse continue;
        result.insert(column);
    }
    return result;
}

pub fn formatColumns(buffer: []u8, columns: ColumnSet) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var first = true;
    for (std.enums.values(Column)) |column| {
        if (!columns.contains(column)) continue;
        writer.print("{s}{s}", .{ if (first) "" else ",", @tagName(column) }) catch return "";
        first = false;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

/// Release info fetches: each Release is asked about at most once a
/// session, and the jobs still running are polled from `tick`.
pub const Info = struct {
    requested: std.AutoHashMapUnmanaged(i64, void) = .empty,
    pending: [pending_info_limit]Pending = undefined,
    pending_count: usize = 0,
    closed: bool = false,

    const Pending = struct {
        release_id: i64,
        job: liborca.JobHandle,
    };

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        self.requested.deinit(allocator);
    }
};

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
    gtk.gtk_widget_set_size_request(tile, self.album_tile_pixels, -1);

    const cover = art.newCover(self, art.initialsPlaceholder(), self.album_tile_pixels);
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
    const badge = explicitBadge();
    gtk.gtk_widget_set_halign(badge, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_END);
    gtk.gtk_widget_add_css_class(badge, "cover-badge");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), badge);

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
    gtk.g_object_set_data(tile, "orca-explicit", badge);
    menu.onSecondaryClick(tile, tileMenu, self);
}

fn explicitBadge() *gtk.Widget {
    const badge = gtk.gtk_label_new("E");
    gtk.gtk_widget_add_css_class(badge, "explicit-badge");
    gtk.gtk_widget_set_tooltip_text(badge, "Explicit");
    gtk.gtk_widget_set_visible(badge, gtk.false_);
    return badge;
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
    if (tilePart(tile, "orca-explicit")) |badge| gtk.gtk_widget_set_visible(badge, @intFromBool(row.release().explicit));
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

fn listLabel(class: [*:0]const u8, width: c_int, xalign: f32) *gtk.Widget {
    const label = tileLabel(null, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), xalign);
    gtk.gtk_widget_set_size_request(label, width, -1);
    return label;
}

fn setupListRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "album-list-row");
    const cover = art.newCover(self, art.initialsPlaceholder(), list_cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-list-cover");
    gtk.gtk_widget_set_valign(cover, gtk.ALIGN_CENTER);
    const title = tileLabel(null, "album-list-title");
    const badge = explicitBadge();
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_CENTER);
    const title_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_box), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_box), badge);
    const artist = listLabel("album-list-artist", 120, 0);
    const names = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, names), gtk.true_);
    gtk.gtk_widget_set_hexpand(names, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, names), title_box);
    gtk.gtk_box_append(gtk.cast(gtk.Box, names), artist);
    const year = listLabel("album-list-detail", 40, 0);
    const songs = listLabel("album-list-detail", 64, 1);
    const minutes = listLabel("album-list-detail", 56, 1);
    const format = listLabel("album-list-format", format_column_pixels, 0);
    for ([_]*gtk.Widget{ year, songs, minutes }) |label| gtk.gtk_widget_add_css_class(label, "numeric");
    const heart = feedback.newRowButton(gtk.callback(listHeartClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(tileMoreClicked), self);
    for ([_]*gtk.Widget{ cover, names, year, songs, minutes, format, heart, more }) |part|
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), part);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    for ([_]*gtk.Widget{ row, heart, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(row, "orca-cover", cover);
    gtk.g_object_set_data(row, "orca-title", title);
    gtk.g_object_set_data(row, "orca-explicit", badge);
    gtk.g_object_set_data(row, "orca-artist", artist);
    gtk.g_object_set_data(row, "orca-year", year);
    gtk.g_object_set_data(row, "orca-songs", songs);
    gtk.g_object_set_data(row, "orca-minutes", minutes);
    gtk.g_object_set_data(row, "orca-format", format);
    gtk.g_object_set_data(row, "orca-heart", heart);
    menu.onSecondaryClick(row, tileMenu, self);
}

pub fn minutesOf(duration_ms: i64) u64 {
    return @intCast(@divTrunc(@max(duration_ms, 0) + 30_000, 60_000));
}

fn bindListRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    const widget = gtk.gtk_list_item_get_child(list_item) orelse return;
    const release = row.release();
    var buffer: [64]u8 = undefined;
    if (tilePart(widget, "orca-title")) |title|
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), if (row.name().len != 0) row.name().ptr else "Untitled");
    if (tilePart(widget, "orca-explicit")) |badge| gtk.gtk_widget_set_visible(badge, @intFromBool(release.explicit));
    if (tilePart(widget, "orca-artist")) |artist| gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), row.detail().ptr);
    if (tilePart(widget, "orca-year")) |year| gtk.gtk_label_set_text(gtk.cast(gtk.Label, year), row.caption().ptr);
    if (tilePart(widget, "orca-songs")) |songs|
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, songs), strings.format(&buffer, "{d} {s}", .{ release.track_count, if (release.track_count == 1) "song" else "songs" }).ptr);
    if (tilePart(widget, "orca-minutes")) |minutes|
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, minutes), strings.format(&buffer, "{d} min", .{minutesOf(release.duration_ms)}).ptr);
    if (tilePart(widget, "orca-format")) |format| gtk.gtk_label_set_text(gtk.cast(gtk.Label, format), release.format.ptr);
    if (tilePart(widget, "orca-heart")) |heart| feedback.showRowButton(heart, if (release.loved) .loved else .none);
    const cover = tilePart(widget, "orca-cover") orelse return;
    art.setInitials(cover, row.name());
    const id = row.id() orelse return;
    art.show(self, cover, art.Key.release(id, .thumb));
}

fn listHeartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    const id = row.id() orelse return;
    setReleaseLove(self, id, !row.release().loved);
}

fn showListLove(self: *App, release_id: i64, loved: bool) void {
    const store = self.album_store orelse return;
    const model = gtk.cast(gtk.ListModel, store);
    const count = gtk.g_list_model_get_n_items(model);
    var position: c_uint = 0;
    while (position < count) : (position += 1) {
        const item = gtk.g_list_model_get_item(model, position) orelse continue;
        defer gtk.g_object_unref(item);
        const row: *BrowseObject = @ptrCast(@alignCast(item));
        if (row.id() != release_id) continue;
        row.fields().release.loved = loved;
        gtk.g_list_model_items_changed(model, position, 1, 1);
        return;
    }
}

fn shelf(self: *const App) Shelf {
    return self.album_shelf;
}

fn request(self: *App, offset: u32) liborca.ReleaseQuery {
    const filters = self.album_filters;
    const artist_id: ?i64 = if (self.album_artist_filter) |artist| artist.artist_id else null;
    const scope: ?ArtistScope = if (self.album_artist_filter) |artist| artist.scope else null;
    return .{
        .text = self.album_search.value,
        .sort = self.album_sort,
        .album_artist_id = if (scope != .appearances) artist_id else null,
        .appearing_artist_id = if (scope == .appearances) artist_id else null,
        .own_releases_only = scope == .albums or scope == .eps_and_singles,
        .release_kind = if (scope) |chosen| switch (chosen) {
            .albums => .album,
            .eps_and_singles => .ep_or_single,
            .appearances => null,
        } else null,
        .genre_id = filters.genre_id,
        .loved_only = shelf(self) == .loved,
        .high_resolution_only = shelf(self) == .high_resolution,
        .needs_review_only = shelf(self) == .needs_review,
        .lossless_only = filters.lossless_only,
        .year_min = filters.year_from,
        .year_max = filters.year_to,
        .has_artwork = filters.hasArtwork(),
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
        const text = emptyText(self);
        adw.adw_status_page_set_title(empty, text.title);
        adw.adw_status_page_set_description(empty, text.description);
    }
    if (self.albums_body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else @tagName(self.album_layout));
    loadNextPage(self);
}

fn emptyText(self: *const App) struct { title: [*:0]const u8, description: [*:0]const u8 } {
    if (self.album_search.value.len != 0)
        return .{ .title = "No matching albums", .description = "Try another search." };
    if (self.album_filters.count() != 0 or self.album_artist_filter != null)
        return .{ .title = "No matching albums", .description = "Clear the filters to see more albums." };
    return switch (shelf(self)) {
        .all => .{ .title = "No albums yet", .description = "Add a music folder from the main menu." },
        .loved => .{ .title = "No loved albums", .description = "Love an album from its page or its menu." },
        .high_resolution => .{ .title = "No high-resolution albums", .description = "Albums above 16-bit or 48 kHz appear here." },
        .needs_review => .{ .title = "Nothing to review", .description = "Albums with matches waiting for review appear here." },
    };
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

/// `FLAC 16/44.1`, `Mixed` across codecs, or empty when nothing was probed.
pub fn releaseFormat(buffer: []u8, release: *const liborca.ReleaseSummary) [:0]const u8 {
    if (release.codec.len == 0) return "";
    if (std.mem.eql(u8, release.codec, liborca.ReleaseSummary.mixed_codec)) return "Mixed";
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeFormat(&writer, release.codec, release.max_bit_depth, release.max_sample_rate) catch return "";
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

pub fn appendReleasePage(self: *App, store: *gtk.ListStore, query: liborca.ReleaseQuery) ?u32 {
    const library = self.library orelse return null;
    var page = self.runtime.libraryReleasePage(library, query) catch return null;
    defer page.deinit();
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    for (page.items) |*release| {
        var format: [64]u8 = undefined;
        const row = browse_model.newRelease(release.id, release.title, release.album_artist, releaseYear(release.*), releaseFormat(&format, release), .{
            .track_count = release.track_count,
            .duration_ms = release.total_duration_ms,
            .loved = release.loved,
            .explicit = release.explicit == .explicit,
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
    return switch (shelf(self)) {
        .all => if (self.album_sort == .recently_added) .recently_added else .all,
        .loved => .loved,
        .high_resolution => .high_resolution,
        .needs_review => .needs_review,
    };
}

fn syncControls(self: *App) void {
    self.albums_syncing_controls = true;
    defer self.albums_syncing_controls = false;
    if (self.album_sort_control) |control| {
        for (sorts, 0..) |entry, index| {
            if (entry.sort == self.album_sort) gtk.gtk_drop_down_set_selected(control, @intCast(index));
        }
    }
    const active = activeChip(self);
    for (self.album_chips, 0..) |maybe_chip, index| {
        const chip = maybe_chip orelse continue;
        const checked = index == @intFromEnum(active);
        if (checked) gtk.gtk_toggle_button_set_active(chip, gtk.true_);
        gtk.gtk_widget_set_focusable(gtk.cast(gtk.Widget, chip), @intFromBool(checked));
    }
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
    settings.save(self);
    reload(self);
}

pub fn setFilter(self: *App, text: []const u8) void {
    if (std.mem.eql(u8, text, self.album_search.value)) return;
    self.album_search.set(self.allocator, text);
    reload(self);
}

pub fn showGenre(self: *App, genre_id: i64) void {
    self.album_filters = .{ .genre_id = genre_id };
    album_filters.showActive(self);
    self.album_artist_filter = null;
    self.album_artist_name.clear(self.allocator);
    showArtistChip(self);
    window.clearSearch(self);
    self.album_search.clear(self.allocator);
    self.album_shelf = .all;
    if (self.album_sort == .recently_added) self.album_sort = self.album_shelf_sort;
    syncControls(self);
    settings.save(self);
    reload(self);
    window.showPage(self, .albums);
    if (self.albums_navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, "albums");
}

fn showArtistChip(self: *App) void {
    const chip = self.album_artist_chip orelse return;
    const filter = self.album_artist_filter orelse return gtk.gtk_widget_set_visible(chip, gtk.false_);
    const name = self.album_artist_name.value;
    var buffer: [320]u8 = undefined;
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, chip), strings.printZ(&buffer, "{s} \u{2022} {s}  \u{2715}", .{
        if (name.len != 0) name else "Unknown Artist",
        artist_scope_labels.get(filter.scope),
    }) catch "Artist");
    gtk.gtk_widget_set_visible(chip, gtk.true_);
}

fn artistChipClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.album_artist_filter = null;
    self.album_artist_name.clear(self.allocator);
    showArtistChip(self);
    reload(self);
}

pub fn showArtist(self: *App, artist_id: i64, name: []const u8, scope: ArtistScope) void {
    self.album_artist_filter = .{ .artist_id = artist_id, .scope = scope };
    self.album_artist_name.set(self.allocator, name);
    self.album_filters = .{};
    album_filters.showActive(self);
    window.clearSearch(self);
    self.album_search.clear(self.allocator);
    self.album_shelf = .all;
    if (self.album_sort == .recently_added) self.album_sort = self.album_shelf_sort;
    syncControls(self);
    showArtistChip(self);
    settings.save(self);
    reload(self);
    window.showPage(self, .albums);
    if (self.albums_navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, "albums");
}

fn chooseChip(self: *App, chip: Chip) void {
    switch (chip) {
        .all, .recently_added => {
            self.album_shelf = .all;
            if (chip == .recently_added)
                self.album_sort = .recently_added
            else if (self.album_sort == .recently_added)
                self.album_sort = self.album_shelf_sort;
        },
        .loved => self.album_shelf = .loved,
        .high_resolution => self.album_shelf = .high_resolution,
        .needs_review => self.album_shelf = .needs_review,
    }
    syncControls(self);
    settings.save(self);
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
    chooseChip(self, chip);
}

/// Left and Right move between the chips, which are one Tab stop.
fn chipKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    _: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    if (self.album_artist_chip) |chip| {
        if (gtk.gtk_widget_has_focus(chip) != 0) return gtk.false_;
    }
    const step: isize = switch (keyval) {
        gtk.KEY_Left => -1,
        gtk.KEY_Right => 1,
        else => return gtk.false_,
    };
    const count: isize = @intCast(self.album_chips.len);
    const next: usize = @intCast(@mod(@as(isize, @intFromEnum(activeChip(self))) + step, count));
    chooseChip(self, @enumFromInt(next));
    const chip = self.album_chips[next] orelse return gtk.true_;
    _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, chip));
    return gtk.true_;
}

fn newArtistChip(self: *App) *gtk.Widget {
    const chip = gtk.gtk_button_new_with_label("Artist");
    gtk.gtk_widget_add_css_class(chip, "album-chip");
    gtk.gtk_widget_add_css_class(chip, "genre-chip");
    gtk.gtk_widget_set_valign(chip, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(chip, "Show every artist");
    _ = gtk.signalConnect(chip, "clicked", gtk.callback(artistChipClicked), self);
    self.album_artist_chip = chip;
    showArtistChip(self);
    return chip;
}

fn newChips(self: *App) *gtk.Widget {
    const row = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, row), 8);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, row), 8);
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
        adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, row), button);
    }
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, row), newArtistChip(self));
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(chipKeyPressed), self);
    gtk.gtk_widget_add_controller(row, keys);
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
    const grid = gtk.gtk_grid_view_new(newSelection(store), factory);
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 2);
    gtk.gtk_grid_view_set_tab_behavior(gtk.cast(gtk.GridView, grid), gtk.LIST_TAB_ITEM);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", activated, self);
    return grid;
}

pub fn newSelection(store: *gtk.ListStore) *gtk.SelectionModel {
    const selection = gtk.gtk_single_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store)));
    gtk.gtk_single_selection_set_autoselect(selection, gtk.false_);
    gtk.gtk_single_selection_set_can_unselect(selection, gtk.true_);
    return gtk.cast(gtk.SelectionModel, selection);
}

/// The column count whose covers come nearest `tile` once they grow or
/// shrink to fill the row, never fewer than two.
fn gridColumns(width: f64, tile: c_int) c_uint {
    const cell: f64 = @floatFromInt(tile + grid_cell_padding_pixels);
    const fitting = @round((width - grid_padding_pixels) / cell);
    if (!(fitting > grid_min_columns)) return grid_min_columns;
    return @intFromFloat(@min(fitting, 16));
}

fn gridTilePixels(width: f64, columns: c_uint) c_int {
    const cell = @floor((width - grid_padding_pixels) / @as(f64, @floatFromInt(columns)));
    return @intFromFloat(@max(cell - grid_cell_padding_pixels, min_tile_pixels));
}

pub fn sizeTile(tile: *gtk.Widget, pixels: c_int) void {
    const cover: *gtk.Widget = @ptrCast(gtk.g_object_get_data(tile, "orca-cover") orelse return);
    gtk.gtk_widget_set_size_request(tile, pixels, -1);
    gtk.gtk_widget_set_size_request(cover, pixels, pixels);
    const image = gtk.gtk_stack_get_child_by_name(gtk.cast(gtk.Stack, cover), "art") orelse return;
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), pixels);
}

fn applyGridColumns(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const grid = self.album_grid orelse return gtk.false_;
    gtk.gtk_grid_view_set_min_columns(grid, self.album_grid_columns);
    gtk.gtk_grid_view_set_max_columns(grid, self.album_grid_columns);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, grid));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        if (gtk.gtk_widget_get_first_child(cell)) |tile| sizeTile(tile, self.album_tile_pixels);
    }
    return gtk.false_;
}

fn gridResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    const columns = gridColumns(width, self.appearance.album_grid_tile);
    const pixels = gridTilePixels(width, columns);
    if (columns == self.album_grid_columns and pixels == self.album_tile_pixels) return;
    self.album_grid_columns = columns;
    self.album_tile_pixels = pixels;
    _ = gtk.g_idle_add(applyGridColumns, self);
}

pub fn resizeGrid(self: *App) void {
    const grid = self.album_grid orelse return;
    const scroller = gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, grid)) orelse return;
    const adjustment = gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
    if (!(gtk.gtk_adjustment_get_page_size(adjustment) > 0)) return;
    gridResized(adjustment, self);
}

fn newList(self: *App, store: *gtk.ListStore) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupListRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindListRow), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const list = gtk.gtk_list_view_new(newSelection(store), factory);
    gtk.gtk_widget_add_css_class(list, "album-list");
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, list), gtk.LIST_TAB_ITEM);
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, list), gtk.true_);
    _ = gtk.signalConnect(list, "activate", gtk.callback(tileActivated), self);
    return list;
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

fn showLayout(self: *App) void {
    self.albums_syncing_controls = true;
    defer self.albums_syncing_controls = false;
    if (self.album_layout_toggles[@intFromEnum(self.album_layout)]) |toggle|
        gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
    const body = self.albums_body orelse return;
    const visible = gtk.gtk_stack_get_visible_child_name(body) orelse return;
    if (std.mem.eql(u8, std.mem.span(visible), "empty")) return;
    gtk.gtk_stack_set_visible_child_name(body, @tagName(self.album_layout));
}

fn layoutToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_syncing_controls) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    const layout: Layout = for (self.album_layout_toggles, 0..) |candidate, index| {
        if (candidate == toggle) break @enumFromInt(index);
    } else return;
    if (layout == self.album_layout) return;
    self.album_layout = layout;
    showLayout(self);
    settings.save(self);
}

fn newLayoutSwitch(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "linked");
    gtk.gtk_widget_add_css_class(box, "view-switch");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    const choices = [_]struct { layout: Layout, icon: [*:0]const u8, tooltip: [*:0]const u8 }{
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
        self.album_layout_toggles[@intFromEnum(choice.layout)] = toggle;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(layoutToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
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
    self.album_grid = gtk.cast(gtk.GridView, grid);
    const scroller = pagingScroller(self, grid);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "changed",
        gtk.callback(gridResized),
        self,
    );
    const list_scroller = pagingScroller(self, newList(self, store));

    const empty = adw.adw_status_page_new();
    self.albums_empty = gtk.cast(adw.StatusPage, empty);
    adw.adw_status_page_set_icon_name(self.albums_empty.?, "media-optical-symbolic");
    adw.adw_status_page_set_title(self.albums_empty.?, "No albums yet");
    adw.adw_status_page_set_description(self.albums_empty.?, "Add a music folder from the main menu.");
    const body = gtk.gtk_stack_new();
    self.albums_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.albums_body.?, scroller, "grid");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, list_scroller, "list");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, empty, "empty");
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    const listing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), newChips(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), body);

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
    title.add(album_filters.build(self));
    title.add(newLayoutSwitch(self));
    syncControls(self);
    showLayout(self);
    const view = page_ui.withTitle(title, listing);

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
    meta: ?*gtk.Widget = null,
    about: ?*gtk.Widget = null,
    description: ?*gtk.Widget = null,
    more_link: ?*gtk.Widget = null,
    source: ?*gtk.Widget = null,
    licence: ?*gtk.Widget = null,
    scroller: ?*gtk.Widget = null,
    more_pending: bool = false,
    expanded: bool = false,
    column_headers: std.enums.EnumArray(Column, ?*gtk.Widget) = .initFill(null),
};

fn pageData(data: ?*anyopaque) *AlbumPage {
    return @ptrCast(@alignCast(data.?));
}

fn pageDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const allocator = page.self.allocator;
    unregisterPage(page);
    details.forgetIds(page.self, page.ids);
    page.disc_lists.deinit(allocator);
    allocator.free(page.ids);
    allocator.free(page.songs);
    allocator.free(page.artists);
    allocator.free(page.rows);
    allocator.destroy(page);
}

/// What the inspector follows while `pushed`, an album page, shows.
pub fn inspectorSource(self: *App, pushed: *adw.NavigationPage) ?details.Source {
    const child = adw.adw_navigation_page_get_child(pushed) orelse return null;
    for (self.open_album_pages[0..self.open_album_page_count]) |page| {
        if (page.scroller != child) continue;
        return .{ .album = .{ .ids = page.ids, .release_id = page.release_id } };
    }
    return null;
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
        if (page.self.window_narrow or page.self.header_compact) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL,
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
    showListLove(self, release_id, release_loved);
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
    details.choose(page.self, page.ids, page.ids[position]);
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
    gtk.g_object_set_data(row, column_keys.get(.rating), stars);
    var format_buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(format_buffer[0 .. format_buffer.len - 1]);
    if (summary.codec.len != 0) signal_path.writeCodecName(&writer, summary.codec) catch {};
    if (summary.bit_depth) |bits| if (summary.codec.len != 0) writer.print(" {d}-bit", .{bits}) catch {};
    format_buffer[writer.end] = 0;
    const format_label = columnLabel(format_buffer[0..writer.end :0], format_column_pixels);
    gtk.g_object_set_data(row, column_keys.get(.format), format_label);
    writer = std.Io.Writer.fixed(format_buffer[0 .. format_buffer.len - 1]);
    if (summary.sample_rate) |rate| signal_path.writeRate(&writer, rate) catch {};
    format_buffer[writer.end] = 0;
    const rate_label = columnLabel(format_buffer[0..writer.end :0], rate_column_pixels);
    gtk.g_object_set_data(row, column_keys.get(.sample_rate), rate_label);
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const title_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), heart);
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
    gtk.gtk_widget_set_valign(stars, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(stars, stars_column_pixels, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), stars);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), format_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), rate_label);
    showRowColumns(row, page.self.album_columns);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), more);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), duration_label);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) {
        gtk.gtk_widget_set_sensitive(row, gtk.false_);
    }
    return row;
}

fn columnLabel(text: [:0]const u8, width: c_int) *gtk.Widget {
    const label = gtk.gtk_label_new(text.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_size_request(label, width, -1);
    gtk.gtk_widget_add_css_class(label, "album-track-column");
    gtk.gtk_widget_add_css_class(label, "dim-label");
    return label;
}

fn showRowColumns(row: *gtk.Widget, columns: ColumnSet) void {
    for (std.enums.values(Column)) |column| {
        const part = gtk.g_object_get_data(row, column_keys.get(column)) orelse continue;
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, part), @intFromBool(columns.contains(column)));
    }
}

fn showColumns(page: *AlbumPage) void {
    const columns = page.self.album_columns;
    for (std.enums.values(Column)) |column| {
        const heading = page.column_headers.get(column) orelse continue;
        gtk.gtk_widget_set_visible(heading, @intFromBool(columns.contains(column)));
    }
    for (page.rows) |maybe_row| showRowColumns(maybe_row orelse continue, columns);
}

fn columnChosen(action: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const marked = @intFromPtr(gtk.g_object_get_data(action.?, "orca-column"));
    if (marked == 0) return;
    const column: Column = @enumFromInt(marked - 1);
    self.album_columns.toggle(column);
    const shown = self.album_columns.contains(column);
    gtk.g_simple_action_set_state(gtk.cast(gtk.GSimpleAction, action), gtk.g_variant_new_boolean(@intFromBool(shown)));
    for (self.open_album_pages[0..self.open_album_page_count]) |page| showColumns(page);
    settings.save(self);
}

fn columnChooserClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const group = gtk.g_simple_action_group_new();
    defer gtk.g_object_unref(group);
    const items = gtk.g_menu_new();
    defer gtk.g_object_unref(items);
    for (std.enums.values(Column)) |column| {
        const shown = self.album_columns.contains(column);
        const action = gtk.g_simple_action_new_stateful(@tagName(column), null, gtk.g_variant_new_boolean(@intFromBool(shown))) orelse continue;
        gtk.g_object_set_data(action, "orca-column", @ptrFromInt(@as(usize, @intFromEnum(column)) + 1));
        _ = gtk.signalConnect(action, "activate", gtk.callback(columnChosen), self);
        gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
        gtk.g_object_unref(action);
        var name: [48]u8 = undefined;
        gtk.g_menu_append(items, column_labels.get(column), strings.format(&name, "albumcolumns.{s}", .{@tagName(column)}).ptr);
    }
    gtk.gtk_widget_insert_action_group(widget, "albumcolumns", gtk.cast(gtk.GActionGroup, group));
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popupModel(widget, gtk.cast(gtk.GMenuModel, items), x, y);
}

fn trackHeader(page: *AlbumPage) *gtk.Widget {
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(header, "album-tracks-header");
    const number = gtk.gtk_label_new("#");
    gtk.gtk_widget_set_size_request(number, number_column_pixels, -1);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 1.0);
    const title = gtk.gtk_label_new("TITLE");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    for ([_]*gtk.Widget{ number, title }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, header), part);
    const headings = std.enums.EnumArray(Column, struct { text: [:0]const u8, width: c_int }).init(.{
        .rating = .{ .text = "RATING", .width = stars_column_pixels },
        .format = .{ .text = "FORMAT", .width = format_column_pixels },
        .sample_rate = .{ .text = "RATE", .width = rate_column_pixels },
    });
    for (std.enums.values(Column)) |column| {
        const heading = headings.get(column);
        const label = gtk.gtk_label_new(heading.text.ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_widget_set_size_request(label, heading.width, -1);
        page.column_headers.set(column, label);
        gtk.gtk_box_append(gtk.cast(gtk.Box, header), label);
    }
    const chooser = gtk.gtk_button_new_from_icon_name("view-more-horizontal-symbolic");
    gtk.gtk_widget_add_css_class(chooser, "flat");
    gtk.gtk_widget_add_css_class(chooser, "column-chooser");
    gtk.gtk_widget_set_tooltip_text(chooser, "Choose Columns");
    gtk.gtk_widget_set_valign(chooser, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(chooser, "clicked", gtk.callback(columnChooserClicked), page.self);
    const duration = gtk.gtk_image_new_from_icon_name("preferences-system-time-symbolic");
    gtk.gtk_widget_set_tooltip_text(duration, "Duration");
    gtk.gtk_widget_set_halign(duration, gtk.ALIGN_END);
    gtk.gtk_widget_set_size_request(duration, duration_column_pixels, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), chooser);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), duration);
    return header;
}

fn showMeta(page: *AlbumPage) void {
    const label = page.meta orelse return;
    const self = page.self;
    const library = self.library orelse return;
    const release = (self.runtime.libraryRelease(library, page.release_id) catch null) orelse return;
    defer release.deinit(self.allocator);
    const genres = self.runtime.libraryReleaseGenres(library, page.release_id, 2) catch null;
    defer if (genres) |found| found.deinit();
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var parts: usize = 0;
    const year = releaseYear(release);
    if (year.len != 0) {
        writer.writeAll(year) catch {};
        parts += 1;
    }
    if (genres) |found| if (found.items.len != 0) {
        if (parts != 0) writer.writeAll(" • ") catch {};
        for (found.items, 0..) |genre, index| {
            if (index != 0) writer.writeAll(" / ") catch {};
            writer.writeAll(genre.name) catch {};
        }
        parts += 1;
    };
    if (parts != 0) writer.writeAll(" • ") catch {};
    var songs: [32]u8 = undefined;
    writer.print("{s} • {d} min", .{ plural(&songs, page.ids.len, "song", "songs"), minutesOf(release.total_duration_ms) }) catch {};
    buffer[writer.end] = 0;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), buffer[0..writer.end :0].ptr);
}

fn collapseDescription(page: *AlbumPage) void {
    const label = page.description orelse return;
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, label), description_lines);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
}

fn moreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const label = page.description orelse return;
    page.expanded = true;
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, label), -1);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_NONE);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, button.?), gtk.false_);
}

fn checkMore(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const page = pageData(data);
    const label = page.description orelse return gtk.false_;
    const more = page.more_link orelse return gtk.false_;
    const width = gtk.gtk_widget_get_width(label);
    const shown = if (page.about) |about| gtk.gtk_widget_get_visible(about) != 0 else false;
    if (width <= 0 and shown) return gtk.true_;
    page.more_pending = false;
    if (page.expanded or width <= 0) return gtk.false_;
    const layout = gtk.gtk_widget_create_pango_layout(label, gtk.gtk_label_get_text(gtk.cast(gtk.Label, label)));
    defer gtk.g_object_unref(layout);
    gtk.pango_layout_set_width(layout, width * gtk.PANGO_SCALE);
    gtk.gtk_widget_set_visible(more, @intFromBool(gtk.pango_layout_get_line_count(layout) > description_lines));
    return gtk.false_;
}

fn queueMoreCheck(page: *AlbumPage) void {
    if (page.more_pending or page.expanded) return;
    const scroller = page.scroller orelse return;
    page.more_pending = true;
    _ = gtk.gtk_widget_add_tick_callback(scroller, checkMore, page, null);
}

fn pageResized(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    queueMoreCheck(pageData(data));
}

/// Shows the stored description, and says whether any info is stored.
fn showInfo(page: *AlbumPage) bool {
    const self = page.self;
    const about = page.about orelse return true;
    const library = self.library orelse return true;
    var stored = (self.runtime.libraryReleaseInfo(library, page.release_id) catch return true) orelse {
        gtk.gtk_widget_set_visible(about, gtk.false_);
        return false;
    };
    defer stored.deinit();
    const record = stored.record;
    const text = std.mem.trim(u8, record.description orelse "", " \n");
    gtk.gtk_widget_set_visible(about, @intFromBool(text.len != 0));
    if (text.len == 0) return true;
    const owned = self.allocator.dupeZ(u8, text) catch return true;
    defer self.allocator.free(owned);
    if (page.description) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), owned.ptr);
    collapseDescription(page);
    queueMoreCheck(page);
    var buffer: [1024]u8 = undefined;
    if (page.source) |source| {
        const url = record.description_url orelse "";
        gtk.gtk_widget_set_visible(source, @intFromBool(url.len != 0));
        if (url.len != 0) gtk.gtk_link_button_set_uri(gtk.cast(gtk.LinkButton, source), strings.terminated(&buffer, url).ptr);
    }
    if (page.licence) |licence| {
        const name = record.description_licence orelse "";
        gtk.gtk_widget_set_visible(licence, @intFromBool(name.len != 0));
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, licence), strings.format(&buffer, "• {s}", .{name}).ptr);
    }
    return true;
}

fn newAbout(page: *AlbumPage) *gtk.Widget {
    const about = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_add_css_class(about, "album-about");
    const description = gtk.gtk_label_new("");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, description), gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, description), 0.0);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, description), 1000);
    gtk.gtk_widget_add_css_class(description, "album-description");
    page.description = description;
    const measure = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, measure), description_max_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, measure), description_max_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, measure), description);
    gtk.gtk_widget_set_halign(measure, gtk.ALIGN_START);
    const more = gtk.gtk_button_new_with_label("More");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "album-description-more");
    gtk.gtk_widget_set_halign(more, gtk.ALIGN_START);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), page);
    page.more_link = more;
    const attribution = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(attribution, "album-attribution");
    const from = gtk.gtk_label_new("From");
    const source = gtk.gtk_link_button_new_with_label("https://wikipedia.org/", "Wikipedia");
    page.source = source;
    const licence = gtk.gtk_label_new("");
    page.licence = licence;
    for ([_]*gtk.Widget{ from, source, licence }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, attribution), part);
    for ([_]*gtk.Widget{ measure, more, attribution }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, about), part);
    page.about = about;
    return about;
}

/// Starts a fetch of the Release's info unless one ran this session.
fn requestInfo(self: *App, release_id: i64) void {
    const info = &self.album_info;
    if (info.closed or info.requested.contains(release_id)) return;
    if (info.pending_count == info.pending.len) return;
    const library = self.library orelse return;
    info.requested.put(self.allocator, release_id, {}) catch return;
    const job = self.runtime.startReleaseInfoFetch(library, release_id, .{}) catch return;
    info.pending[info.pending_count] = .{ .release_id = release_id, .job = job };
    info.pending_count += 1;
}

pub fn tick(self: *App) void {
    const info = &self.album_info;
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
        for (self.open_album_pages[0..self.open_album_page_count]) |page| {
            if (page.release_id != pending.release_id) continue;
            _ = showInfo(page);
            showMeta(page);
        }
        details.albumInfoChanged(self, pending.release_id);
    }
}

pub fn shutdown(self: *App) void {
    const info = &self.album_info;
    info.closed = true;
    for (info.pending[0..info.pending_count]) |pending| self.runtime.cancelJob(pending.job) catch {};
    info.pending_count = 0;
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

/// The release type uppercased, as `EP` or `SINGLE`; otherwise
/// `COMPILATION` or `ALBUM`.
fn eyebrow(buffer: []u8, release_type: ?[]const u8, is_compilation: bool) [:0]const u8 {
    const fallback: [:0]const u8 = if (is_compilation) "COMPILATION" else "ALBUM";
    const kind = std.mem.trim(u8, release_type orelse "", " ");
    if (kind.len == 0 or kind.len >= buffer.len) return fallback;
    const upper = std.ascii.upperString(buffer[0..kind.len], kind);
    buffer[upper.len] = 0;
    return buffer[0..upper.len :0];
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
    const kind = gtk.gtk_label_new(eyebrow(&buffer, release.release_type, release.is_compilation).ptr);
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
    const meta = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(meta, "album-meta");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, meta), gtk.true_);
    page.meta = meta;
    showMeta(page);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, kind), 0.0);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, meta), 0.0);
    for ([_]*gtk.Widget{ kind, title, artist, meta, newAbout(page) }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, facts), widget);
    if (!showInfo(page)) requestInfo(self, release_id);
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
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), trackHeader(page));
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
    showColumns(page);
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
    page.scroller = scroller;
    _ = gtk.signalConnect(gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), "changed", gtk.callback(pageResized), page);
    queueMoreCheck(page);
    registerPage(page);

    const title_text = strings.printZ(&buffer, "{s}", .{if (release.title.len != 0) release.title else "Album"}) catch "Album";
    const pushed = adw.adw_navigation_page_new(scroller, title_text.ptr);
    window.markPushed(pushed, .{ .album = release_id });
    adw.adw_navigation_view_push(navigation, pushed);
    _ = gtk.gtk_widget_grab_focus(play);
}
