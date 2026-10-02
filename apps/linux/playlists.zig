//! Playlists: the overview of every playlist, the page that lists one
//! playlist's songs, and the dialogs that create, rename, delete, import and
//! export them.
//!
//! liborca keeps the playlists, resolves their entries and plays them; this
//! asks and shows the answer.

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
const window = @import("window.zig");
const albums = @import("albums.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const details = @import("details.zig");
const page_ui = @import("page.zig");
const song_table = @import("song_table.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const insert_batch = 512;
const max_playlists = 4 * app.page_size;
const card_pixels: c_int = 188;
const hero_pixels: c_int = 232;
const overview_tag = "playlists";
const page_tag = "playlist";

const Sort = enum { updated, name, created };

const sort_labels = [_]?[*:0]const u8{ "Recently Updated", "Name", "Recently Created", null };

const cell_keys = [_][*:0]const u8{ "orca-cell-0", "orca-cell-1", "orca-cell-2", "orca-cell-3" };

pub const Card = struct {
    id: i64,
    name: [:0]u8,
    folded: [:0]u8,
    entries: u32,
    available: u32,
    duration_ms: i64,
    created_at: i64,
    updated_at: i64,
    covers: [4]i64 = undefined,
    cover_count: u8 = 0,
    covers_loaded: bool = false,

    fn releaseCovers(self: *const Card) []const i64 {
        return self.covers[0..self.cover_count];
    }
};

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    page: ?*adw.NavigationPage = null,
    cards: std.ArrayList(Card) = .empty,
    card_store: ?*gtk.ListStore = null,
    query: ?[:0]u8 = null,
    sort: Sort = .updated,
    overview_meta: ?*gtk.Label = null,
    overview_body: ?*gtk.Stack = null,
    open_id: ?i64 = null,
    songs: song_table.Table = .{},
    crumb: ?*gtk.Label = null,
    hero: ?*gtk.Widget = null,
    mosaic: ?*gtk.Widget = null,
    title: ?*gtk.Label = null,
    meta: ?*gtk.Label = null,
    body: ?*gtk.Stack = null,
    scroller: ?*gtk.Widget = null,
    play_button: ?*gtk.Widget = null,
    shuffle_button: ?*gtk.Widget = null,
    /// The last import's unmatched lines, for its toast's Details.
    unmatched: std.ArrayList([:0]u8) = .empty,
    unmatched_total: u32 = 0,

    fn clearCards(self: *State, allocator: std.mem.Allocator) void {
        for (self.cards.items) |card| {
            allocator.free(card.name);
            allocator.free(card.folded);
        }
        self.cards.clearRetainingCapacity();
    }

    fn clearUnmatched(self: *State, allocator: std.mem.Allocator) void {
        for (self.unmatched.items) |line| allocator.free(line);
        self.unmatched.clearRetainingCapacity();
        self.unmatched_total = 0;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearCards(allocator);
        self.cards.deinit(allocator);
        if (self.query) |query| allocator.free(query);
        self.query = null;
        self.clearUnmatched(allocator);
        self.unmatched.deinit(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn plural(count: u64, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

fn fold(allocator: std.mem.Allocator, text: []const u8) ?[:0]u8 {
    const folded = gtk.g_utf8_casefold(text.ptr, @intCast(text.len)) orelse return null;
    defer gtk.g_free(folded);
    return allocator.dupeZ(u8, std.mem.span(folded)) catch null;
}

fn appendCard(self: *App, summary: liborca.PlaylistSummary) !void {
    const name = try self.allocator.dupeZ(u8, summary.name);
    errdefer self.allocator.free(name);
    const folded = fold(self.allocator, summary.name) orelse return error.OutOfMemory;
    errdefer self.allocator.free(folded);
    try self.playlists.cards.append(self.allocator, .{
        .id = summary.id,
        .name = name,
        .folded = folded,
        .entries = summary.entries,
        .available = summary.available,
        .duration_ms = summary.duration_ms,
        .created_at = summary.created_at,
        .updated_at = summary.updated_at,
    });
}

pub fn refresh(self: *App) void {
    self.playlists.clearCards(self.allocator);
    if (self.library) |library| {
        var offset: u32 = 0;
        reading: while (offset < max_playlists) : (offset += app.page_size) {
            const page = self.runtime.libraryPlaylists(library, app.page_size, offset) catch {
                self.toast("Could not read your playlists");
                break;
            };
            defer page.deinit();
            for (page.items) |summary| appendCard(self, summary) catch break :reading;
            if (page.items.len < app.page_size) break;
        }
    }
    if (self.playlists.open_id) |id| if (findCard(self, id) == null) {
        self.playlists.open_id = null;
        if (self.playlists.navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, overview_tag);
        reloadPage(self, false);
    };
    rebuildStore(self);
}

fn findCard(self: *App, playlist_id: i64) ?*Card {
    for (self.playlists.cards.items) |*card| {
        if (card.id == playlist_id) return card;
    }
    return null;
}

fn nameOf(self: *App, playlist_id: i64) ?[:0]const u8 {
    return (findCard(self, playlist_id) orelse return null).name;
}

/// Playlist names for a menu, which reads `_` as a mnemonic.
pub fn menuLabel(buffer: []u8, name: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (name) |byte| {
        if (byte == '_') writer.writeAll("__") catch break else writer.writeByte(byte) catch break;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

pub fn cards(self: *App) []const Card {
    return self.playlists.cards.items;
}

const SortContext = struct {
    cards: []const Card,
    sort: Sort,

    fn lessThan(context: SortContext, left: usize, right: usize) bool {
        const a = context.cards[left];
        const b = context.cards[right];
        switch (context.sort) {
            .updated => if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at,
            .created => if (a.created_at != b.created_at) return a.created_at > b.created_at,
            .name => {},
        }
        return left < right;
    }
};

fn matches(card: *const Card, query: ?[:0]const u8) bool {
    const wanted = query orelse return true;
    return std.mem.indexOf(u8, card.folded, wanted) != null;
}

fn rebuildStore(self: *App) void {
    const store = self.playlists.card_store orelse return;
    const all = self.playlists.cards.items;
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(self.allocator);
    for (all, 0..) |*card, index| {
        if (matches(card, self.playlists.query)) order.append(self.allocator, index) catch break;
    }
    std.mem.sort(usize, order.items, SortContext{ .cards = all, .sort = self.playlists.sort }, SortContext.lessThan);

    var objects: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (objects.items) |object| gtk.g_object_unref(object);
        objects.deinit(self.allocator);
    }
    for (order.items) |index| {
        const object = browse_model.new(all[index].id, all[index].name, "") orelse continue;
        objects.append(self.allocator, object) catch {
            gtk.g_object_unref(object);
            break;
        };
    }
    const shown = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store));
    gtk.g_list_store_splice(store, 0, shown, objects.items.ptr, @intCast(objects.items.len));

    if (self.playlists.overview_meta) |meta| {
        var buffer: [48]u8 = undefined;
        gtk.gtk_label_set_text(meta, strings.printZ(&buffer, "{d} {s}", .{ all.len, plural(all.len, "playlist", "playlists") }) catch "");
    }
    if (self.playlists.overview_body) |body| gtk.gtk_stack_set_visible_child_name(
        body,
        if (all.len == 0) "empty" else if (objects.items.len == 0) "no-results" else "grid",
    );
}

fn summaryText(buffer: []u8, card: *const Card, with_unavailable: bool) [:0]const u8 {
    var duration_buffer: [32]u8 = undefined;
    const songs = plural(card.entries, "song", "songs");
    if (card.entries == 0) return strings.printZ(buffer, "0 {s}", .{songs}) catch "";
    const duration = strings.totalDuration(&duration_buffer, card.duration_ms);
    const missing = card.entries -| card.available;
    if (with_unavailable and missing != 0)
        return strings.printZ(buffer, "{d} {s} • {s} • {d} unavailable", .{ card.entries, songs, duration, missing }) catch "";
    return strings.printZ(buffer, "{d} {s} • {s}", .{ card.entries, songs, duration }) catch "";
}

fn formatted(moment: *gtk.GDateTime, pattern: [*:0]const u8) ?[*:0]u8 {
    return gtk.g_date_time_format(moment, pattern);
}

fn sameDay(day: [*:0]const u8, moment: *gtk.GDateTime) bool {
    const other = formatted(moment, "%F") orelse return false;
    defer gtk.g_free(other);
    return std.mem.eql(u8, std.mem.span(day), std.mem.span(other));
}

fn updatedText(buffer: []u8, unix_seconds: i64) [:0]const u8 {
    const updated = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return "";
    defer gtk.g_date_time_unref(updated);
    const now = gtk.g_date_time_new_now_local() orelse return "";
    defer gtk.g_date_time_unref(now);
    const day = formatted(updated, "%F") orelse return "";
    defer gtk.g_free(day);
    if (sameDay(day, now)) return "Updated today";
    const elapsed = gtk.g_date_time_difference(now, updated);
    if (elapsed < 0) return "Updated today";
    if (gtk.g_date_time_add_days(now, -1)) |yesterday| {
        defer gtk.g_date_time_unref(yesterday);
        if (sameDay(day, yesterday)) return "Updated yesterday";
    }
    const days = @max(2, @divTrunc(elapsed, std.time.us_per_day));
    if (days <= 30) return strings.printZ(buffer, "Updated {d} days ago", .{days}) catch "";
    const date = formatted(updated, "%-d %b %Y") orelse return "";
    defer gtk.g_free(date);
    return strings.printZ(buffer, "Updated {s}", .{std.mem.span(date)}) catch "";
}

fn loadCovers(self: *App, card: *Card) void {
    if (card.covers_loaded) return;
    card.covers_loaded = true;
    card.cover_count = 0;
    const library = self.library orelse return;
    const page = self.runtime.libraryPlaylistEntries(library, card.id, app.page_size, 0) catch return;
    defer page.deinit();
    for (page.items) |entry| {
        const track = entry.track orelse continue;
        const release_id = track.release_id orelse continue;
        if (std.mem.indexOfScalar(i64, card.releaseCovers(), release_id) != null) continue;
        card.covers[card.cover_count] = release_id;
        card.cover_count += 1;
        if (card.cover_count == card.covers.len) break;
    }
}

fn mosaicPlaceholder(pixels: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("media-playlist-consecutive-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), @divTrunc(pixels, 3));
    gtk.gtk_widget_add_css_class(icon, "cover-placeholder");
    return icon;
}

fn mosaicPart(mosaic: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    return gtk.cast(gtk.Widget, gtk.g_object_get_data(mosaic, key) orelse return null);
}

fn newMosaic(self: *App, pixels: c_int) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(stack, "playlist-mosaic");
    gtk.gtk_widget_set_overflow(stack, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(stack, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(stack, gtk.ALIGN_START);
    const single = art.newCover(self, mosaicPlaceholder(pixels), pixels);
    gtk.gtk_widget_add_css_class(single, "mosaic-cell");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), single, "single");
    gtk.g_object_set_data(stack, "orca-single", single);
    const half = @divTrunc(pixels, 2);
    const grid = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for (0..2) |row_index| {
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        for (0..2) |column| {
            const cell = art.newCover(self, art.iconPlaceholder(half), half);
            gtk.gtk_widget_add_css_class(cell, "mosaic-cell");
            gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            gtk.g_object_set_data(stack, cell_keys[row_index * 2 + column], cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
    }
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), grid, "grid");
    return stack;
}

fn clearCover(cover: *gtk.Widget) void {
    const stack = gtk.cast(gtk.Stack, cover);
    if (gtk.gtk_stack_get_child_by_name(stack, "art")) |image|
        gtk.gtk_image_set_from_paintable(gtk.cast(gtk.Image, image), null);
    gtk.gtk_stack_set_visible_child_name(stack, "placeholder");
}

fn showMosaic(self: *App, mosaic: *gtk.Widget, covers: []const i64) void {
    const single = mosaicPart(mosaic, "orca-single") orelse return;
    if (covers.len == 0) {
        art.forget(self, single);
        clearCover(single);
    } else art.show(self, single, art.Key.release(covers[0], .tile));
    const tiled = covers.len >= cell_keys.len;
    for (cell_keys, 0..) |key, index| {
        const cell = mosaicPart(mosaic, key) orelse continue;
        if (tiled) art.show(self, cell, art.Key.release(covers[index], .tile)) else art.forget(self, cell);
    }
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, mosaic), if (tiled) "grid" else "single");
}

fn forgetMosaic(self: *App, mosaic: *gtk.Widget) void {
    if (mosaicPart(mosaic, "orca-single")) |single| art.forget(self, single);
    for (cell_keys) |key| art.forget(self, mosaicPart(mosaic, key) orelse continue);
}

fn tileLabel(class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn cardPart(tile: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    return gtk.cast(gtk.Widget, gtk.g_object_get_data(tile, key) orelse return null);
}

fn cardId(widget: *gtk.Widget) ?i64 {
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    return row.id();
}

fn setupCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_add_css_class(tile, "playlist-card");
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(tile, card_pixels, -1);

    const mosaic = newMosaic(self, card_pixels);
    const play_button = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    for ([_][*:0]const u8{ "tile-play", "tile-action", "circular" }) |class| gtk.gtk_widget_add_css_class(play_button, class);
    gtk.gtk_widget_set_halign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(play_button, "Play Playlist");
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(cardPlayClicked), self);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "album-cover-frame");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), mosaic);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), play_button);

    const title = tileLabel("tile-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    for ([_][*:0]const u8{ "flat", "tile-more", "tile-action" }) |class| gtk.gtk_widget_add_css_class(more, class);
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(cardMoreClicked), self);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(heading, "playlist-card-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), more);
    const songs = tileLabel("tile-artist");
    gtk.gtk_widget_add_css_class(songs, "numeric");
    const updated = tileLabel("tile-year");
    const unavailable = tileLabel("tile-year");
    gtk.gtk_widget_add_css_class(unavailable, "playlist-unavailable");

    for ([_]*gtk.Widget{ frame, heading, songs, updated, unavailable }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), part);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    for ([_]*gtk.Widget{ tile, play_button, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-mosaic", mosaic);
    gtk.g_object_set_data(tile, "orca-title", title);
    gtk.g_object_set_data(tile, "orca-songs", songs);
    gtk.g_object_set_data(tile, "orca-updated", updated);
    gtk.g_object_set_data(tile, "orca-unavailable", unavailable);
    menu.onSecondaryClick(tile, cardMenu, self);
}

fn bindCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const card = findCard(self, cardId(tile) orelse return) orelse return;
    var buffer: [128]u8 = undefined;
    if (cardPart(tile, "orca-title")) |title| gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), card.name.ptr);
    if (cardPart(tile, "orca-songs")) |songs| gtk.gtk_label_set_text(gtk.cast(gtk.Label, songs), summaryText(&buffer, card, false).ptr);
    if (cardPart(tile, "orca-updated")) |updated| gtk.gtk_label_set_text(gtk.cast(gtk.Label, updated), updatedText(&buffer, card.updated_at).ptr);
    if (cardPart(tile, "orca-unavailable")) |unavailable| {
        const missing = card.entries -| card.available;
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, unavailable), strings.printZ(&buffer, "{d} unavailable", .{missing}) catch "");
        gtk.gtk_widget_set_visible(unavailable, if (missing != 0) gtk.true_ else gtk.false_);
    }
    loadCovers(self, card);
    if (cardPart(tile, "orca-mosaic")) |mosaic| showMosaic(self, mosaic, card.releaseCovers());
}

fn unbindCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    forgetMosaic(state(data), cardPart(tile, "orca-mosaic") orelse return);
}

fn actionMenu(playlist_id: i64, playback: bool) *gtk.GMenu {
    const Item = struct { label: [*:0]const u8, action: []const u8 };
    const groups = [_][]const Item{
        &.{ .{ .label = "Play", .action = "playlist-play" }, .{ .label = "Shuffle", .action = "playlist-shuffle" } },
        &.{ .{ .label = "Rename…", .action = "playlist-rename" }, .{ .label = "Export…", .action = "playlist-export" } },
        &.{.{ .label = "Delete…", .action = "playlist-delete" }},
    };
    const model = gtk.g_menu_new();
    for (groups, 0..) |group, index| {
        if (index == 0 and !playback) continue;
        const section = gtk.g_menu_new();
        for (group) |entry| {
            var buffer: [64]u8 = undefined;
            const detailed = strings.printZ(&buffer, "app.{s}(int64 {d})", .{ entry.action, playlist_id }) catch continue;
            gtk.g_menu_append(section, entry.label, detailed.ptr);
        }
        gtk.g_menu_append_section(model, null, gtk.cast(gtk.GMenuModel, section));
        gtk.g_object_unref(section);
    }
    return model;
}

fn popupActions(widget: *gtk.Widget, playlist_id: i64, playback: bool, x: f64, y: f64) void {
    const model = actionMenu(playlist_id, playback);
    defer gtk.g_object_unref(model);
    menu.popupModel(widget, gtk.cast(gtk.GMenuModel, model), x, y);
}

fn popupBelow(widget: *gtk.Widget, playlist_id: i64, playback: bool) void {
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    popupActions(widget, playlist_id, playback, x, y);
}

fn cardMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    const tile = menu.gestureWidget(gesture);
    popupActions(tile, cardId(tile) orelse return, true, x, y);
}

fn cardMoreClicked(button: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const widget = gtk.cast(gtk.Widget, button.?);
    popupBelow(widget, cardId(widget) orelse return, true);
}

fn cardPlayClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playWhole(state(data), cardId(gtk.cast(gtk.Widget, button.?)) orelse return, false);
}

fn cardActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const store = self.playlists.card_store orelse return;
    open(self, albums.releaseAt(store, position) orelse return);
}

fn pageMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    popupBelow(gtk.cast(gtk.Widget, button.?), self.playlists.open_id orelse return, false);
}

pub fn open(self: *App, playlist_id: i64) void {
    self.playlists.open_id = playlist_id;
    reloadPage(self, false);
    window.showPage(self, .playlists);
    const navigation = self.playlists.navigation orelse return;
    const visible = adw.adw_navigation_view_get_visible_page_tag(navigation);
    if (visible != null and std.mem.eql(u8, std.mem.span(visible.?), page_tag)) return;
    _ = adw.adw_navigation_view_pop_to_tag(navigation, overview_tag);
    adw.adw_navigation_view_push_by_tag(navigation, page_tag);
}

/// Rereads the open playlist. `keep_scroll` holds the list where it was, for
/// an edit to the rows the user is looking at.
pub fn reloadPage(self: *App, keep_scroll: bool) void {
    const store = self.playlists.songs.store orelse return;
    const adjustment = if (self.playlists.scroller) |scroller|
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller))
    else
        null;
    const scrolled_to = if (adjustment) |value| gtk.gtk_adjustment_get_value(value) else 0;
    gtk.g_list_store_remove_all(store);
    const playlist_id = self.playlists.open_id orelse return;
    const library = self.library orelse return;

    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (additions.items) |row| gtk.g_object_unref(row);
        additions.deinit(self.allocator);
    }
    var available: u32 = 0;
    var offset: u32 = 0;
    while (offset < liborca.max_playlist_entries) : (offset += app.page_size) {
        const page = self.runtime.libraryPlaylistEntries(library, playlist_id, app.page_size, offset) catch {
            self.toast("Could not read that playlist");
            break;
        };
        defer page.deinit();
        for (page.items) |entry| {
            const row = if (entry.track) |track| track_model.new(track) else track_model.unavailable(entry.recording_id);
            additions.append(self.allocator, row orelse continue) catch {
                gtk.g_object_unref(row.?);
                break;
            };
            if (entry.track != null) available += 1;
        }
        if (page.items.len < app.page_size) break;
    }
    if (additions.items.len != 0)
        gtk.g_list_store_splice(store, 0, 0, additions.items.ptr, @intCast(additions.items.len));
    if (adjustment) |value| gtk.gtk_adjustment_set_value(value, if (keep_scroll) scrolled_to else 0);

    const card = findCard(self, playlist_id);
    const name: [*:0]const u8 = if (card) |found| found.name.ptr else "Playlist";
    if (self.playlists.crumb) |crumb| gtk.gtk_label_set_text(crumb, name);
    if (self.playlists.title) |title| gtk.gtk_label_set_text(title, name);
    if (self.playlists.page) |page| adw.adw_navigation_page_set_title(page, name);
    if (self.playlists.meta) |meta| {
        var buffer: [128]u8 = undefined;
        gtk.gtk_label_set_text(meta, if (card) |found| summaryText(&buffer, found, true).ptr else "");
    }
    if (self.playlists.mosaic) |mosaic| {
        if (card) |found| {
            loadCovers(self, found);
            showMosaic(self, mosaic, found.releaseCovers());
        } else showMosaic(self, mosaic, &.{});
    }
    if (self.playlists.body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (additions.items.len == 0) "empty" else "list");
    for ([_]?*gtk.Widget{ self.playlists.play_button, self.playlists.shuffle_button }) |maybe| {
        const button = maybe orelse continue;
        gtk.gtk_widget_set_sensitive(button, if (available != 0) gtk.true_ else gtk.false_);
    }
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    song_table.repaint(&self.playlists.songs, changed, change);
}

fn rowAt(self: *App, position: u32) ?*TrackObject {
    const store = self.playlists.songs.store orelse return null;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return null;
    gtk.g_object_unref(item);
    return @ptrCast(@alignCast(item));
}

/// Plays the open playlist from the row at `position`. liborca plays only the
/// entries in the library, so the start counts only those.
pub fn playFrom(self: *App, position: u32) void {
    const playlist_id = self.playlists.open_id orelse return;
    const library = self.library orelse return;
    const row = rowAt(self, position) orelse return;
    if (!row.inLibrary()) return self.toast("That song is not in your library");
    var start: u32 = 0;
    var index: u32 = 0;
    while (index < position) : (index += 1) {
        if ((rowAt(self, index) orelse continue).inLibrary()) start += 1;
    }
    play(self, playlist_id, library, start);
}

fn play(self: *App, playlist_id: i64, library: liborca.LibraryHandle, start: u32) void {
    if (!transport.ensureOutput(self)) return self.toast("No audio output is available");
    self.runtime.playerPlayPlaylist(self.player, library, self.io, playlist_id, start) catch |err| return self.toast(switch (err) {
        error.PlaylistEmpty => "Nothing in this playlist is in your library",
        else => "Could not start playback",
    });
    self.requestTick();
}

pub fn playWhole(self: *App, playlist_id: i64, shuffled: bool) void {
    const library = self.library orelse return;
    self.runtime.playerSetShuffle(self.player, shuffled) catch {};
    play(self, playlist_id, library, 0);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    playWhole(self, self.playlists.open_id orelse return, false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    playWhole(self, self.playlists.open_id orelse return, true);
}

fn newClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    askNew(state(data), &.{});
}

fn importClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    chooseImport(state(data));
}

fn searchChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.playlists.query) |query| self.allocator.free(query);
    self.playlists.query = null;
    const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry.?)));
    if (text.len != 0) self.playlists.query = fold(self.allocator, text);
    rebuildStore(self);
}

fn sortChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= std.enums.values(Sort).len) return;
    self.playlists.sort = @enumFromInt(selected);
    rebuildStore(self);
}

pub fn setNarrow(self: *App) void {
    const hero = self.playlists.hero orelse return;
    gtk.gtk_orientable_set_orientation(
        gtk.cast(gtk.Orientable, hero),
        if (self.window_narrow) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL,
    );
}

fn creationButtons(self: *App, spacing: c_int) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, spacing);
    const create = albums.pill("New Playlist", "list-add-symbolic", true);
    _ = gtk.signalConnect(create, "clicked", gtk.callback(newClicked), self);
    const import = gtk.gtk_button_new_with_label("Import…");
    _ = gtk.signalConnect(import, "clicked", gtk.callback(importClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), import);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), create);
    return row;
}

fn statusPage(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) *gtk.Widget {
    const page = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, page), icon);
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, page), title);
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, page), description);
    return page;
}

fn buildOverview(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.playlists.card_store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupCard), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindCard), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindCard), self);
    const grid = gtk.gtk_grid_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(grid, "album-grid");
    gtk.gtk_widget_add_css_class(grid, "playlist-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 1);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", gtk.callback(cardActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), grid);

    const empty = statusPage("media-playlist-consecutive-symbolic", "No playlists yet", "Right-click a song or an album and choose Add to Playlist.");
    const empty_actions = creationButtons(self, 12);
    gtk.gtk_widget_set_halign(empty_actions, gtk.ALIGN_CENTER);
    adw.adw_status_page_set_child(gtk.cast(adw.StatusPage, empty), empty_actions);
    const no_results = statusPage("edit-find-symbolic", "No results", "Try a different search.");

    const body = gtk.gtk_stack_new();
    self.playlists.overview_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, scroller, "grid");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, empty, "empty");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, no_results, "no-results");

    const header = page_ui.header();
    const title = page_ui.title("Playlists");
    self.playlists.overview_meta = title.meta;
    const sort_label = gtk.gtk_label_new("Sort by");
    gtk.gtk_widget_add_css_class(sort_label, "meta");
    gtk.gtk_widget_set_valign(sort_label, gtk.ALIGN_CENTER);
    const sort = gtk.gtk_drop_down_new_from_strings(&sort_labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort playlists");
    gtk.gtk_widget_add_css_class(sort, "sort-dropdown");
    gtk.gtk_widget_set_valign(sort, gtk.ALIGN_CENTER);
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, sort), @intFromEnum(self.playlists.sort));
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    title.add(sort_label);
    title.add(sort);

    const search = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, search), "Search playlists");
    gtk.gtk_widget_set_size_request(search, 240, -1);
    _ = gtk.signalConnect(search, "search-changed", gtk.callback(searchChanged), self);
    const controls = creationButtons(self, 8);
    gtk.gtk_widget_add_css_class(controls, "playlist-header-actions");
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), controls);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), search);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), page_ui.withTitle(title, body));
    return view;
}

fn buildPlaylistPage(self: *App, navigation: *adw.NavigationView) *adw.NavigationPage {
    const list = song_table.build(&self.playlists.songs, self, .{ .multiple = false, .sortable = false, .playlist = true });
    const scroller = gtk.gtk_scrolled_window_new();
    self.playlists.scroller = scroller;
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    const empty = statusPage("media-playlist-consecutive-symbolic", "No songs yet", "Right-click a song or an album and choose Add to Playlist.");
    const body = gtk.gtk_stack_new();
    self.playlists.body = gtk.cast(gtk.Stack, body);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, empty, "empty");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(hero, "album-hero");
    gtk.gtk_widget_add_css_class(hero, "playlist-hero");
    self.playlists.hero = hero;
    const mosaic = newMosaic(self, hero_pixels);
    gtk.gtk_widget_add_css_class(mosaic, "hero-cover");
    self.playlists.mosaic = mosaic;
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), mosaic);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const kind = gtk.gtk_label_new("PLAYLIST");
    gtk.gtk_widget_add_css_class(kind, "album-kind");
    const title = gtk.gtk_label_new("");
    self.playlists.title = gtk.cast(gtk.Label, title);
    gtk.gtk_widget_add_css_class(title, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    const meta = gtk.gtk_label_new("");
    self.playlists.meta = gtk.cast(gtk.Label, meta);
    gtk.gtk_widget_add_css_class(meta, "album-meta");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    for ([_]*gtk.Widget{ kind, title, meta }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), label);
    }
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    const play_button = albums.pill("Play", "media-playback-start-symbolic", true);
    const shuffle_button = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    self.playlists.play_button = play_button;
    self.playlists.shuffle_button = shuffle_button;
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(shuffle_button, "clicked", gtk.callback(shuffleClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "Playlist Menu");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(pageMoreClicked), self);
    for ([_]*gtk.Widget{ play_button, shuffle_button, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    setNarrow(self);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), hero);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), body);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_widget_set_vexpand(layers, gtk.true_);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), albums.newBackdrop(mosaicPart(mosaic, "orca-single").?));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), column);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), column, gtk.true_);

    const trail = page_ui.pushedTrail(navigation, "Playlist");
    self.playlists.crumb = trail.current;
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), trail.bar);
    adw.adw_toolbar_view_set_content(
        gtk.cast(adw.ToolbarView, view),
        details.besideContent(self, trail.bar, layers, .{ .selection = self.playlists.songs.selection.? }).widget,
    );
    const page = adw.adw_navigation_page_new(view, "Playlist");
    adw.adw_navigation_page_set_tag(page, page_tag);
    return page;
}

pub fn build(self: *App) *gtk.Widget {
    const navigation = adw.adw_navigation_view_new();
    self.playlists.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(buildOverview(self), "Playlists");
    adw.adw_navigation_page_set_tag(root, overview_tag);
    adw.adw_navigation_view_add(self.playlists.navigation.?, root);
    const page = buildPlaylistPage(self, self.playlists.navigation.?);
    self.playlists.page = page;
    adw.adw_navigation_view_add(self.playlists.navigation.?, page);
    refresh(self);
    return navigation;
}

/// Adds the Tracks' recordings to the end of the playlist.
pub fn addTracks(self: *App, playlist_id: i64, track_ids: []const i64) void {
    const library = self.library orelse return;
    if (track_ids.len == 0) return;
    var added: u32 = 0;
    var start: usize = 0;
    while (start < track_ids.len) : (start += insert_batch) {
        const end = @min(start + insert_batch, track_ids.len);
        const insertion = self.runtime.libraryPlaylistInsert(library, playlist_id, track_ids[start..end], null) catch |err| {
            self.toast(switch (err) {
                error.PlaylistFull => "That playlist is full",
                else => "Could not add to that playlist",
            });
            break;
        };
        added += insertion.added;
    }
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
    if (added == 0) return;
    var buffer: [640]u8 = undefined;
    const name = nameOf(self, playlist_id) orelse "the playlist";
    self.toast(strings.printZ(&buffer, "Added {d} {s} to “{s}”", .{ added, plural(added, "song", "songs"), name }) catch "Added to the playlist");
}

pub fn removeAt(self: *App, playlist_id: i64, position: u32) void {
    const library = self.library orelse return;
    _ = self.runtime.libraryPlaylistRemove(library, playlist_id, &.{position}) catch
        return self.toast("Could not remove that song");
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

pub fn move(self: *App, playlist_id: i64, from: u32, to: u32) void {
    const library = self.library orelse return;
    self.runtime.libraryPlaylistMove(library, playlist_id, from, to) catch
        return self.toast("Could not move that song");
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

const Purpose = enum { create, create_and_add, rename };

const NameRequest = struct {
    self: *App,
    purpose: Purpose,
    entry: *gtk.Widget,
    playlist_id: ?i64,
    track_ids: []i64,
};

fn nameError(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.PlaylistNameTaken => "A playlist with that name already exists",
        error.InvalidPlaylistName => "A playlist needs a name",
        else => "Could not save that playlist",
    };
}

/// Asks for a new playlist's name, then creates it: and adds `track_ids` to it
/// when there are any, or opens it when there are none.
pub fn askNew(self: *App, track_ids: []const i64) void {
    if (self.library == null) return self.toast("No library is open");
    askName(self, if (track_ids.len == 0) .create else .create_and_add, null, "", track_ids);
}

fn askName(self: *App, purpose: Purpose, playlist_id: ?i64, initial: [:0]const u8, track_ids: []const i64) void {
    const owned_ids = self.allocator.dupe(i64, track_ids) catch return self.toast("Out of memory");
    const request = self.allocator.create(NameRequest) catch {
        self.allocator.free(owned_ids);
        return self.toast("Out of memory");
    };
    const entry = gtk.gtk_entry_new();
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), initial.ptr);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), "Name");
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, entry), gtk.true_);
    request.* = .{ .self = self, .purpose = purpose, .entry = entry, .playlist_id = playlist_id, .track_ids = owned_ids };

    const renaming = purpose == .rename;
    const dialog = adw.adw_alert_dialog_new(if (renaming) "Rename Playlist" else "New Playlist", null);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, entry);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "save", if (renaming) "Rename" else "Create");
    adw.adw_alert_dialog_set_response_appearance(alert, "save", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "save");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(nameResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
    _ = gtk.g_idle_add(focusLater, gtk.g_object_ref(entry));
}

// A menu that opened the dialog hands focus back to its parent on idle, after the dialog took it.
fn focusLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const entry = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(entry);
    if (gtk.gtk_widget_get_root(entry) != null) _ = gtk.gtk_widget_grab_focus(entry);
    return gtk.SOURCE_REMOVE;
}

fn nameResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *NameRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer {
        self.allocator.free(request.track_ids);
        self.allocator.destroy(request);
    }
    if (!std.mem.eql(u8, std.mem.span(response), "save")) return;
    const library = self.library orelse return;
    const name = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.entry)));
    switch (request.purpose) {
        .create, .create_and_add => {
            const playlist_id = self.runtime.libraryCreatePlaylist(library, name) catch |err| return self.toast(nameError(err));
            refresh(self);
            if (request.purpose == .create) return open(self, playlist_id);
            addTracks(self, playlist_id, request.track_ids);
        },
        .rename => {
            const playlist_id = request.playlist_id orelse return;
            self.runtime.libraryRenamePlaylist(library, playlist_id, name) catch |err| return self.toast(nameError(err));
            refresh(self);
            if (self.playlists.open_id == playlist_id) reloadPage(self, true);
        },
    }
}

pub fn askRename(self: *App, playlist_id: i64) void {
    askName(self, .rename, playlist_id, nameOf(self, playlist_id) orelse "", &.{});
}

const PlaylistRequest = struct {
    self: *App,
    playlist_id: i64,
};

pub fn confirmDelete(self: *App, playlist_id: i64) void {
    var buffer: [640]u8 = undefined;
    const heading = strings.printZ(&buffer, "Delete “{s}”?", .{nameOf(self, playlist_id) orelse ""}) catch "Delete this playlist?";
    const request = self.allocator.create(PlaylistRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .playlist_id = playlist_id };
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Its songs stay in your library.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "delete", "Delete");
    adw.adw_alert_dialog_set_response_appearance(alert, "delete", adw.RESPONSE_DESTRUCTIVE);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(deleteResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn deleteResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *PlaylistRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "delete")) return;
    const library = self.library orelse return;
    self.runtime.libraryDeletePlaylist(library, request.playlist_id) catch return self.toast("Could not delete that playlist");
    refresh(self);
}

pub fn chooseExport(self: *App, playlist_id: i64) void {
    const request = self.allocator.create(PlaylistRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .playlist_id = playlist_id };
    var name_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&name_buffer);
    for (nameOf(self, playlist_id) orelse "Playlist") |byte| writer.writeByte(if (byte == '/') '-' else byte) catch break;
    var buffer: [600]u8 = undefined;
    const initial = strings.printZ(&buffer, "{s}.m3u8", .{name_buffer[0..writer.end]}) catch "Playlist.m3u8";
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Export Playlist");
    gtk.gtk_file_dialog_set_initial_name(dialog, initial.ptr);
    gtk.gtk_file_dialog_save(dialog, self.window, null, exportChosen, request);
    gtk.g_object_unref(dialog);
}

fn exportChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const request: *PlaylistRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_save_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    const library = self.library orelse return;
    const exported = self.runtime.libraryExportPlaylist(library, self.io, request.playlist_id, std.mem.span(path_pointer), .{
        .paths = .absolute,
        .replace = true,
    }) catch return self.toast("Could not export that playlist");
    var buffer: [128]u8 = undefined;
    self.toast(if (exported.skipped != 0)
        strings.printZ(&buffer, "Exported {d} {s}, {d} not in your library", .{ exported.written, plural(exported.written, "song", "songs"), exported.skipped }) catch "Exported"
    else
        strings.printZ(&buffer, "Exported {d} {s}", .{ exported.written, plural(exported.written, "song", "songs") }) catch "Exported");
}

pub fn chooseImport(self: *App) void {
    if (self.library == null) return self.toast("No library is open");
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Import Playlist");
    const filter = gtk.gtk_file_filter_new();
    gtk.gtk_file_filter_set_name(filter, "Playlists (M3U)");
    gtk.gtk_file_filter_add_suffix(filter, "m3u");
    gtk.gtk_file_filter_add_suffix(filter, "m3u8");
    if (gtk.g_list_store_new(gtk.gtk_file_filter_get_type())) |filters| {
        gtk.g_list_store_append(filters, filter);
        gtk.gtk_file_dialog_set_filters(dialog, gtk.cast(gtk.ListModel, filters));
        gtk.g_object_unref(filters);
    }
    gtk.gtk_file_dialog_set_default_filter(dialog, filter);
    gtk.g_object_unref(filter);
    gtk.gtk_file_dialog_open(dialog, self.window, null, importChosen, self);
    gtk.g_object_unref(dialog);
}

fn importChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_open_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    importFile(self, std.mem.span(path_pointer));
}

fn importFile(self: *App, path: []const u8) void {
    const library = self.library orelse return;
    const imported = self.runtime.libraryImportPlaylist(library, self.io, path, null) catch |err| return self.toast(switch (err) {
        error.PlaylistEmpty => "That playlist has no entries",
        error.PlaylistTooLarge => "That playlist is too large to import",
        else => "Could not import that playlist",
    });
    defer imported.deinit();
    self.playlists.clearUnmatched(self.allocator);
    for (imported.unmatched_lines) |line| {
        const copy = self.allocator.dupeZ(u8, line) catch break;
        self.playlists.unmatched.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            break;
        };
    }
    self.playlists.unmatched_total = imported.unmatched;
    refresh(self);
    open(self, imported.playlist_id);

    const matched = imported.matched_by_path + imported.matched_by_info;
    var buffer: [128]u8 = undefined;
    const text = if (imported.unmatched != 0)
        strings.printZ(&buffer, "Imported {d} {s}, {d} not found", .{ matched, plural(matched, "song", "songs"), imported.unmatched }) catch "Imported"
    else
        strings.printZ(&buffer, "Imported {d} {s}", .{ matched, plural(matched, "song", "songs") }) catch "Imported";
    const overlay = self.toasts orelse return;
    const toast = adw.adw_toast_new(text.ptr);
    if (imported.unmatched != 0) {
        adw.adw_toast_set_timeout(toast, 8);
        adw.adw_toast_set_button_label(toast, "Details");
        _ = gtk.signalConnect(toast, "button-clicked", gtk.callback(detailsClicked), self);
    } else adw.adw_toast_set_timeout(toast, 3);
    adw.adw_toast_overlay_add_toast(overlay, toast);
}

fn detailsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showUnmatched(state(data));
}

fn showUnmatched(self: *App) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.allocator);
    const lines = self.playlists.unmatched.items;
    for (lines, 0..) |line, index| {
        if (index != 0) text.append(self.allocator, '\n') catch return;
        text.appendSlice(self.allocator, line) catch return;
    }
    const hidden = self.playlists.unmatched_total -| @as(u32, @intCast(lines.len));
    if (hidden != 0) text.print(self.allocator, "\n…and {d} more", .{hidden}) catch return;
    text.append(self.allocator, 0) catch return;

    const label = gtk.gtk_label_new(@ptrCast(text.items.ptr));
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, label), gtk.WRAP_WORD_CHAR);
    gtk.gtk_widget_add_css_class(label, "monospace");
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 320);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), label);

    const dialog = adw.adw_alert_dialog_new("Not Found", "No song in your library matches these entries.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, scroller);
    adw.adw_alert_dialog_add_response(alert, "close", "Close");
    adw.adw_alert_dialog_set_close_response(alert, "close");
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
