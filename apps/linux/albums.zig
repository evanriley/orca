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
const artist_page = @import("artist_page.zig");
const album_filters = @import("album_filters.zig");
const signal_path = @import("signal_path.zig");
const preferences = @import("preferences.zig");
const window = @import("window.zig");
const offline = @import("offline.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const list_cover_pixels: c_int = 32;
const hero_pixels: c_int = 248;
const number_column_pixels: c_int = 32;
const duration_column_pixels: c_int = 50;
const format_column_pixels: c_int = 96;
const rate_column_pixels: c_int = 64;
const stars_column_pixels: c_int = 96;
const content_max_pixels = 1020;
const meta_separator = "  <span fgalpha=\"43%\">·</span>  ";
const grid_cell_padding_pixels = 22;
const cover_size_pixels = 96;
const grid_min_columns = 2;
const min_tile_pixels = 72;
const description_max_pixels = 520;
const description_lines = 3;
const pending_info_limit = 8;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.ReleaseSort }{
    .{ .label = "Date Added", .sort = .recently_added },
    .{ .label = "Title", .sort = .title },
    .{ .label = "Artist", .sort = .artist },
    .{ .label = "Year", .sort = .year },
    .{ .label = "Loved", .sort = .loved },
    .{ .label = "Most Played", .sort = .most_played },
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

/// Which Releases the page lists.
pub const Shelf = enum { all, loved, high_resolution, needs_review };

/// How recently a listed Release was added. The cutoff is fixed when the
/// window is chosen, so every page of one listing agrees on it.
pub const Added = struct {
    window: Window = .any,
    after: ?i64 = null,

    pub const Window = enum {
        any,
        week,
        month,
        year,

        pub fn days(self: Window) ?i64 {
            return switch (self) {
                .any => null,
                .week => 7,
                .month => 30,
                .year => 365,
            };
        }

        pub fn label(self: Window) [*:0]const u8 {
            return switch (self) {
                .any => "Any time",
                .week => "Last 7 days",
                .month => "Last 30 days",
                .year => "Last 12 months",
            };
        }
    };
};

const recently_added_window: Added.Window = .month;

/// From this many albums in the library the page takes its large-library
/// form: a count line, facet chips and letter sections.
const large_library_albums = 2000;
const large_tile_pixels = 104;
const section_column_gap = 14;
const page_cache_slots = 6;
const scrubber_letters = "#" ++ "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const scrub_bubble_ms = 700;
const scroll_settle_frames = 12;
const section_art_frames = 30;
const hover_play_pixels = 44;
const hover_more_pixels = 24;

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

fn newTile(self: *App) *gtk.Widget {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(tile, self.album_tile_pixels, -1);

    const cover = art.newCover(self, art.initialsPlaceholder(), self.album_tile_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    const dim = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(dim, "tile-dim");
    gtk.gtk_widget_add_css_class(dim, "tile-action");
    gtk.gtk_widget_set_can_target(dim, gtk.false_);
    const play = gtk.gtk_button_new_from_icon_name("orca-play-symbolic");
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
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), dim);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), play);
    const badge = explicitBadge();
    gtk.gtk_widget_set_halign(badge, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_END);
    gtk.gtk_widget_add_css_class(badge, "cover-badge");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), badge);
    const local = offline.localBadge();
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), local);

    const playing = playingBars();
    const title = tileLabel(null, "tile-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(heading, "tile-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), playing);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
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

    for ([_]*gtk.Widget{ frame, heading, byline, year }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), part);
    gtk.g_object_set_data(tile, "orca-play", play);
    gtk.g_object_set_data(tile, "orca-more", more);
    gtk.g_object_set_data(tile, "orca-cover", cover);
    gtk.g_object_set_data(tile, "orca-title", title);
    gtk.g_object_set_data(tile, "orca-artist", artist);
    gtk.g_object_set_data(tile, "orca-year", year);
    gtk.g_object_set_data(tile, "orca-explicit", badge);
    gtk.g_object_set_data(tile, "orca-local", local);
    gtk.g_object_set_data(tile, "orca-playing", playing);
    menu.onSecondaryClick(tile, tileMenu, self);
    return tile;
}

fn setupTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const tile = newTile(state(data));
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    for ([_]?*gtk.Widget{ tile, tilePart(tile, "orca-play"), tilePart(tile, "orca-more") }) |widget|
        gtk.g_object_set_data(widget.?, "orca-list-item", item);
}

pub fn playingBadge() *gtk.Widget {
    const badge = gtk.gtk_image_new_from_icon_name("media-playback-start-symbolic");
    gtk.gtk_widget_add_css_class(badge, "playing-badge");
    gtk.gtk_widget_set_halign(badge, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(badge, "Playing");
    gtk.gtk_widget_set_visible(badge, gtk.false_);
    return badge;
}

fn playingBars() *gtk.Widget {
    const bars = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(bars, "playing-bars");
    gtk.gtk_widget_set_valign(bars, gtk.ALIGN_CENTER);
    for ([_]c_int{ 10, 6, 8 }) |height| {
        const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_add_css_class(bar, "playing-bar");
        gtk.gtk_widget_set_size_request(bar, 2, height);
        gtk.gtk_widget_set_valign(bar, gtk.ALIGN_END);
        gtk.gtk_box_append(gtk.cast(gtk.Box, bars), bar);
    }
    gtk.gtk_widget_set_size_request(bars, -1, 10);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, bars), gtk.ACCESSIBLE_PROPERTY_LABEL, "Now playing", @as(c_int, -1));
    gtk.gtk_widget_set_tooltip_text(bars, "Now playing");
    gtk.gtk_widget_set_visible(bars, gtk.false_);
    return bars;
}

pub fn showPlaying(widget: *gtk.Widget, playing: bool) void {
    if (playing)
        gtk.gtk_widget_add_css_class(widget, "now-playing")
    else
        gtk.gtk_widget_remove_css_class(widget, "now-playing");
    const badge = gtk.g_object_get_data(widget, "orca-playing") orelse return;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, badge), @intFromBool(playing));
}

pub fn watchView(self: *App, view: *gtk.Widget, kind: app.PlayingKind) void {
    for (&self.marked_views) |*slot| {
        if (slot.* != null) continue;
        slot.* = .{ .view = view, .kind = kind };
        _ = gtk.signalConnect(view, "destroy", gtk.callback(watchedViewDestroyed), self);
        return;
    }
}

fn watchedViewDestroyed(view: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    for (&self.marked_views) |*slot| {
        const marked = slot.* orelse continue;
        if (@as(*anyopaque, @ptrCast(marked.view)) == view) slot.* = null;
    }
}

fn markViews(self: *App) void {
    const playing = self.playing();
    for (self.marked_views) |slot| {
        const marked = slot orelse continue;
        var child = gtk.gtk_widget_get_first_child(marked.view);
        while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
            const tile = gtk.gtk_widget_get_first_child(cell) orelse continue;
            const item = gtk.g_object_get_data(tile, "orca-list-item") orelse continue;
            const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse continue;
            const row: *BrowseObject = @ptrCast(@alignCast(object));
            showPlaying(tile, playing.matches(marked.kind, row.id()));
        }
    }
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
    if (gtk.g_object_get_data(widget, "orca-release")) |id| return @intCast(@intFromPtr(id));
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
    showInert(list_item, tile, row.isPlaceholder());
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), titleText(row));
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), row.detail().ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, year), row.caption().ptr);
    if (tilePart(tile, "orca-explicit")) |badge| gtk.gtk_widget_set_visible(badge, @intFromBool(row.release().explicit));
    art.setInitials(cover, row.name());
    showPlaying(tile, self.playing().matches(.release, row.id()));
    offline.markTile(self, tile, row.id());
    const id = row.id() orelse return;
    const grid: ?*gtk.Widget = if (self.album_grid) |view| gtk.cast(gtk.Widget, view) else null;
    art.show(self, cover, art.Key.release(id, coverArtSize(grid, self.album_tile_pixels)));
}

fn titleText(row: *BrowseObject) [*:0]const u8 {
    if (row.isPlaceholder()) return "";
    return if (row.name().len != 0) row.name().ptr else "Untitled";
}

fn showInert(list_item: *gtk.ListItem, widget: *gtk.Widget, inert: bool) void {
    gtk.gtk_list_item_set_activatable(list_item, @intFromBool(!inert));
    gtk.gtk_widget_set_can_target(widget, @intFromBool(!inert));
    for ([_][*:0]const u8{ "orca-play", "orca-more", "orca-heart" }) |key| {
        if (tilePart(widget, key)) |part| gtk.gtk_widget_set_visible(part, @intFromBool(!inert));
    }
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
    const tracks = listLabel("album-list-detail", 64, 1);
    const minutes = listLabel("album-list-detail", 56, 1);
    const format = listLabel("album-list-format", format_column_pixels, 0);
    for ([_]*gtk.Widget{ year, tracks, minutes }) |label| gtk.gtk_widget_add_css_class(label, "numeric");
    const heart = feedback.newRowButton(gtk.callback(listHeartClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(tileMoreClicked), self);
    for ([_]*gtk.Widget{ cover, names, year, tracks, minutes, format, heart, more }) |part|
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), part);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    for ([_]*gtk.Widget{ row, heart, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(row, "orca-cover", cover);
    gtk.g_object_set_data(row, "orca-title", title);
    gtk.g_object_set_data(row, "orca-explicit", badge);
    gtk.g_object_set_data(row, "orca-artist", artist);
    gtk.g_object_set_data(row, "orca-year", year);
    gtk.g_object_set_data(row, "orca-tracks", tracks);
    gtk.g_object_set_data(row, "orca-minutes", minutes);
    gtk.g_object_set_data(row, "orca-format", format);
    gtk.g_object_set_data(row, "orca-heart", heart);
    gtk.g_object_set_data(row, "orca-more", more);
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
    const placeholder = row.isPlaceholder();
    showInert(list_item, widget, placeholder);
    var buffer: [64]u8 = undefined;
    if (tilePart(widget, "orca-title")) |title| gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), titleText(row));
    if (tilePart(widget, "orca-explicit")) |badge| gtk.gtk_widget_set_visible(badge, @intFromBool(release.explicit));
    if (tilePart(widget, "orca-artist")) |artist| gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), row.detail().ptr);
    if (tilePart(widget, "orca-year")) |year| gtk.gtk_label_set_text(gtk.cast(gtk.Label, year), row.caption().ptr);
    if (tilePart(widget, "orca-tracks")) |tracks| gtk.gtk_label_set_text(gtk.cast(gtk.Label, tracks), if (placeholder)
        ""
    else
        strings.format(&buffer, "{d} {s}", .{ release.track_count, if (release.track_count == 1) "track" else "tracks" }).ptr);
    if (tilePart(widget, "orca-minutes")) |minutes| gtk.gtk_label_set_text(gtk.cast(gtk.Label, minutes), if (placeholder)
        ""
    else
        strings.format(&buffer, "{d} min", .{minutesOf(release.duration_ms)}).ptr);
    if (tilePart(widget, "orca-format")) |format| gtk.gtk_label_set_text(gtk.cast(gtk.Label, format), release.format.ptr);
    if (tilePart(widget, "orca-heart")) |heart| feedback.showRowButton(heart, if (release.loved) .loved else .none);
    showPlaying(widget, self.playing().matches(.release, row.id()));
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

const LoveChange = struct {
    release_id: i64,
    loved: bool,

    fn replace(self: LoveChange, row: *BrowseObject) ?*BrowseObject {
        if (row.id() != self.release_id or row.release().loved == self.loved) return null;
        return browse_model.releaseWithLove(row, self.loved);
    }
};

fn showListLove(self: *App, release_id: i64, loved: bool) void {
    const model = self.album_model orelse return;
    _ = model.update(LoveChange{ .release_id = release_id, .loved = loved }, LoveChange.replace);
}

fn shelf(self: *const App) Shelf {
    return self.album_shelf;
}

pub fn setAdded(self: *App, added: Added.Window) void {
    const days = added.days() orelse {
        self.album_added = .{};
        return;
    };
    self.album_added = .{
        .window = added,
        .after = std.Io.Clock.real.now(self.io).toSeconds() - days * std.time.s_per_day,
    };
}

pub fn narrowed(self: *const App) bool {
    return self.album_search.value.len != 0 or
        self.album_filters.count() != 0 or
        self.album_artist_filter != null or
        self.album_added.window != .any or
        shelf(self) != .all;
}

fn request(self: *App, offset: u64) liborca.ReleaseQuery {
    const filters = self.album_filters;
    const artist_id: ?i64 = if (self.album_artist_filter) |artist| artist.artist_id else null;
    const scope: ?ArtistScope = if (self.album_artist_filter) |artist| artist.scope else null;
    return .{
        .text = self.album_search.value,
        .sort = self.album_sort,
        .name_order = self.general.name_order,
        .added_after = self.album_added.after,
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
        .offset = @intCast(@min(offset, std.math.maxInt(u32))),
    };
}

pub fn reload(self: *App) void {
    measureLibrary(self);
    relist(self);
}

pub fn relist(self: *App) void {
    const model = self.album_model orelse return;
    const started = gtk.g_get_monotonic_time();
    syncControls(self);
    album_filters.showFacets(self);
    cancelCount(self);
    self.albums_failure = .none;
    const library = self.library orelse {
        model.reset(0);
        setBuckets(self, &.{});
        return showListing(self, 0);
    };
    if (sectioned(self)) {
        model.reset(0);
        return showListing(self, loadSections(self, library));
    }
    setBuckets(self, &.{});
    model.setSource(.{ .context = self, .request = requestReleases, .cancel = cancelReleases });
    requestCount(self);
    if (self.albums_count_request == .idle) self.albums_count = 0;
    scrollToTop(self);
    model.reset(listedRows(self.albums_count));
    if (self.albums_count_request == .idle) {
        showListing(self, 0);
    } else {
        if (self.albums_count != 0) {
            if (self.albums_body) |body| gtk.gtk_stack_set_visible_child_name(body, bodyChild(self, self.albums_count));
        }
        showSectionChrome(self, false);
    }
    if (self.debug_frames) std.debug.print("orca-gtk frames: album reload {d} us\n", .{gtk.g_get_monotonic_time() - started});
}

fn listedRows(total: u64) u32 {
    return @intCast(@min(total, std.math.maxInt(u32)));
}

fn scrollToTop(self: *App) void {
    const body = self.albums_body orelse return;
    for ([_][*:0]const u8{ "grid", "list" }) |name| {
        const scroller = gtk.gtk_stack_get_child_by_name(body, name) orelse continue;
        gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), 0.0);
    }
}

fn showListing(self: *App, total: u64) void {
    self.albums_count = total;
    if (!sectioned(self)) {
        if (self.album_model) |model| model.resize(listedRows(total));
    }
    showCount(self, total);
    if (self.albums_empty) |empty| {
        const text = emptyText(self);
        adw.adw_status_page_set_title(empty, text.title);
        adw.adw_status_page_set_description(empty, text.description);
    }
    if (self.albums_body) |body| gtk.gtk_stack_set_visible_child_name(body, bodyChild(self, total));
    showSectionChrome(self, total != 0);
}

fn requestReleases(context: *anyopaque, offset: u32, limit: u32) track_model.Requested {
    const self = state(context);
    const library = self.library orelse return .failed;
    var query = request(self, offset);
    query.limit = limit;
    const id = self.runtime.libraryRequestBrowse(library, self.io, .{ .release_page = query }) catch |err| {
        if (err == error.BrowseQueueFull) {
            self.scheduleBrowseRetry();
            return .busy;
        }
        self.noteAlbumsFailure();
        return .failed;
    };
    return .{ .issued = id };
}

fn cancelReleases(context: *anyopaque, request_id: u64) void {
    const self = state(context);
    const library = self.library orelse return;
    self.runtime.libraryCancelBrowse(library, request_id);
}

fn requestCount(self: *App) void {
    const library = self.library orelse {
        self.albums_count_request = .idle;
        return;
    };
    const id = self.runtime.libraryRequestBrowse(library, self.io, .{ .release_count = request(self, 0) }) catch |err| {
        if (err == error.BrowseQueueFull) {
            self.albums_count_request = .waiting;
            self.scheduleBrowseRetry();
            return;
        }
        self.albums_count_request = .idle;
        self.noteAlbumsFailure();
        return;
    };
    self.albums_count_request = .{ .pending = id };
}

fn cancelCount(self: *App) void {
    switch (self.albums_count_request) {
        .pending => |id| if (self.library) |library| self.runtime.libraryCancelBrowse(library, id),
        else => {},
    }
    self.albums_count_request = .idle;
}

pub fn isCountRequest(self: *const App, request_id: u64) bool {
    return switch (self.albums_count_request) {
        .pending => |id| id == request_id,
        else => false,
    };
}

pub fn countArrived(self: *App, count: u64) void {
    const started = gtk.g_get_monotonic_time();
    self.albums_count_request = .idle;
    showListing(self, count);
    if (self.debug_frames) std.debug.print("orca-gtk frames: album count {d} us\n", .{gtk.g_get_monotonic_time() - started});
}

pub fn countFailed(self: *App) void {
    self.albums_count_request = .idle;
    self.noteAlbumsFailure();
    showListing(self, 0);
}

pub fn pageArrived(self: *App, request_id: u64, page: liborca.ReleasePage) void {
    const model = self.album_model orelse return;
    const started = gtk.g_get_monotonic_time();
    offline.prefetchReleases(self, page.items);
    model.pageArrived(request_id, page);
    if (self.debug_frames) std.debug.print("orca-gtk frames: album page {d} us\n", .{gtk.g_get_monotonic_time() - started});
}

pub fn pageFailed(self: *App, request_id: u64) bool {
    const model = self.album_model orelse return false;
    return model.pageFailed(request_id);
}

pub fn retryWaiting(self: *App) bool {
    var waiting = false;
    if (self.albums_count_request == .waiting) {
        requestCount(self);
        switch (self.albums_count_request) {
            .waiting => waiting = true,
            .idle => countFailed(self),
            .pending => {},
        }
    }
    if (self.album_model) |model| {
        if (model.retryWaiting()) waiting = true;
    }
    return waiting;
}

fn bodyChild(self: *const App, total: u64) [*:0]const u8 {
    if (total == 0) return "empty";
    if (sectioned(self)) return "sections";
    return @tagName(self.album_layout);
}

fn showCount(self: *App, total: u64) void {
    var buffer: [128]u8 = undefined;
    const sections = &self.album_sections;
    if (self.albums_meta) |meta| {
        const text: [:0]const u8 = if (sections.large and sections.totals != null) text: {
            const totals = sections.totals.?;
            const size = gtk.g_format_size(totals.bytes);
            defer gtk.g_free(size);
            break :text strings.printZ(&buffer, "{f} \u{00b7} {f} artists \u{00b7} {s}", .{
                strings.grouped(totals.count),
                strings.grouped(totals.artists),
                std.mem.span(size),
            }) catch "";
        } else if (total == 1)
            "1 album"
        else
            strings.printZ(&buffer, "{d} albums", .{total}) catch "";
        gtk.gtk_label_set_text(meta, text.ptr);
    }
    showUnavailable(self);
    const label = sections.match orelse return;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, label), @intFromBool(sections.large and narrowed(self)));
    gtk.gtk_label_set_text(label, (strings.printZ(&buffer, "{f} match", .{strings.grouped(total)}) catch @as([:0]const u8, "")).ptr);
}

/// " · N unavailable" after the album count while a root is offline and the
/// listing is the whole library.
pub fn showUnavailable(self: *App) void {
    const label = self.albums_unavailable orelse return;
    const count = offline.unavailableReleases(self);
    var buffer: [64]u8 = undefined;
    const shown = count != 0 and (self.album_sections.large or !narrowed(self));
    const text: [:0]const u8 = if (shown) strings.format(&buffer, " \u{00b7} {f} unavailable", .{strings.grouped(count)}) else "";
    gtk.gtk_label_set_text(label, text.ptr);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, label), @intFromBool(shown));
}

fn besideMeta(meta: *gtk.Label) *gtk.Label {
    const meta_widget = gtk.cast(gtk.Widget, meta);
    const column = gtk.gtk_widget_get_parent(meta_widget).?;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    _ = gtk.g_object_ref(meta_widget);
    gtk.gtk_box_remove(gtk.cast(gtk.Box, column), meta_widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), meta_widget);
    gtk.g_object_unref(meta_widget);
    const unavailable = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(unavailable, "meta");
    gtk.gtk_widget_add_css_class(unavailable, "numeric");
    gtk.gtk_widget_add_css_class(unavailable, "meta-unavailable");
    gtk.gtk_widget_set_visible(unavailable, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), unavailable);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), row);
    return gtk.cast(gtk.Label, unavailable);
}

pub fn reloadKeepingScroll(self: *App) void {
    const scroll = page_ui.visibleScroll(self.albums_body);
    reload(self);
    if (scroll) |kept| page_ui.restoreScroll(self, kept);
}

pub const RowRefresh = enum { not_listed, replaced, release_gone, merged };

pub fn refreshReleaseRow(self: *App, store: *gtk.ListStore, listed_id: i64, release_id: i64) RowRefresh {
    const library = self.library orelse return .not_listed;
    const release = (self.runtime.libraryRelease(library, release_id) catch null) orelse return .release_gone;
    defer release.deinit(self.allocator);
    const model = gtk.cast(gtk.ListModel, store);
    const count = gtk.g_list_model_get_n_items(model);
    var found: ?c_uint = null;
    var position: c_uint = 0;
    while (position < count) : (position += 1) {
        const id = releaseAt(store, position);
        if (id != listed_id and id != release_id) continue;
        if (found != null) return .merged;
        found = position;
    }
    const at = found orelse return .not_listed;
    const row = newReleaseRow(&release) orelse return .not_listed;
    var replacement: [1]?*anyopaque = .{row};
    gtk.g_list_store_splice(store, at, 1, &replacement, 1);
    gtk.g_object_unref(row);
    return .replaced;
}

pub fn releaseChanged(self: *App, release_id: i64) void {
    releaseMoved(self, release_id, release_id);
}

const RowChange = struct {
    listed_id: i64,
    release_id: i64,
    release: *const liborca.ReleaseSummary,
    replaced: u32 = 0,

    fn replace(self: *RowChange, row: *BrowseObject) ?*BrowseObject {
        const id = row.id() orelse return null;
        if (id != self.listed_id and id != self.release_id) return null;
        self.replaced += 1;
        return newReleaseRow(self.release);
    }
};

fn refreshListedRelease(self: *App, model: *PagedReleases, listed_id: i64, release_id: i64) RowRefresh {
    const library = self.library orelse return .not_listed;
    const release = (self.runtime.libraryRelease(library, release_id) catch null) orelse return .release_gone;
    defer release.deinit(self.allocator);
    var change: RowChange = .{ .listed_id = listed_id, .release_id = release_id, .release = &release };
    _ = model.update(&change, RowChange.replace);
    return switch (change.replaced) {
        0 => .not_listed,
        1 => .replaced,
        else => .merged,
    };
}

pub fn releaseMoved(self: *App, old_id: i64, new_id: i64) void {
    if (self.album_model) |model| switch (refreshListedRelease(self, model, old_id, new_id)) {
        .release_gone, .merged => reloadKeepingScroll(self),
        .not_listed, .replaced => {},
    };
    if (self.album_sections.buckets.len != 0) {
        if (old_id == new_id) refreshSections(self) else reloadKeepingScroll(self);
    }
    refreshPages(self, old_id, new_id);
}

fn emptyText(self: *const App) struct { title: [*:0]const u8, description: [*:0]const u8 } {
    if (self.album_search.value.len != 0)
        return .{ .title = "No matching albums", .description = "Try another search." };
    if (self.album_filters.count() != 0 or self.album_artist_filter != null)
        return .{ .title = "No matching albums", .description = "Clear the filters to see more albums." };
    return switch (shelf(self)) {
        .all => switch (self.album_added.window) {
            .any => .{ .title = "No albums yet", .description = "Add a music folder in Settings › Library." },
            .week => .{ .title = "Nothing added recently", .description = "Albums added in the last 7 days appear here." },
            .month => .{ .title = "Nothing added recently", .description = "Albums added in the last 30 days appear here." },
            .year => .{ .title = "Nothing added recently", .description = "Albums added in the last 12 months appear here." },
        },
        .loved => .{ .title = "No loved albums", .description = "Love an album from its page or its menu." },
        .high_resolution => .{ .title = "No high-resolution albums", .description = "Albums above 16-bit or 48 kHz appear here." },
        .needs_review => .{ .title = "Nothing to review", .description = "Albums with matches waiting for review appear here." },
    };
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

const ReleaseRows = struct {
    pub const Row = BrowseObject;
    pub const Page = liborca.ReleasePage;
    pub const type_name = "OrcaPagedReleaseModel";
    pub const itemType = browse_model.getType;
    pub const empty = browse_model.releasePlaceholder;
    pub const fromItem = newReleaseRow;
};

pub const PagedReleases = track_model.Paged(ReleaseRows);

fn newReleaseRow(release: *const liborca.ReleaseSummary) ?*BrowseObject {
    var format: [64]u8 = undefined;
    return browse_model.newRelease(release.id, release.title, release.album_artist, releaseYear(release.*), releaseFormat(&format, release), .{
        .track_count = release.track_count,
        .duration_ms = release.total_duration_ms,
        .loved = release.loved,
        .explicit = release.explicit == .explicit,
    });
}

pub fn appendReleasePage(self: *App, store: *gtk.ListStore, query: liborca.ReleaseQuery) ?u32 {
    const library = self.library orelse return null;
    var page = self.runtime.libraryReleasePage(library, query) catch return null;
    defer page.deinit();
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    for (page.items) |*release| {
        const row = newReleaseRow(release) orelse continue;
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

fn activeChip(self: *const App) Chip {
    return switch (shelf(self)) {
        .all => if (self.album_added.window == .any) .all else .recently_added,
        .loved => .loved,
        .high_resolution => .high_resolution,
        .needs_review => .needs_review,
    };
}

fn syncControls(self: *App) void {
    self.albums_syncing_controls = true;
    defer self.albums_syncing_controls = false;
    for (sorts, 0..) |entry, index| {
        if (entry.sort != self.album_sort) continue;
        if (self.album_sort_control) |control| gtk.gtk_drop_down_set_selected(control, @intCast(index));
        if (self.album_sections.sort_checks[index]) |check| gtk.gtk_check_button_set_active(check, gtk.true_);
        if (self.album_sections.sort_button) |button| {
            var buffer: [48]u8 = undefined;
            gtk.gtk_menu_button_set_label(button, (strings.printZ(&buffer, "Sort: {s}", .{std.mem.span(entry.label)}) catch @as([:0]const u8, "Sort")).ptr);
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
    chooseSort(self, sorts[selected].sort);
}

fn chooseSort(self: *App, sort: liborca.ReleaseSort) void {
    self.album_sort = sort;
    settings.save(self);
    relist(self);
}

fn sortChecked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_syncing_controls) return;
    const check = gtk.cast(gtk.CheckButton, button.?);
    if (gtk.gtk_check_button_get_active(check) == gtk.false_) return;
    const index = for (self.album_sections.sort_checks, 0..) |candidate, index| {
        if (candidate == check) break index;
    } else return;
    if (self.album_sections.sort_popover) |popover| gtk.gtk_popover_popdown(gtk.cast(gtk.Popover, popover));
    if (sorts[index].sort != self.album_sort) chooseSort(self, sorts[index].sort);
}

pub fn setFilter(self: *App, text: []const u8) void {
    if (std.mem.eql(u8, text, self.album_search.value)) return;
    self.album_search.set(self.allocator, text);
    relist(self);
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
    self.album_added = .{};
    settings.save(self);
    relist(self);
    window.showPage(self, .albums);
    if (self.albums_navigation) |navigation| window.popToTag(self, navigation, "albums");
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
    relist(self);
}

pub fn showArtist(self: *App, artist_id: i64, name: []const u8, scope: ArtistScope) void {
    self.album_artist_filter = .{ .artist_id = artist_id, .scope = scope };
    self.album_artist_name.set(self.allocator, name);
    self.album_filters = .{};
    album_filters.showActive(self);
    window.clearSearch(self);
    self.album_search.clear(self.allocator);
    self.album_shelf = .all;
    self.album_added = .{};
    showArtistChip(self);
    settings.save(self);
    relist(self);
    window.showPage(self, .albums);
    if (self.albums_navigation) |navigation| window.popToTag(self, navigation, "albums");
}

fn chooseChip(self: *App, chip: Chip) void {
    setAdded(self, if (chip == .recently_added) recently_added_window else .any);
    switch (chip) {
        .all => self.album_shelf = .all,
        .recently_added => {
            self.album_shelf = .all;
            self.album_sort = .recently_added;
        },
        .loved => self.album_shelf = .loved,
        .high_resolution => self.album_shelf = .high_resolution,
        .needs_review => self.album_shelf = .needs_review,
    }
    settings.save(self);
    relist(self);
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
    gtk.gtk_widget_set_hexpand(row, gtk.true_);
    gtk.gtk_widget_set_valign(row, gtk.ALIGN_CENTER);
    var group: ?*gtk.ToggleButton = null;
    for (std.enums.values(Chip)) |chip| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), chip_labels.get(chip));
        gtk.gtk_widget_add_css_class(button, "chip");
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

    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(bar, "album-chips");
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), newCoverSize(self));
    return bar;
}

fn coverSizeMoved(scale: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    preferences.setAlbumTile(state(data), gtk.gtk_range_get_value(gtk.cast(gtk.Range, scale)));
}

fn newCoverSize(self: *App) *gtk.Widget {
    const label = gtk.gtk_label_new("Cover size");
    gtk.gtk_widget_add_css_class(label, "cover-size-label");
    const range = app.album_tile_range;
    const adjustment = gtk.gtk_adjustment_new(@floatFromInt(self.appearance.album_grid_tile), @floatFromInt(range[0]), @floatFromInt(range[1]), 4, 16, 0);
    const scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, adjustment);
    gtk.gtk_widget_add_css_class(scale, "cover-size");
    gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, scale), gtk.false_);
    gtk.gtk_widget_set_size_request(scale, cover_size_pixels, -1);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, scale), gtk.ACCESSIBLE_PROPERTY_LABEL, "Cover size", @as(c_int, -1));
    _ = gtk.signalConnect(scale, "value-changed", gtk.callback(coverSizeMoved), self);
    self.album_cover_scale = gtk.cast(gtk.Range, scale);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), scale);
    return box;
}

fn tileActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const model = self.album_model orelse return;
    const id = listedRelease(gtk.cast(gtk.ListModel, model), position) orelse return;
    const navigation = self.albums_navigation orelse return;
    openAlbum(self, navigation, id);
}

pub fn newGrid(self: *App, store: *gtk.ListStore, activated: gtk.GCallback) *gtk.Widget {
    return newGridOver(self, gtk.cast(gtk.ListModel, store), activated);
}

fn newGridOver(self: *App, model: *gtk.ListModel, activated: gtk.GCallback) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupTile), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindTile), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const grid = gtk.gtk_grid_view_new(selectionOver(model), factory);
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 2);
    gtk.gtk_grid_view_set_tab_behavior(gtk.cast(gtk.GridView, grid), gtk.LIST_TAB_ITEM);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", activated, self);
    watchView(self, grid, .release);
    return grid;
}

pub fn newSelection(store: *gtk.ListStore) *gtk.SelectionModel {
    return selectionOver(gtk.cast(gtk.ListModel, store));
}

fn selectionOver(model: *gtk.ListModel) *gtk.SelectionModel {
    const selection = gtk.gtk_single_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(model)));
    gtk.gtk_single_selection_set_autoselect(selection, gtk.false_);
    gtk.gtk_single_selection_set_can_unselect(selection, gtk.true_);
    return gtk.cast(gtk.SelectionModel, selection);
}

/// As many columns as fit covers of at least `tile`, which then grow to
/// fill the row, never fewer than two.
pub fn gridColumns(width: f64, tile: c_int) c_uint {
    const cell: f64 = @floatFromInt(tile + grid_cell_padding_pixels);
    const fitting = @floor(width / cell);
    if (!(fitting > grid_min_columns)) return grid_min_columns;
    return @intFromFloat(@min(fitting, 16));
}

pub fn gridTilePixels(width: f64, columns: c_uint) c_int {
    const cell = @floor(width / @as(f64, @floatFromInt(columns)));
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
    self.album_grid_idle = 0;
    const grid = self.album_grid orelse return gtk.SOURCE_REMOVE;
    gtk.gtk_grid_view_set_min_columns(grid, self.album_grid_columns);
    gtk.gtk_grid_view_set_max_columns(grid, self.album_grid_columns);
    const size = coverArtSize(gtk.cast(gtk.Widget, grid), self.album_tile_pixels);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, grid));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        const tile = gtk.gtk_widget_get_first_child(cell) orelse continue;
        sizeTile(tile, self.album_tile_pixels);
        if (tilePart(tile, "orca-cover")) |cover| art.resize(self, cover, size);
    }
    return gtk.SOURCE_REMOVE;
}

fn gridDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.album_grid_idle != 0) _ = gtk.g_source_remove(self.album_grid_idle);
    self.album_grid_idle = 0;
    self.album_grid = null;
}

fn gridResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    const columns = gridColumns(width, self.appearance.album_grid_tile);
    const pixels = gridTilePixels(width, columns);
    if (columns == self.album_grid_columns and pixels == self.album_tile_pixels) return;
    self.album_grid_columns = columns;
    self.album_tile_pixels = pixels;
    if (self.album_grid_idle == 0) self.album_grid_idle = gtk.g_idle_add(applyGridColumns, self);
}

pub fn resizeGrid(self: *App) void {
    if (self.album_sections.scroller) |scroller| {
        const adjustment = gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
        if (gtk.gtk_adjustment_get_page_size(adjustment) > 0) sectionsResized(adjustment, self);
    }
    const grid = self.album_grid orelse return;
    const scroller = gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, grid)) orelse return;
    const adjustment = gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
    if (!(gtk.gtk_adjustment_get_page_size(adjustment) > 0)) return;
    gridResized(adjustment, self);
}

fn newList(self: *App, model: *gtk.ListModel) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupListRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindListRow), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const list = gtk.gtk_list_view_new(selectionOver(model), factory);
    gtk.gtk_widget_add_css_class(list, "album-list");
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, list), gtk.LIST_TAB_ITEM);
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, list), gtk.true_);
    _ = gtk.signalConnect(list, "activate", gtk.callback(tileActivated), self);
    watchView(self, list, .release);
    return list;
}

fn listingScroller(child: *gtk.Widget) *gtk.Widget {
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), child);
    return scroller;
}

fn showLayout(self: *App) void {
    self.albums_syncing_controls = true;
    defer self.albums_syncing_controls = false;
    for (self.album_layout_toggles) |toggles| {
        if (toggles[@intFromEnum(self.album_layout)]) |toggle| gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
    }
    const body = self.albums_body orelse return;
    const visible = gtk.gtk_stack_get_visible_child_name(body) orelse return;
    if (std.mem.eql(u8, std.mem.span(visible), "empty")) return;
    gtk.gtk_stack_set_visible_child_name(body, bodyChild(self, 1));
}

fn layoutToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_syncing_controls) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    const layout: Layout = found: for (self.album_layout_toggles) |toggles| {
        for (toggles, 0..) |candidate, index| {
            if (candidate == toggle) break :found @enumFromInt(index);
        }
    } else return;
    if (layout == self.album_layout) return;
    self.album_layout = layout;
    settings.save(self);
    if (self.album_sections.large) relist(self) else showLayout(self);
}

fn newLayoutSwitch(self: *App, set: usize) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "segmented");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    const choices = [_]struct { layout: Layout, icon: [*:0]const u8, tooltip: [*:0]const u8 }{
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
        self.album_layout_toggles[set][@intFromEnum(choice.layout)] = toggle;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(layoutToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
}
pub fn releaseAt(store: *gtk.ListStore, position: c_uint) ?i64 {
    return listedRelease(gtk.cast(gtk.ListModel, store), position);
}

fn listedRelease(model: *gtk.ListModel, position: c_uint) ?i64 {
    const item = gtk.g_list_model_get_item(model, position) orelse return null;
    defer gtk.g_object_unref(item);
    const row: *BrowseObject = @ptrCast(@alignCast(item));
    return row.id();
}

pub fn build(self: *App) *gtk.Widget {
    const model = PagedReleases.create().?;
    self.album_model = model;
    const listing_model = gtk.cast(gtk.ListModel, model);
    const grid = newGridOver(self, listing_model, gtk.callback(tileActivated));
    self.album_grid = gtk.cast(gtk.GridView, grid);
    _ = gtk.signalConnect(grid, "destroy", gtk.callback(gridDestroyed), self);
    const scroller = listingScroller(grid);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "changed",
        gtk.callback(gridResized),
        self,
    );
    const list_scroller = listingScroller(newList(self, listing_model));

    const empty = adw.adw_status_page_new();
    self.albums_empty = gtk.cast(adw.StatusPage, empty);
    adw.adw_status_page_set_icon_name(self.albums_empty.?, "media-optical-symbolic");
    adw.adw_status_page_set_title(self.albums_empty.?, "No albums yet");
    adw.adw_status_page_set_description(self.albums_empty.?, "Add a music folder in Settings › Library.");
    const body = gtk.gtk_stack_new();
    self.albums_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.albums_body.?, scroller, "grid");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, list_scroller, "list");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, empty, "empty");
    _ = gtk.gtk_stack_add_named(self.albums_body.?, newSections(self), "sections");
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    const chips = newChips(self);
    self.album_sections.chip_bar = chips;
    const facets = newFacets(self);
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), chips);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), facets);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), newScrubberOverlay(self, newStickyHeader(self, body)));
    const listing = column;

    const title = page_ui.title("Albums");
    self.albums_meta = title.meta;
    self.albums_unavailable = besideMeta(title.meta);
    self.album_sections.title_text = gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, title.title));
    self.album_sections.title_end = gtk.cast(gtk.Widget, title.end);
    var labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| labels[index] = entry.label;
    labels[sorts.len] = null;
    const sort_label = gtk.gtk_label_new("Sort by");
    gtk.gtk_widget_add_css_class(sort_label, "sort-label");
    gtk.gtk_widget_set_valign(sort_label, gtk.ALIGN_CENTER);
    const sort = gtk.gtk_drop_down_new_from_strings(&labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort albums");
    gtk.gtk_widget_add_css_class(sort, "sort-dropdown");
    gtk.gtk_widget_add_css_class(sort, "btn-dropdown");
    gtk.gtk_widget_set_valign(sort, gtk.ALIGN_CENTER);
    self.album_sort_control = gtk.cast(gtk.DropDown, sort);
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    adw.adw_wrap_box_set_child_spacing(title.end, 10);
    title.add(sort_label);
    title.add(sort);
    title.add(album_filters.build(self));
    title.add(newLayoutSwitch(self, 0));
    syncControls(self);
    showLayout(self);
    const view = page_ui.withTitle(title, listing);
    self.album_sections.page = view;
    applyForm(self);

    const navigation = adw.adw_navigation_view_new();
    self.albums_navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Albums");
    adw.adw_navigation_page_set_tag(root, "albums");
    adw.adw_navigation_view_add(self.albums_navigation.?, root);
    return navigation;
}

/// The large-library form of the page and its letter-sectioned grid: a list
/// of header rows and rows of tiles over `libraryReleaseLetterIndex`, whose
/// Releases are read a page at a time as rows are bound.
pub const Sections = struct {
    large: bool = false,
    totals: ?liborca.ReleaseTotals = null,
    buckets: []const liborca.LetterBucket = &.{},
    columns: u32 = 0,
    tile_pixels: c_int = large_tile_pixels,
    pages: [page_cache_slots]?CachedPage = @splat(null),
    clock: u64 = 0,
    model: ?*browse_model.SectionModel = null,
    view: ?*gtk.Widget = null,
    scroller: ?*gtk.Widget = null,
    resize_idle: c_uint = 0,
    sticky_idle: c_uint = 0,
    target: ?u32 = null,
    settle_tick: c_uint = 0,
    art_tick: c_uint = 0,
    art_frames: u32 = 0,
    settle_frames: u32 = 0,
    settle_still: u32 = 0,
    sticky: ?*gtk.Widget = null,
    scrubber: ?*gtk.Widget = null,
    scrubber_overlay: ?*gtk.Widget = null,
    letters: [scrubber_letters.len]?*gtk.Widget = @splat(null),
    current_letter: ?u8 = null,
    bubble: ?*gtk.Label = null,
    bubble_timer: c_uint = 0,
    hover_dim: ?*gtk.Widget = null,
    hover_play: ?*gtk.Widget = null,
    hover_more: ?*gtk.Widget = null,
    page: ?*gtk.Widget = null,
    chip_bar: ?*gtk.Widget = null,
    facet_bar: ?*gtk.Widget = null,
    title_text: ?*gtk.Widget = null,
    title_end: ?*gtk.Widget = null,
    match: ?*gtk.Label = null,
    sort_button: ?*gtk.MenuButton = null,
    sort_popover: ?*gtk.Widget = null,
    sort_checks: [sorts.len]?*gtk.CheckButton = @splat(null),

    const CachedPage = struct {
        index: u64,
        page: liborca.ReleasePage,
        used: u64,
    };

    /// Empties the model before dropping it, so a view still holding it never
    /// reads buckets freed after this.
    fn releaseModel(self: *Sections) void {
        const model = self.model orelse return;
        model.set(&.{}, 1);
        gtk.g_object_unref(model);
        self.model = null;
    }

    fn clearPages(self: *Sections) void {
        for (&self.pages) |*slot| {
            if (slot.*) |cached| cached.page.deinit();
            slot.* = null;
        }
    }

    pub fn deinit(self: *Sections, allocator: std.mem.Allocator) void {
        self.clearPages();
        self.releaseModel();
        if (self.buckets.len != 0) allocator.free(self.buckets);
        self.buckets = &.{};
        for ([_]*c_uint{ &self.resize_idle, &self.sticky_idle, &self.bubble_timer }) |source| {
            if (source.* != 0) _ = gtk.g_source_remove(source.*);
            source.* = 0;
        }
    }
};

fn sectioned(self: *const App) bool {
    return self.album_sections.large and self.album_layout == .grid and
        (self.album_sort == .title or self.album_sort == .artist);
}

fn measureLibrary(self: *App) void {
    const sections = &self.album_sections;
    sections.totals = null;
    if (self.library) |library| sections.totals = self.runtime.libraryReleaseQueryTotals(library, .{}) catch null;
    sections.large = if (sections.totals) |totals| totals.count >= large_library_albums else false;
    applyForm(self);
}

fn applyForm(self: *App) void {
    const sections = &self.album_sections;
    const large = sections.large;
    if (sections.chip_bar) |bar| gtk.gtk_widget_set_visible(bar, @intFromBool(!large));
    if (sections.facet_bar) |bar| gtk.gtk_widget_set_visible(bar, @intFromBool(large));
    if (sections.title_end) |end| gtk.gtk_widget_set_visible(end, @intFromBool(!large));
    if (sections.page) |page| {
        if (large) gtk.gtk_widget_add_css_class(page, "albums-large") else gtk.gtk_widget_remove_css_class(page, "albums-large");
    }
    const text = sections.title_text orelse return;
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, text), if (large) gtk.ORIENTATION_HORIZONTAL else gtk.ORIENTATION_VERTICAL);
    gtk.gtk_box_set_spacing(gtk.cast(gtk.Box, text), if (large) 14 else 2);
    var child = gtk.gtk_widget_get_first_child(text);
    while (child) |label| : (child = gtk.gtk_widget_get_next_sibling(label))
        gtk.gtk_widget_set_valign(label, if (large) gtk.ALIGN_BASELINE_FILL else gtk.ALIGN_FILL);
}

fn loadSections(self: *App, library: liborca.LibraryHandle) u64 {
    const buckets = self.runtime.libraryReleaseLetterIndex(library, self.allocator, request(self, 0)) catch &.{};
    setBuckets(self, buckets);
    var total: u64 = 0;
    for (buckets) |bucket| total += bucket.count;
    return total;
}

fn sectionColumns(self: *const App) u32 {
    return if (self.album_sections.columns != 0) self.album_sections.columns else 1;
}

/// Takes ownership of `buckets` and shows them from the top.
fn setBuckets(self: *App, buckets: []const liborca.LetterBucket) void {
    const sections = &self.album_sections;
    const old = sections.buckets;
    sections.clearPages();
    sections.target = null;
    sections.buckets = buckets;
    if (sections.model) |model| model.set(buckets, sectionColumns(self));
    if (old.len != 0) self.allocator.free(old);
    if (sections.scroller) |scroller|
        gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), 0);
    showLetters(self);
}

fn cachedRelease(self: *App, offset: u64) ?*const liborca.ReleaseSummary {
    const sections = &self.album_sections;
    const index = offset / app.page_size;
    const within = offset % app.page_size;
    sections.clock += 1;
    for (&sections.pages) |*slot| {
        if (slot.*) |*cached| {
            if (cached.index != index) continue;
            cached.used = sections.clock;
            return if (within < cached.page.items.len) &cached.page.items[within] else null;
        }
    }
    const library = self.library orelse return null;
    const page = self.runtime.libraryReleasePage(library, request(self, index * app.page_size)) catch return null;
    var victim = &sections.pages[0];
    for (&sections.pages) |*slot| {
        const cached = slot.* orelse {
            victim = slot;
            break;
        };
        if (cached.used < victim.*.?.used) victim = slot;
    }
    if (victim.*) |old| old.page.deinit();
    victim.* = .{ .index = index, .page = page, .used = sections.clock };
    const stored = &victim.*.?;
    return if (within < stored.page.items.len) &stored.page.items[within] else null;
}

fn pageCached(self: *const App, index: u64) bool {
    for (self.album_sections.pages) |slot| {
        if (slot) |cached| if (cached.index == index) return true;
    }
    return false;
}

fn runCached(self: *const App, run: browse_model.SectionRow.Tiles) bool {
    if (run.count == 0) return true;
    return pageCached(self, run.offset / app.page_size) and
        pageCached(self, (run.offset + run.count - 1) / app.page_size);
}

fn blankSectionTile(self: *App, tile: *gtk.Widget) void {
    setTileRelease(tile, null);
    sizeSectionTile(tile, self.album_sections.tile_pixels);
    gtk.g_object_set_data(tile, "orca-art-pending", null);
    for ([_][*:0]const u8{ "orca-title", "orca-artist" }) |key| {
        if (tilePart(tile, key)) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), " ");
    }
    const cover = tilePart(tile, "orca-cover") orelse return;
    art.clear(self, cover);
}

fn sizeSectionTile(tile: *gtk.Widget, pixels: c_int) void {
    gtk.gtk_widget_set_size_request(tile, pixels, -1);
    if (tilePart(tile, "orca-cover")) |cover| gtk.gtk_widget_set_size_request(cover, pixels, pixels);
}

fn setTileRelease(tile: *gtk.Widget, id: ?i64) void {
    const value: ?*anyopaque = if (id) |known| @ptrFromInt(@as(usize, @intCast(known))) else null;
    gtk.g_object_set_data(tile, "orca-release", value);
}

fn openTile(self: *App, tile: *gtk.Widget) void {
    const id = tileRelease(tile) orelse return;
    const navigation = self.albums_navigation orelse return;
    openAlbum(self, navigation, id);
}

fn sectionTileClicked(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    openTile(state(data), menu.gestureWidget(gesture));
}

fn sectionTileKey(controller: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const tile = menu.gestureWidget(controller);
    const shift = modifiers & gtk.MODIFIER_SHIFT != 0;
    switch (keyval) {
        gtk.KEY_Return, gtk.KEY_KP_Enter, gtk.KEY_ISO_Enter, gtk.KEY_space => openTile(self, tile),
        gtk.KEY_Menu => popupTileMenu(self, tile),
        gtk.KEY_F10 => if (shift) popupTileMenu(self, tile) else return gtk.false_,
        else => return gtk.false_,
    }
    return gtk.true_;
}

fn popupTileMenu(self: *App, tile: *gtk.Widget) void {
    const id = tileRelease(tile) orelse return;
    if (setAlbumContext(self, id)) popupBelow(self, tile);
}

/// A tile in the letter sections: a cover picture and two labels, so the
/// couple of hundred rows a list view keeps bound stay cheap to restyle and
/// rebind. Its hover actions are one shared set, `showSectionHover`.
fn newSectionTile(self: *App) *gtk.Widget {
    const pixels = self.album_sections.tile_pixels;
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_add_css_class(tile, "section-tile");
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_START);
    gtk.gtk_widget_set_focusable(tile, gtk.true_);
    gtk.gtk_widget_set_size_request(tile, pixels, -1);
    const cover = art.newPictureCover(self, pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover-frame");
    const title = tileLabel(null, "tile-title");
    const artist = tileLabel(null, "tile-artist");
    for ([_]*gtk.Widget{ cover, title, artist }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), part);
    for ([_]*gtk.Widget{ title, artist }) |label| gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1);
    gtk.g_object_set_data(tile, "orca-cover", cover);
    gtk.g_object_set_data(tile, "orca-title", title);
    gtk.g_object_set_data(tile, "orca-artist", artist);
    gtk.g_object_set_data(tile, "orca-section-tile", tile);
    menu.onSecondaryClick(tile, tileMenu, self);
    const click = gtk.gtk_gesture_click_new();
    gtk.gtk_gesture_single_set_button(gtk.cast(gtk.GestureSingle, click), 1);
    _ = gtk.signalConnect(click, "released", gtk.callback(sectionTileClicked), self);
    gtk.gtk_widget_add_controller(tile, click);
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(sectionTileKey), self);
    gtk.gtk_widget_add_controller(tile, keys);
    return tile;
}

fn bindSectionTile(self: *App, tile: *gtk.Widget, release: *const liborca.ReleaseSummary) void {
    var buffer: [512]u8 = undefined;
    const name = if (release.title.len != 0) release.title else "Untitled";
    setTileRelease(tile, release.id);
    sizeSectionTile(tile, self.album_sections.tile_pixels);
    if (tilePart(tile, "orca-title")) |title| gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), strings.format(&buffer, "{s}", .{name}).ptr);
    if (tilePart(tile, "orca-artist")) |artist| gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), strings.format(&buffer, "{s}", .{release.album_artist}).ptr);
    const label = strings.format(&buffer, "{s} by {s}", .{ name, if (release.album_artist.len != 0) release.album_artist else "Unknown Artist" });
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, tile), gtk.ACCESSIBLE_PROPERTY_LABEL, label.ptr, @as(c_int, -1));
    showPlaying(tile, self.playing().matches(.release, release.id));
    offline.markTile(self, tile, release.id);
    const cover = tilePart(tile, "orca-cover") orelse return;
    const key = art.Key.release(release.id, sectionArtSize(self));
    if (art.cached(self, key)) {
        gtk.g_object_set_data(tile, "orca-art-pending", null);
        return art.show(self, cover, key);
    }
    art.clear(self, cover);
    gtk.g_object_set_data(tile, "orca-art-pending", tile);
    queueSectionArt(self);
}

fn sectionArtSize(self: *const App) art.Size {
    return coverArtSize(self.album_sections.view, self.album_sections.tile_pixels);
}

pub fn coverArtSize(view: ?*gtk.Widget, tile_pixels: c_int) art.Size {
    const shown = view orelse return .tile;
    return art.Size.atLeast(tile_pixels * gtk.gtk_widget_get_scale_factor(shown));
}

fn queueSectionArt(self: *App) void {
    const sections = &self.album_sections;
    const view = sections.view orelse return;
    sections.art_frames = 0;
    if (sections.art_tick == 0) sections.art_tick = gtk.gtk_widget_add_tick_callback(view, showSectionArt, self, null);
}

fn showSectionArt(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const sections = &self.album_sections;
    const view = sections.view orelse {
        sections.art_tick = 0;
        return gtk.SOURCE_REMOVE;
    };
    const Visible = struct { app_state: *App, view: *gtk.Widget, top: f32, bottom: f32, waiting: bool = false, fetched: bool = false };
    const height: f32 = @floatFromInt(gtk.gtk_widget_get_height(view));
    var range: Visible = .{ .app_state = self, .view = view, .top = 0, .bottom = height };
    const visitor = struct {
        fn visit(visible: *Visible, row: *gtk.Widget) bool {
            const tiles = tilePart(row, "orca-section-tiles") orelse return true;
            const cell = gtk.gtk_widget_get_parent(row) orelse return true;
            var bounds: gtk.Rect = undefined;
            const pending = gtk.g_object_get_data(row, "orca-section-pending") != null;
            if (gtk.gtk_widget_compute_bounds(cell, visible.view, &bounds) == 0 or !(bounds.height > 0)) {
                visible.waiting = visible.waiting or pending or pendingArt(tiles);
                return true;
            }
            if (bounds.y + bounds.height < visible.top or bounds.y > visible.bottom) return true;
            if (pending) fill: {
                const section = rowSection(row) orelse break :fill;
                const cached = switch (section) {
                    .tiles => |run| runCached(visible.app_state, run),
                    .header => true,
                };
                if (!cached and visible.fetched) {
                    visible.waiting = true;
                    return true;
                }
                visible.fetched = visible.fetched or !cached;
                fillSectionRow(visible.app_state, row, section, true);
            }
            var child = gtk.gtk_widget_get_first_child(tiles);
            while (child) |tile| : (child = gtk.gtk_widget_get_next_sibling(tile)) {
                if (gtk.g_object_get_data(tile, "orca-art-pending") == null) continue;
                gtk.g_object_set_data(tile, "orca-art-pending", null);
                const id = tileRelease(tile) orelse continue;
                const cover = tilePart(tile, "orca-cover") orelse continue;
                art.show(visible.app_state, cover, art.Key.release(id, sectionArtSize(visible.app_state)));
            }
            return true;
        }
    }.visit;
    if (height > 0) {
        eachSectionRow(self, &range, visitor);
        range.top = -height;
        range.bottom = 2 * height;
        eachSectionRow(self, &range, visitor);
    }
    sections.art_frames += 1;
    if ((range.waiting or !(height > 0)) and sections.art_frames < section_art_frames) return gtk.SOURCE_CONTINUE;
    sections.art_tick = 0;
    return gtk.SOURCE_REMOVE;
}

fn pendingArt(tiles: *gtk.Widget) bool {
    var child = gtk.gtk_widget_get_first_child(tiles);
    while (child) |tile| : (child = gtk.gtk_widget_get_next_sibling(tile)) {
        if (gtk.g_object_get_data(tile, "orca-art-pending") != null and gtk.gtk_widget_get_visible(tile) != 0) return true;
    }
    return false;
}

fn newSectionHeader() *gtk.Widget {
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(header, "section-header");
    const letter = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(letter, "section-letter");
    const count = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(count, "section-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    for ([_]*gtk.Widget{ letter, count }) |label| {
        gtk.gtk_widget_set_valign(label, gtk.ALIGN_BASELINE_FILL);
        gtk.gtk_box_append(gtk.cast(gtk.Box, header), label);
    }
    gtk.g_object_set_data(header, "orca-section-letter", letter);
    gtk.g_object_set_data(header, "orca-section-count", count);
    return header;
}

fn showSectionHeader(header: *gtk.Widget, bucket: liborca.LetterBucket) void {
    const letter: [1:0]u8 = .{bucket.letter};
    if (tilePart(header, "orca-section-letter")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), &letter);
    var buffer: [48]u8 = undefined;
    if (tilePart(header, "orca-section-count")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), strings.format(&buffer, "{f} {s}", .{
        strings.grouped(bucket.count),
        if (bucket.count == 1) "album" else "albums",
    }).ptr);
}

fn setupSectionRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    gtk.gtk_list_item_set_activatable(list_item, gtk.false_);
    gtk.gtk_list_item_set_selectable(list_item, gtk.false_);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(row, "section-row");
    const header = newSectionHeader();
    const tiles = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, section_column_gap);
    gtk.gtk_widget_add_css_class(tiles, "section-tiles");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), tiles);
    gtk.g_object_set_data(row, "orca-list-item", item);
    gtk.g_object_set_data(row, "orca-section-header", header);
    gtk.g_object_set_data(row, "orca-section-tiles", tiles);
    gtk.gtk_list_item_set_child(list_item, row);
}

fn rowSection(row: *gtk.Widget) ?browse_model.SectionRow {
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    const entry: *BrowseObject = @ptrCast(@alignCast(object));
    return entry.section();
}

fn fillSectionRow(self: *App, row: *gtk.Widget, section: browse_model.SectionRow, fetch: bool) void {
    const header = tilePart(row, "orca-section-header") orelse return;
    const tiles = tilePart(row, "orca-section-tiles") orelse return;
    const buckets = self.album_sections.buckets;
    gtk.g_object_set_data(row, "orca-section-pending", null);
    switch (section) {
        .header => |index| {
            gtk.gtk_widget_set_visible(tiles, gtk.false_);
            gtk.gtk_widget_set_visible(header, gtk.true_);
            if (index < buckets.len) showSectionHeader(header, buckets[index]);
        },
        .tiles => |run| {
            gtk.gtk_widget_set_visible(header, gtk.false_);
            gtk.gtk_widget_set_visible(tiles, gtk.true_);
            const ready = fetch or runCached(self, run);
            var next = gtk.gtk_widget_get_first_child(tiles);
            var index: u32 = 0;
            while (index < run.count) : (index += 1) {
                const tile = next orelse made: {
                    const made = newSectionTile(self);
                    gtk.gtk_box_append(gtk.cast(gtk.Box, tiles), made);
                    break :made made;
                };
                next = gtk.gtk_widget_get_next_sibling(tile);
                if (!ready) {
                    gtk.gtk_widget_set_visible(tile, gtk.true_);
                    blankSectionTile(self, tile);
                    continue;
                }
                const release = cachedRelease(self, run.offset + index) orelse {
                    gtk.gtk_widget_set_visible(tile, gtk.false_);
                    setTileRelease(tile, null);
                    continue;
                };
                gtk.gtk_widget_set_visible(tile, gtk.true_);
                bindSectionTile(self, tile, release);
            }
            while (next) |extra| : (next = gtk.gtk_widget_get_next_sibling(extra)) {
                gtk.gtk_widget_set_visible(extra, gtk.false_);
                setTileRelease(extra, null);
                if (tilePart(extra, "orca-cover")) |cover| art.forget(self, cover);
            }
            if (!ready) {
                gtk.g_object_set_data(row, "orca-section-pending", row);
                queueSectionArt(self);
            }
        },
    }
}

fn bindSectionRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    fillSectionRow(state(data), row, rowSection(row) orelse return, false);
}

fn unbindSectionRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const tiles = tilePart(row, "orca-section-tiles") orelse return;
    var child = gtk.gtk_widget_get_first_child(tiles);
    while (child) |tile| : (child = gtk.gtk_widget_get_next_sibling(tile)) {
        if (tilePart(tile, "orca-cover")) |cover| art.forget(self, cover);
    }
}

fn eachSectionRow(self: *App, context: anytype, comptime visit: fn (@TypeOf(context), *gtk.Widget) bool) void {
    const view = self.album_sections.view orelse return;
    var child = gtk.gtk_widget_get_first_child(view);
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        if (gtk.gtk_widget_get_mapped(cell) == 0) continue;
        const row = gtk.gtk_widget_get_first_child(cell) orelse continue;
        if (gtk.g_object_get_data(row, "orca-section-tiles") == null) continue;
        if (!visit(context, row)) return;
    }
}

fn markSections(self: *App) void {
    eachSectionRow(self, self, struct {
        fn visit(app_state: *App, row: *gtk.Widget) bool {
            const tiles = tilePart(row, "orca-section-tiles") orelse return true;
            const playing = app_state.playing();
            var child = gtk.gtk_widget_get_first_child(tiles);
            while (child) |tile| : (child = gtk.gtk_widget_get_next_sibling(tile))
                showPlaying(tile, playing.matches(.release, tileRelease(tile)));
            return true;
        }
    }.visit);
}

fn refreshSections(self: *App) void {
    self.album_sections.clearPages();
    eachSectionRow(self, self, struct {
        fn visit(app_state: *App, row: *gtk.Widget) bool {
            fillSectionRow(app_state, row, rowSection(row) orelse return true, false);
            return true;
        }
    }.visit);
}

fn rowTop(self: *App, position: u32) ?f32 {
    const Search = struct { app_state: *App, position: u32, top: ?f32 = null };
    var search: Search = .{ .app_state = self, .position = position };
    eachSectionRow(self, &search, struct {
        fn visit(found: *Search, row: *gtk.Widget) bool {
            const item = gtk.g_object_get_data(row, "orca-list-item") orelse return true;
            if (gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item)) != found.position) return true;
            const view = found.app_state.album_sections.view orelse return false;
            const cell = gtk.gtk_widget_get_parent(row) orelse return false;
            var bounds: gtk.Rect = undefined;
            if (gtk.gtk_widget_compute_bounds(cell, view, &bounds) != 0) found.top = bounds.y;
            return false;
        }
    }.visit);
    return search.top;
}

fn topBucket(self: *App) ?usize {
    const Search = struct { app_state: *App, bucket: ?usize = null, best: f32 = std.math.floatMax(f32) };
    var search: Search = .{ .app_state = self };
    eachSectionRow(self, &search, struct {
        fn visit(found: *Search, row: *gtk.Widget) bool {
            const view = found.app_state.album_sections.view orelse return false;
            const cell = gtk.gtk_widget_get_parent(row) orelse return true;
            var bounds: gtk.Rect = undefined;
            if (gtk.gtk_widget_compute_bounds(cell, view, &bounds) == 0) return true;
            if (!(bounds.height > 0) or bounds.y + bounds.height <= 1) return true;
            if (bounds.y >= found.best) return true;
            found.best = bounds.y;
            found.bucket = switch (rowSection(row) orelse return true) {
                .header => |bucket| bucket,
                .tiles => |run| run.bucket,
            };
            return true;
        }
    }.visit);
    return search.bucket;
}

fn sectionAdjustment(self: *App) ?*gtk.Adjustment {
    const scroller = self.album_sections.scroller orelse return null;
    return gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
}

/// `gtk_list_view_scroll_to` only brings a row into view, and rows not yet
/// measured have estimated heights, so the top of the row is measured each
/// frame and the list moved by what is left until it sits at the top. A row
/// made this frame reads 0 before its first allocation, so the top must hold
/// for two frames.
fn settleScroll(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const sections = &self.album_sections;
    const target = sections.target orelse return stopSettling(sections);
    sections.settle_frames += 1;
    if (sections.settle_frames > scroll_settle_frames) return stopSettling(sections);
    const adjustment = sectionAdjustment(self) orelse return stopSettling(sections);
    const top = rowTop(self, target) orelse {
        sections.settle_still = 0;
        if (sections.view) |view| gtk.gtk_list_view_scroll_to(gtk.cast(gtk.ListView, view), target, gtk.LIST_SCROLL_NONE, null);
        return gtk.SOURCE_CONTINUE;
    };
    if (@abs(top) < 1) {
        sections.settle_still += 1;
        return if (sections.settle_still >= 2) stopSettling(sections) else gtk.SOURCE_CONTINUE;
    }
    sections.settle_still = 0;
    const value = gtk.gtk_adjustment_get_value(adjustment);
    gtk.gtk_adjustment_set_value(adjustment, value + top);
    if (gtk.gtk_adjustment_get_value(adjustment) == value) return stopSettling(sections);
    return gtk.SOURCE_CONTINUE;
}

fn stopSettling(sections: *Sections) gtk.gboolean {
    sections.target = null;
    sections.settle_tick = 0;
    return gtk.SOURCE_REMOVE;
}

fn scrollToBucket(self: *App, bucket: usize) void {
    const sections = &self.album_sections;
    const view = sections.view orelse return;
    if (bucket >= sections.buckets.len) return;
    const position = browse_model.sectionHeaderPosition(sections.buckets, sectionColumns(self), bucket);
    gtk.gtk_list_view_scroll_to(gtk.cast(gtk.ListView, view), position, gtk.LIST_SCROLL_NONE, null);
    sections.target = position;
    sections.settle_frames = 0;
    sections.settle_still = 0;
    if (sections.settle_tick == 0) sections.settle_tick = gtk.gtk_widget_add_tick_callback(view, settleScroll, self, null);
    markLetter(self, sections.buckets[bucket].letter);
}

fn sectionsScrolled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    showSectionHover(self, null);
    queueSectionArt(self);
    if (self.album_sections.sticky_idle == 0) self.album_sections.sticky_idle = gtk.g_idle_add(showStickyLater, self);
}

fn showStickyLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.album_sections.sticky_idle = 0;
    showSticky(self);
    return gtk.SOURCE_REMOVE;
}

fn showSticky(self: *App) void {
    const sections = &self.album_sections;
    const sticky = sections.sticky orelse return;
    const adjustment = sectionAdjustment(self) orelse return;
    const bucket = topBucket(self);
    const shown = sectioned(self) and sections.buckets.len != 0 and bucket != null and gtk.gtk_adjustment_get_value(adjustment) > 0.5;
    gtk.gtk_widget_set_visible(sticky, @intFromBool(shown));
    const index = bucket orelse return;
    if (index >= sections.buckets.len) return;
    showSectionHeader(sticky, sections.buckets[index]);
    if (sections.target == null) markLetter(self, sections.buckets[index].letter);
}

fn sectionsResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const sections = &self.album_sections;
    const width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    if (!(width > 0)) return;
    const gap: f64 = section_column_gap;
    const minimum: f64 = @floatFromInt(@max(@divTrunc(self.appearance.album_grid_tile * large_tile_pixels, app.default_album_tile_pixels), min_tile_pixels));
    const columns: u32 = @intFromFloat(@max(@floor((width + gap) / (minimum + gap)), 1));
    const count: f64 = @floatFromInt(columns);
    const pixels: c_int = @intFromFloat(@floor((width - (count - 1) * gap) / count));
    if (columns == sections.columns and pixels == sections.tile_pixels) return;
    sections.columns = columns;
    sections.tile_pixels = pixels;
    if (sections.resize_idle == 0) sections.resize_idle = gtk.g_idle_add(applySectionColumns, self);
}

fn applySectionColumns(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const sections = &self.album_sections;
    sections.resize_idle = 0;
    const model = sections.model orelse return gtk.SOURCE_REMOVE;
    if (model.columns() != sectionColumns(self))
        model.set(sections.buckets, sectionColumns(self))
    else
        refreshSections(self);
    return gtk.SOURCE_REMOVE;
}

fn sectionsDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const sections = &self.album_sections;
    for ([_]*c_uint{ &sections.resize_idle, &sections.sticky_idle, &sections.bubble_timer }) |source| {
        if (source.* != 0) _ = gtk.g_source_remove(source.*);
        source.* = 0;
    }
    sections.view = null;
    sections.scroller = null;
    sections.sticky = null;
    sections.scrubber = null;
    sections.bubble = null;
    sections.hover_dim = null;
    sections.hover_play = null;
    sections.hover_more = null;
    sections.settle_tick = 0;
    sections.art_tick = 0;
}

fn sectionsPressed(_: ?*anyopaque, _: c_int, _: f64, _: f64, view: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, view.?));
}

fn newSections(self: *App) *gtk.Widget {
    const sections = &self.album_sections;
    sections.releaseModel();
    const model = browse_model.newSectionModel().?;
    sections.model = model;
    model.set(sections.buckets, sectionColumns(self));
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupSectionRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindSectionRow), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindSectionRow), self);
    const selection = gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(model)));
    const view = gtk.gtk_list_view_new(selection, factory);
    gtk.gtk_widget_add_css_class(view, "album-sections");
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, view), gtk.LIST_TAB_ITEM);
    const click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(click, "pressed", gtk.callback(sectionsPressed), view);
    gtk.gtk_widget_add_controller(view, click);
    sections.view = view;
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_EXTERNAL, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    sections.scroller = scroller;
    _ = gtk.signalConnect(gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), "changed", gtk.callback(sectionsResized), self);
    _ = gtk.signalConnect(gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), "value-changed", gtk.callback(sectionsScrolled), self);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(sectionsDestroyed), self);
    return scroller;
}

fn newStickyHeader(self: *App, body: *gtk.Widget) *gtk.Widget {
    const overlay = gtk.gtk_overlay_new();
    gtk.gtk_widget_set_vexpand(overlay, gtk.true_);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, overlay), body);
    const sticky = newSectionHeader();
    gtk.gtk_widget_add_css_class(sticky, "section-sticky");
    gtk.gtk_widget_set_valign(sticky, gtk.ALIGN_START);
    gtk.gtk_widget_set_can_target(sticky, gtk.false_);
    gtk.gtk_widget_set_visible(sticky, gtk.false_);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), sticky);
    self.album_sections.sticky = sticky;
    return overlay;
}

fn showSectionChrome(self: *App, listed: bool) void {
    const sections = &self.album_sections;
    const shown = sectioned(self) and listed;
    if (sections.scrubber) |scrubber| gtk.gtk_widget_set_visible(scrubber, @intFromBool(shown));
    if (!shown) {
        if (sections.sticky) |sticky| gtk.gtk_widget_set_visible(sticky, gtk.false_);
    } else showSticky(self);
}

fn bucketOfLetter(self: *const App, letter: u8) ?usize {
    const buckets = self.album_sections.buckets;
    if (buckets.len == 0) return null;
    for (buckets, 0..) |bucket, index| {
        if (bucket.letter >= letter) return index;
    }
    return buckets.len - 1;
}

fn showLetters(self: *App) void {
    const sections = &self.album_sections;
    sections.current_letter = null;
    for (sections.letters, scrubber_letters) |maybe_label, letter| {
        const label = maybe_label orelse continue;
        gtk.gtk_widget_remove_css_class(label, "current");
        const present = for (sections.buckets) |bucket| {
            if (bucket.letter == letter) break true;
        } else false;
        if (present) gtk.gtk_widget_remove_css_class(label, "absent") else gtk.gtk_widget_add_css_class(label, "absent");
    }
}

fn markLetter(self: *App, letter: u8) void {
    const sections = &self.album_sections;
    if (sections.current_letter == letter) return;
    sections.current_letter = letter;
    for (sections.letters, scrubber_letters) |maybe_label, candidate| {
        const label = maybe_label orelse continue;
        if (candidate == letter) gtk.gtk_widget_add_css_class(label, "current") else gtk.gtk_widget_remove_css_class(label, "current");
    }
}

fn showBubble(self: *App, letter: u8, y: f64) void {
    const sections = &self.album_sections;
    const bubble = sections.bubble orelse return;
    const scrubber = sections.scrubber orelse return;
    const overlay = sections.scrubber_overlay orelse return;
    const text: [1:0]u8 = .{letter};
    gtk.gtk_label_set_text(bubble, &text);
    var bounds: gtk.Rect = undefined;
    const top: f64 = if (gtk.gtk_widget_compute_bounds(scrubber, overlay, &bounds) != 0) bounds.y else 0;
    const half: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_height(gtk.cast(gtk.Widget, bubble)), 2));
    gtk.gtk_widget_set_margin_top(gtk.cast(gtk.Widget, bubble), @intFromFloat(@max(top + y - half, 0)));
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, bubble), "shown");
    if (sections.bubble_timer != 0) _ = gtk.g_source_remove(sections.bubble_timer);
    sections.bubble_timer = 0;
}

fn hideBubbleLater(self: *App) void {
    const sections = &self.album_sections;
    if (sections.bubble_timer != 0) _ = gtk.g_source_remove(sections.bubble_timer);
    sections.bubble_timer = gtk.g_timeout_add(scrub_bubble_ms, hideBubble, self);
}

fn hideBubble(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.album_sections.bubble_timer = 0;
    if (self.album_sections.bubble) |bubble| gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, bubble), "shown");
    return gtk.SOURCE_REMOVE;
}

fn scrubTo(self: *App, y: f64) void {
    const scrubber = self.album_sections.scrubber orelse return;
    const height: f64 = @floatFromInt(gtk.gtk_widget_get_height(scrubber));
    if (!(height > 0)) return;
    const slots: f64 = @floatFromInt(scrubber_letters.len);
    const slot: usize = @intFromFloat(std.math.clamp(@floor(y / height * slots), 0, slots - 1));
    const bucket = bucketOfLetter(self, scrubber_letters[slot]) orelse return;
    scrollToBucket(self, bucket);
    showBubble(self, self.album_sections.buckets[bucket].letter, std.math.clamp(y, 0, height));
}

fn scrubBegin(_: ?*anyopaque, _: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.album_sections.scrubber) |scrubber| _ = gtk.gtk_widget_grab_focus(scrubber);
    scrubTo(self, y);
}

fn scrubUpdate(gesture: ?*anyopaque, _: f64, offset_y: f64, data: ?*anyopaque) callconv(.c) void {
    var start_y: f64 = 0;
    if (gtk.gtk_gesture_drag_get_start_point(gtk.cast(gtk.Gesture, gesture.?), null, &start_y) == 0) return;
    scrubTo(state(data), start_y + offset_y);
}

fn scrubEnd(_: ?*anyopaque, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    hideBubbleLater(state(data));
}

fn scrubKey(_: ?*anyopaque, keyval: c_uint, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const sections = &self.album_sections;
    if (sections.buckets.len == 0) return gtk.false_;
    const current = if (sections.current_letter) |letter| bucketOfLetter(self, letter) orelse 0 else 0;
    const bucket: usize = switch (keyval) {
        gtk.KEY_Up => current -| 1,
        gtk.KEY_Down => @min(current + 1, sections.buckets.len - 1),
        gtk.KEY_Home => 0,
        gtk.KEY_End => sections.buckets.len - 1,
        else => return gtk.false_,
    };
    scrollToBucket(self, bucket);
    const letter = sections.buckets[bucket].letter;
    const slot = std.mem.indexOfScalar(u8, scrubber_letters, letter) orelse 0;
    if (sections.letters[slot]) |label| {
        var bounds: gtk.Rect = undefined;
        const scrubber = sections.scrubber orelse return gtk.true_;
        if (gtk.gtk_widget_compute_bounds(label, scrubber, &bounds) != 0) showBubble(self, letter, bounds.y + bounds.height / 2);
    }
    hideBubbleLater(self);
    return gtk.true_;
}

fn newScrubberOverlay(self: *App, listing: *gtk.Widget) *gtk.Widget {
    const sections = &self.album_sections;
    const overlay = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, overlay), listing);
    sections.scrubber_overlay = overlay;

    const scrubber = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(scrubber, "letter-scrubber");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, scrubber), gtk.true_);
    gtk.gtk_widget_set_halign(scrubber, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(scrubber, gtk.ALIGN_FILL);
    gtk.gtk_widget_set_focusable(scrubber, gtk.true_);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, scrubber), gtk.ACCESSIBLE_PROPERTY_LABEL, "Jump to letter", @as(c_int, -1));
    for (scrubber_letters, 0..) |letter, index| {
        const text: [1:0]u8 = .{letter};
        const label = gtk.gtk_label_new(&text);
        gtk.gtk_widget_add_css_class(label, "scrub-letter");
        gtk.gtk_widget_set_vexpand(label, gtk.true_);
        gtk.gtk_box_append(gtk.cast(gtk.Box, scrubber), label);
        sections.letters[index] = label;
    }
    const drag = gtk.gtk_gesture_drag_new();
    _ = gtk.signalConnect(drag, "drag-begin", gtk.callback(scrubBegin), self);
    _ = gtk.signalConnect(drag, "drag-update", gtk.callback(scrubUpdate), self);
    _ = gtk.signalConnect(drag, "drag-end", gtk.callback(scrubEnd), self);
    gtk.gtk_widget_add_controller(scrubber, drag);
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(scrubKey), self);
    gtk.gtk_widget_add_controller(scrubber, keys);
    gtk.gtk_widget_set_visible(scrubber, gtk.false_);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), scrubber);
    sections.scrubber = scrubber;

    const bubble = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(bubble, "scrub-bubble");
    gtk.gtk_widget_set_halign(bubble, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(bubble, gtk.ALIGN_START);
    gtk.gtk_widget_set_can_target(bubble, gtk.false_);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), bubble);
    sections.bubble = gtk.cast(gtk.Label, bubble);
    newSectionHover(self, overlay);
    showLetters(self);
    return overlay;
}

fn newSectionHover(self: *App, overlay: *gtk.Widget) void {
    const sections = &self.album_sections;
    const dim = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(dim, "section-hover-dim");
    gtk.gtk_widget_set_can_target(dim, gtk.false_);
    const play = gtk.gtk_button_new_from_icon_name("orca-play-symbolic");
    gtk.gtk_widget_add_css_class(play, "tile-play");
    gtk.gtk_widget_add_css_class(play, "circular");
    gtk.gtk_widget_set_size_request(play, hover_play_pixels, hover_play_pixels);
    gtk.gtk_widget_set_tooltip_text(play, "Play Album");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, play), gtk.ACCESSIBLE_PROPERTY_LABEL, "Play Album", @as(c_int, -1));
    _ = gtk.signalConnect(play, "clicked", gtk.callback(tilePlayClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "section-hover-more");
    gtk.gtk_widget_add_css_class(more, "circular");
    gtk.gtk_widget_set_size_request(more, hover_more_pixels, hover_more_pixels);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, more), gtk.ACCESSIBLE_PROPERTY_LABEL, "More", @as(c_int, -1));
    _ = gtk.signalConnect(more, "clicked", gtk.callback(tileMoreClicked), self);
    for ([_]*gtk.Widget{ dim, play, more }) |part| {
        gtk.gtk_widget_set_halign(part, gtk.ALIGN_START);
        gtk.gtk_widget_set_valign(part, gtk.ALIGN_START);
        gtk.gtk_widget_set_visible(part, gtk.false_);
        gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), part);
    }
    sections.hover_dim = dim;
    sections.hover_play = play;
    sections.hover_more = more;
    const pointer = gtk.gtk_event_controller_motion_new();
    _ = gtk.signalConnect(pointer, "motion", gtk.callback(sectionsHovered), self);
    _ = gtk.signalConnect(pointer, "leave", gtk.callback(sectionsLeft), self);
    gtk.gtk_widget_add_controller(overlay, pointer);
}

fn sectionsHovered(_: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    showSectionHover(self, sectionTileAt(self, x, y));
}

fn sectionsLeft(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showSectionHover(state(data), null);
}

fn sectionTileAt(self: *App, x: f64, y: f64) ?*gtk.Widget {
    const sections = &self.album_sections;
    const overlay = sections.scrubber_overlay orelse return null;
    const view = sections.view orelse return null;
    var bounds: gtk.Rect = undefined;
    if (gtk.gtk_widget_compute_bounds(view, overlay, &bounds) == 0) return null;
    var widget = gtk.gtk_widget_pick(view, x - bounds.x, y - bounds.y, 0);
    while (widget) |current| : (widget = gtk.gtk_widget_get_parent(current)) {
        if (current == view) return null;
        if (gtk.g_object_get_data(current, "orca-section-tile") != null) return current;
    }
    return null;
}

/// Lays the shared dim, play and more buttons over `tile`'s cover, or hides
/// them. They sit in the listing's overlay rather than in each tile.
fn showSectionHover(self: *App, tile: ?*gtk.Widget) void {
    const sections = &self.album_sections;
    const dim = sections.hover_dim orelse return;
    const play = sections.hover_play orelse return;
    const more = sections.hover_more orelse return;
    const overlay = sections.scrubber_overlay orelse return;
    var bounds: gtk.Rect = undefined;
    const release = place: {
        const shown = tile orelse break :place null;
        const id = tileRelease(shown) orelse break :place null;
        const cover = tilePart(shown, "orca-cover") orelse break :place null;
        if (gtk.gtk_widget_compute_bounds(cover, overlay, &bounds) == 0) break :place null;
        break :place id;
    };
    const value: ?*anyopaque = if (release) |id| @ptrFromInt(@as(usize, @intCast(id))) else null;
    for ([_]*gtk.Widget{ dim, play, more }) |part| {
        gtk.gtk_widget_set_visible(part, @intFromBool(release != null));
        gtk.g_object_set_data(part, "orca-release", value);
    }
    if (release == null) return;
    const left: c_int = @intFromFloat(@round(bounds.x));
    const top: c_int = @intFromFloat(@round(bounds.y));
    const width: c_int = @intFromFloat(@round(bounds.width));
    const height: c_int = @intFromFloat(@round(bounds.height));
    gtk.gtk_widget_set_size_request(dim, width, height);
    const corner = 6;
    for ([_]struct { *gtk.Widget, c_int, c_int }{
        .{ dim, left, top },
        .{ play, left + @divTrunc(width - hover_play_pixels, 2), top + @divTrunc(height - hover_play_pixels, 2) },
        .{ more, left + width - hover_more_pixels - corner, top + height - hover_more_pixels - corner },
    }) |placed| {
        gtk.gtk_widget_set_margin_start(placed[0], @max(placed[1], 0));
        gtk.gtk_widget_set_margin_top(placed[0], @max(placed[2], 0));
    }
}

fn newSortButton(self: *App) *gtk.Widget {
    const sections = &self.album_sections;
    const options = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(options, "facet-options");
    var group: ?*gtk.CheckButton = null;
    for (sorts, 0..) |entry, index| {
        const check = gtk.gtk_check_button_new_with_label(entry.label);
        const button = gtk.cast(gtk.CheckButton, check);
        gtk.gtk_check_button_set_group(button, group);
        group = group orelse button;
        sections.sort_checks[index] = button;
        _ = gtk.signalConnect(check, "toggled", gtk.callback(sortChecked), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, options), check);
    }
    const popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), options);
    sections.sort_popover = popover;
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_label(gtk.cast(gtk.MenuButton, button), "Sort");
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, button), gtk.true_);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "facet-sort");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, "Sort albums");
    sections.sort_button = gtk.cast(gtk.MenuButton, button);
    return button;
}

fn newFacets(self: *App) *gtk.Widget {
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(bar, "album-facets");
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), album_filters.buildFacets(self));
    const match = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(match, "facet-match");
    gtk.gtk_widget_add_css_class(match, "numeric");
    gtk.gtk_widget_set_visible(match, gtk.false_);
    gtk.gtk_widget_set_hexpand(match, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, match), 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), match);
    self.album_sections.match = gtk.cast(gtk.Label, match);
    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_hexpand(end, gtk.true_);
    gtk.gtk_widget_set_halign(end, gtk.ALIGN_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, end), newSortButton(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, end), newLayoutSwitch(self, 1));
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), end);
    gtk.gtk_widget_set_visible(bar, gtk.false_);
    self.album_sections.facet_bar = bar;
    return bar;
}

/// What an open album page plays: its tracks in listening order, and whose
/// they are, index-aligned.
pub const AlbumPage = struct {
    self: *App,
    navigation: *adw.NavigationView,
    ids: []i64,
    tracks: []feedback.Target,
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
    pushed: ?*adw.NavigationPage = null,
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
    allocator.free(page.tracks);
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
        for (page.tracks, page.rows) |*track, maybe_row| {
            const recording = track.recording_id orelse continue;
            if (!changed.contains(recording)) continue;
            switch (change) {
                .feedback => |value| {
                    track.feedback = value;
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
    markViews(self);
    markSections(self);
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
    self.context.addTrack(self.allocator, page.ids[position], page.tracks[position].recording_id, page.tracks[position].feedback) catch return false;
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

fn trackKeyPressed(controller: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const page = pageData(data);
    const key = menu.trackKey(keyval, modifiers) orelse return gtk.false_;
    if (!window.plainKeysApply(page.self)) return gtk.false_;
    const list = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, controller.?));
    const row = gtk.gtk_list_box_get_selected_row(gtk.cast(gtk.ListBox, list)) orelse return gtk.false_;
    const position = rowPosition(gtk.cast(gtk.Widget, row)) orelse return gtk.false_;
    if (!setTrackContext(page, position)) return gtk.false_;
    menu.runTrackKey(page.self, key);
    return gtk.true_;
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
    artist_page.openArtist(page.self, page.navigation, id);
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
    if (marked == 0 or marked > page.tracks.len) return;
    feedback.toggle(page.self, page.tracks[marked - 1]);
}

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const stars = ratings.starsOf(button) orelse return;
    const marked = @intFromPtr(gtk.g_object_get_data(stars, "orca-position"));
    if (marked == 0 or marked > page.tracks.len) return;
    ratings.change(page.self, &.{page.tracks[marked - 1]}, ratings.chosen(button));
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
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number_label), 0.0);
    gtk.gtk_widget_add_css_class(number_label, "numeric");
    gtk.gtk_widget_add_css_class(number_label, "album-track-number");
    const playing_glyph = gtk.gtk_image_new_from_icon_name("orca-play-symbolic");
    gtk.gtk_widget_set_halign(playing_glyph, gtk.ALIGN_START);
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
    const more = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
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
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 0.0);
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
    const chooser = gtk.gtk_button_new_from_icon_name("orca-columns-symbolic");
    gtk.gtk_widget_add_css_class(chooser, "flat");
    gtk.gtk_widget_add_css_class(chooser, "column-chooser");
    gtk.gtk_widget_set_tooltip_text(chooser, "Choose Columns");
    gtk.gtk_widget_set_valign(chooser, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(chooser, "clicked", gtk.callback(columnChooserClicked), page.self);
    const duration = gtk.gtk_image_new_from_icon_name("preferences-system-time-symbolic");
    gtk.gtk_widget_set_tooltip_text(duration, "Duration");
    gtk.gtk_widget_set_halign(duration, gtk.ALIGN_END);
    gtk.gtk_widget_set_hexpand(duration, gtk.true_);
    const duration_column = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_size_request(duration_column, duration_column_pixels, -1);
    gtk.gtk_widget_set_hexpand(duration_column, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, duration_column), duration);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), chooser);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), duration_column);
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
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    const year = releaseYear(release);
    if (year.len != 0) {
        writeMarkup(&writer, year);
        writer.writeAll(meta_separator) catch {};
    }
    if (genres) |found| if (found.items.len != 0) {
        for (found.items, 0..) |genre, index| {
            if (index != 0) writer.writeAll(" / ") catch {};
            writeMarkup(&writer, genre.name);
        }
        writer.writeAll(meta_separator) catch {};
    };
    var tracks: [32]u8 = undefined;
    writer.print("{s}" ++ meta_separator ++ "{d} min", .{ plural(&tracks, page.ids.len, "track", "tracks"), minutesOf(release.total_duration_ms) }) catch {};
    buffer[writer.end] = 0;
    gtk.gtk_label_set_markup(gtk.cast(gtk.Label, label), buffer[0..writer.end :0].ptr);
}

fn writeMarkup(writer: *std.Io.Writer, text: []const u8) void {
    const escaped = gtk.g_markup_escape_text(text.ptr, @intCast(text.len));
    defer gtk.g_free(escaped);
    writer.writeAll(std.mem.span(escaped)) catch {};
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
    const library = self.library orelse return;
    if (info.pending_count == info.pending.len) return self.toast("Too many album lookups are running; reopen this album shortly");
    const job = self.runtime.startReleaseInfoFetch(library, release_id, .{}) catch
        return self.toast("Could not look this album up");
    info.requested.put(self.allocator, release_id, {}) catch {};
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
        const outcome = self.runtime.jobReleaseInfoOutcome(pending.job) catch .not_requested;
        if (!artist_page.infoSettled(outcome)) _ = info.requested.remove(pending.release_id);
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

pub fn forgetLibrary(self: *App) void {
    const info = &self.album_info;
    for (info.pending[0..info.pending_count]) |pending| self.runtime.cancelJob(pending.job) catch {};
    info.pending_count = 0;
    info.requested.clearRetainingCapacity();
    self.album_artist_filter = null;
    self.album_artist_name.clear(self.allocator);
    showArtistChip(self);
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
    _ = showAlbum(self, navigation, release_id, null);
}

fn showAlbum(self: *App, navigation: *adw.NavigationView, release_id: i64, into: ?*adw.NavigationPage) bool {
    const library = self.library orelse return false;
    const release = (self.runtime.libraryRelease(library, release_id) catch null) orelse return false;
    defer release.deinit(self.allocator);
    var tracks = self.runtime.libraryTrackQuery(library, "", .{
        .release_id = release_id,
        .sort = .track_number,
        .limit = app.page_size,
    }) catch return false;
    defer tracks.deinit();

    const page = self.allocator.create(AlbumPage) catch return false;
    page.* = .{
        .self = self,
        .navigation = navigation,
        .ids = &.{},
        .tracks = &.{},
        .artists = &.{},
        .rows = &.{},
        .release_id = release_id,
        .album_artist_id = release.album_artist_id,
        .loved = release.loved,
    };
    page.ids = self.allocator.alloc(i64, tracks.items.len) catch {
        self.allocator.destroy(page);
        return false;
    };
    page.tracks = self.allocator.alloc(feedback.Target, tracks.items.len) catch {
        self.allocator.free(page.ids);
        self.allocator.destroy(page);
        return false;
    };
    page.artists = self.allocator.alloc(?i64, tracks.items.len) catch {
        self.allocator.free(page.ids);
        self.allocator.free(page.tracks);
        self.allocator.destroy(page);
        return false;
    };
    page.rows = self.allocator.alloc(?*gtk.Widget, tracks.items.len) catch {
        self.allocator.free(page.ids);
        self.allocator.free(page.tracks);
        self.allocator.free(page.artists);
        self.allocator.destroy(page);
        return false;
    };
    for (page.ids, page.tracks, page.artists, page.rows, tracks.items) |*id, *track, *artist_id, *row, item| {
        id.* = item.id;
        track.* = .{ .track_id = item.id, .recording_id = item.recording_id, .feedback = item.feedback };
        artist_id.* = item.artist_id;
        row.* = null;
    }

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 30);
    gtk.gtk_widget_add_css_class(content, "album-page");
    gtk.gtk_widget_add_css_class(content, "album-detail");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 36);
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

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
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
    _ = showInfo(page);
    requestInfo(self, release_id);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "artist-actions");
    const play = pill("Play", "orca-play-symbolic", true);
    const shuffle = pill("Shuffle", "orca-shuffle-symbolic", false);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    const heart = feedback.newAlbumButton(gtk.callback(albumHeartClicked), page);
    feedback.showAlbumButton(heart, release.loved);
    page.love_button = heart;
    const more = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
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
            const keys = gtk.gtk_event_controller_key_new();
            _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(trackKeyPressed), page);
            gtk.gtk_widget_add_controller(box, keys);
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
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), content_max_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), content_max_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const layers = gtk.gtk_overlay_new();
    const backdrop = art.newBackdrop(self, .header);
    gtk.gtk_widget_add_css_class(backdrop, "album-backdrop");
    art.showBackdrop(self, backdrop, &.{cover});
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), backdrop);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), clamp);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), clamp, gtk.true_);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), layers);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);
    page.scroller = scroller;
    _ = gtk.signalConnect(gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), "changed", gtk.callback(pageResized), page);
    page_ui.extendUnderBar(self, scroller, scroller);
    queueMoreCheck(page);
    registerPage(page);

    const title_text = strings.printZ(&buffer, "{s}", .{if (release.title.len != 0) release.title else "Album"}) catch "Album";
    if (into) |pushed| {
        page.pushed = pushed;
        adw.adw_navigation_page_set_child(pushed, scroller);
        adw.adw_navigation_page_set_title(pushed, title_text.ptr);
        window.markPushed(pushed, .{ .album = release_id });
        page_ui.refresh(self);
        return true;
    }
    const pushed = adw.adw_navigation_page_new(scroller, title_text.ptr);
    page.pushed = pushed;
    window.markPushed(pushed, .{ .album = release_id });
    adw.adw_navigation_view_push(navigation, pushed);
    _ = gtk.gtk_widget_grab_focus(play);
    return true;
}

fn refreshPages(self: *App, old_id: i64, new_id: i64) void {
    var targets: [app.open_album_page_limit]struct {
        navigation: *adw.NavigationView,
        pushed: *adw.NavigationPage,
        scroll: ?page_ui.Scroll,
    } = undefined;
    var count: usize = 0;
    for (self.open_album_pages[0..self.open_album_page_count]) |page| {
        if (page.release_id != old_id) continue;
        targets[count] = .{
            .navigation = page.navigation,
            .pushed = page.pushed orelse continue,
            .scroll = if (old_id == new_id) null else if (page.scroller) |scroller| page_ui.scrollOf(scroller) else null,
        };
        count += 1;
    }
    for (targets[0..count]) |target| {
        if (showAlbum(self, target.navigation, new_id, target.pushed)) {
            const scroll = target.scroll orelse continue;
            const scroller = adw.adw_navigation_page_get_child(target.pushed) orelse continue;
            page_ui.restoreScroll(self, .{ .scroller = scroller, .value = scroll.value });
            continue;
        }
        if (adw.adw_navigation_view_get_previous_page(target.navigation, target.pushed)) |previous|
            window.popToPage(self, target.navigation, previous);
    }
    if (count != 0) window.syncInspector(self);
}
