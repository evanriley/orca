const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const browse = @import("browse.zig");
const browse_model = @import("browse_model.zig");
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const page_ui = @import("page.zig");
const playlists = @import("playlists.zig");
const settings = @import("settings.zig");
const song_filters = @import("song_filters.zig");
const strings = @import("strings.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

pub const navigation_tag = "genres";

const tile_width: c_int = 165;
const tile_height: c_int = 128;
const album_pixels: c_int = 128;
const artist_pixels: c_int = 36;
const song_cover_pixels: c_int = 32;
const album_limit = 4;
const artist_limit = 5;
const song_limit = 5;
const mosaic_cells = 4;
const wheel_step: f64 = 120;
const cell_keys = [mosaic_cells][*:0]const u8{ "orca-cell-0", "orca-cell-1", "orca-cell-2", "orca-cell-3" };

const Summary = struct {
    id: i64,
    track_count: u32,
    release_count: u32,
    artist_count: u32,
    total_duration_ms: i64,

    fn of(genre: liborca.GenreSummary) Summary {
        return .{
            .id = genre.id,
            .track_count = genre.track_count,
            .release_count = genre.release_count,
            .artist_count = genre.artist_count,
            .total_duration_ms = genre.total_duration_ms,
        };
    }
};

const Covers = struct {
    ids: [mosaic_cells]i64 = @splat(0),
    len: u8 = 0,
};

const Song = struct {
    target: feedback.Target,
    row: ?*gtk.Widget = null,
    heart: ?*gtk.Widget = null,
};

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    selected: ?i64 = null,
    stale: bool = true,
    idle: c_uint = 0,
    store: ?*gtk.ListStore = null,
    selection: ?*gtk.SingleSelection = null,
    strip: ?*gtk.Widget = null,
    summaries: std.ArrayList(Summary) = .empty,
    loaded: u32 = 0,
    exhausted: bool = false,
    suppress: bool = false,
    artwork: std.AutoHashMapUnmanaged(i64, Covers) = .empty,
    body: ?*gtk.Stack = null,
    current: ?Summary = null,
    current_name: app.OwnedText = .{},
    hero_name: ?*gtk.Label = null,
    hero_stats: ?*gtk.Label = null,
    album_card: ?*gtk.Widget = null,
    artist_card: ?*gtk.Widget = null,
    song_card: ?*gtk.Widget = null,
    album_grid: ?*gtk.FlowBox = null,
    artist_list: ?*gtk.ListBox = null,
    song_list: ?*gtk.ListBox = null,
    release_ids: [album_limit]i64 = @splat(0),
    release_count: usize = 0,
    artist_ids: [artist_limit]i64 = @splat(0),
    artist_count: usize = 0,
    songs: [song_limit]Song = undefined,
    song_ids: [song_limit]i64 = @splat(0),
    song_count: usize = 0,
    song_sort: liborca.TrackSort = .play_count,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.idle != 0) _ = gtk.g_source_remove(self.idle);
        self.idle = 0;
        self.summaries.deinit(allocator);
        self.artwork.deinit(allocator);
        self.current_name.clear(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn part(widget: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    const found = gtk.g_object_get_data(widget, key) orelse return null;
    return @ptrCast(@alignCast(found));
}

pub fn shown(self: *App) void {
    const genres = &self.genres;
    if (!genres.stale or genres.idle != 0) return;
    if (genres.summaries.items.len == 0) if (genres.body) |body| gtk.gtk_stack_set_visible_child_name(body, "loading");
    genres.idle = gtk.g_idle_add(loadIdle, self);
}

pub fn open(self: *App, genre_id: i64) void {
    const genres = &self.genres;
    genres.selected = genre_id;
    if (genres.navigation) |navigation| window.popToTag(self, navigation, navigation_tag);
    window.showPage(self, .genres);
    if (!genres.stale and genres.idle == 0) restoreSelection(self);
}

pub fn invalidate(self: *App) void {
    self.genres.stale = true;
    if (self.current_page == .genres) shown(self);
}

fn bodyDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const genres = &state(data).genres;
    if (genres.idle != 0) _ = gtk.g_source_remove(genres.idle);
    genres.idle = 0;
    genres.body = null;
}

fn loadIdle(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.genres.idle = 0;
    load(self);
    return gtk.SOURCE_REMOVE;
}

fn load(self: *App) void {
    const genres = &self.genres;
    genres.stale = false;
    const store = genres.store orelse return;
    genres.suppress = true;
    gtk.g_list_store_remove_all(store);
    genres.suppress = false;
    genres.summaries.clearRetainingCapacity();
    genres.artwork.clearRetainingCapacity();
    genres.loaded = 0;
    genres.exhausted = false;
    loadNext(self);
    const body = genres.body orelse return;
    if (genres.summaries.items.len == 0) {
        genres.current = null;
        genres.current_name.clear(self.allocator);
        gtk.gtk_stack_set_visible_child_name(body, "empty");
        return;
    }
    gtk.gtk_stack_set_visible_child_name(body, "content");
    restoreSelection(self);
}

fn loadNext(self: *App) void {
    const genres = &self.genres;
    const store = genres.store orelse return;
    if (genres.exhausted) return;
    const library = self.library orelse {
        genres.exhausted = true;
        return;
    };
    var page = self.runtime.libraryGenrePage(library, .{
        .sort = .track_count,
        .limit = app.page_size,
        .offset = genres.loaded,
    }) catch {
        genres.exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) genres.exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (additions.items) |row| gtk.g_object_unref(row);
        additions.deinit(self.allocator);
    }
    var buffer: [48]u8 = undefined;
    for (page.items) |genre| {
        const detail = std.fmt.bufPrint(&buffer, "{d} {s}", .{
            genre.track_count,
            if (genre.track_count == 1) "track" else "tracks",
        }) catch "";
        const row = browse_model.new(genre.id, genre.name, detail) orelse continue;
        additions.append(self.allocator, row) catch {
            gtk.g_object_unref(row);
            break;
        };
        genres.summaries.append(self.allocator, Summary.of(genre)) catch {
            _ = additions.pop();
            gtk.g_object_unref(row);
            break;
        };
    }
    if (additions.items.len != 0) {
        genres.suppress = true;
        gtk.g_list_store_splice(
            store,
            gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
            0,
            additions.items.ptr,
            @intCast(additions.items.len),
        );
        genres.suppress = false;
    }
    genres.loaded += @intCast(page.items.len);
}

fn restoreSelection(self: *App) void {
    const genres = &self.genres;
    if (genres.selected) |wanted| {
        for (genres.summaries.items, 0..) |summary, position| {
            if (summary.id == wanted) return select(self, @intCast(position));
        }
        if (showById(self, wanted)) return;
    }
    select(self, 0);
}

fn select(self: *App, position: c_uint) void {
    const genres = &self.genres;
    if (genres.selection) |selection| {
        genres.suppress = true;
        gtk.gtk_single_selection_set_selected(selection, position);
        genres.suppress = false;
    }
    showAt(self, position, false);
    if (genres.strip) |strip| gtk.gtk_list_view_scroll_to(gtk.cast(gtk.ListView, strip), position, gtk.LIST_SCROLL_NONE, null);
}

fn showAt(self: *App, position: c_uint, persist: bool) void {
    const genres = &self.genres;
    if (position >= genres.summaries.items.len) return;
    const store = genres.store orelse return;
    const object = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return;
    defer gtk.g_object_unref(object);
    const genre: *BrowseObject = @ptrCast(@alignCast(object));
    showGenre(self, genres.summaries.items[position], genre.name(), persist);
}

fn showById(self: *App, genre_id: i64) bool {
    const library = self.library orelse return false;
    const genre = (self.runtime.libraryGenre(library, genre_id) catch null) orelse return false;
    defer genre.deinit(self.allocator);
    if (self.genres.selection) |selection| {
        self.genres.suppress = true;
        gtk.gtk_single_selection_set_selected(selection, gtk.INVALID_LIST_POSITION);
        self.genres.suppress = false;
    }
    showGenre(self, Summary.of(genre), genre.name, false);
    return true;
}

fn showGenre(self: *App, summary: Summary, name: []const u8, persist: bool) void {
    const genres = &self.genres;
    genres.current = summary;
    genres.current_name.set(self.allocator, name);
    if (persist and genres.selected != summary.id) {
        genres.selected = summary.id;
        settings.save(self);
    }
    var buffer: [512]u8 = undefined;
    if (genres.hero_name) |label| gtk.gtk_label_set_text(label, strings.terminated(&buffer, name).ptr);
    if (genres.hero_stats) |label| gtk.gtk_label_set_text(label, statsText(&buffer, summary).ptr);
    const library = self.library orelse return;
    fillAlbums(self, library, summary.id);
    fillArtists(self, library, summary.id);
    fillSongs(self, library, summary.id);
}

fn statsText(buffer: []u8, summary: Summary) [:0]const u8 {
    const minutes: u64 = if (summary.total_duration_ms > 0) @intCast(@divTrunc(summary.total_duration_ms, 60_000)) else 0;
    var duration_buffer: [32]u8 = undefined;
    const duration = if (minutes >= 60)
        std.fmt.bufPrint(&duration_buffer, " • {d}h {d}m", .{ minutes / 60, minutes % 60 }) catch ""
    else if (minutes > 0)
        std.fmt.bufPrint(&duration_buffer, " • {d}m", .{minutes}) catch ""
    else
        "";
    return strings.printZ(buffer, "{d} {s} • {d} {s} • {d} {s}{s}", .{
        summary.track_count,
        if (summary.track_count == 1) "track" else "tracks",
        summary.release_count,
        if (summary.release_count == 1) "album" else "albums",
        summary.artist_count,
        if (summary.artist_count == 1) "artist" else "artists",
        duration,
    }) catch "";
}

fn coversFor(self: *App, genre_id: i64) Covers {
    const genres = &self.genres;
    if (genres.artwork.get(genre_id)) |covers| return covers;
    var covers: Covers = .{};
    const library = self.library orelse return covers;
    const found = self.runtime.libraryGenreArtwork(library, genre_id, mosaic_cells) catch return covers;
    defer found.deinit();
    for (found.ids[0..@min(found.ids.len, mosaic_cells)], 0..) |id, index| covers.ids[index] = id;
    covers.len = @intCast(@min(found.ids.len, mosaic_cells));
    genres.artwork.put(self.allocator, genre_id, covers) catch {};
    return covers;
}

fn paintMosaic(self: *App, mosaic: *gtk.Widget, covers: Covers) void {
    const single = part(mosaic, "orca-single") orelse return;
    const tiled = covers.len == mosaic_cells;
    if (tiled or covers.len == 0) art.clear(self, single) else art.show(self, single, art.Key.release(covers.ids[0], .tile));
    for (cell_keys, 0..) |key, index| {
        const cell = part(mosaic, key) orelse continue;
        if (tiled) art.show(self, cell, art.Key.release(covers.ids[index], .thumb)) else art.clear(self, cell);
    }
    const page: [*:0]const u8 = if (tiled) "grid" else if (covers.len != 0) "single" else "blank";
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, mosaic), page);
}

fn blank() *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, "genre-tile-blank");
    return box;
}

fn newMosaic(self: *App) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    const single = art.newFillingCover(self, blank());
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), single, "single");
    gtk.g_object_set_data(stack, "orca-single", single);
    const grid = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, grid), gtk.true_);
    for (0..2) |row_index| {
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, row), gtk.true_);
        for (0..2) |column| {
            const cell = art.newFillingCover(self, blank());
            gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            gtk.g_object_set_data(stack, cell_keys[row_index * 2 + column], cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
    }
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), grid, "grid");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), blank(), "blank");
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, stack), "blank");
    return stack;
}

fn tileLabel(class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn setupTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "genre-tile");
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    const sizer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(sizer, tile_width, tile_height);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), sizer);
    const mosaic = newMosaic(self);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), mosaic);
    const shade = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(shade, "genre-tile-shade");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), shade);
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(labels, "genre-tile-labels");
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_END);
    const name = tileLabel("genre-tile-name");
    const count = tileLabel("genre-tile-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), count);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), labels);
    const ring = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(ring, "genre-tile-ring");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), ring);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), frame);
    gtk.g_object_set_data(frame, "orca-mosaic", mosaic);
    gtk.g_object_set_data(frame, "orca-name", name);
    gtk.g_object_set_data(frame, "orca-detail", count);
}

fn bindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const genre: *BrowseObject = @ptrCast(@alignCast(object));
    const frame = gtk.gtk_list_item_get_child(list_item) orelse return;
    const name = part(frame, "orca-name") orelse return;
    const count = part(frame, "orca-detail") orelse return;
    const mosaic = part(frame, "orca-mosaic") orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, name), genre.name().ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, count), genre.detail().ptr);
    gtk.gtk_widget_set_tooltip_text(frame, genre.name().ptr);
    const id = genre.id() orelse return paintMosaic(self, mosaic, .{});
    paintMosaic(self, mosaic, coversFor(self, id));
}

fn unbindTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const frame = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const mosaic = part(frame, "orca-mosaic") orelse return;
    if (part(mosaic, "orca-single")) |single| art.forget(self, single);
    for (cell_keys) |key| if (part(mosaic, key)) |cell| art.forget(self, cell);
}

fn selectionChanged(selection: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.genres.suppress) return;
    const position = gtk.gtk_single_selection_get_selected(gtk.cast(gtk.SingleSelection, selection));
    if (position == gtk.INVALID_LIST_POSITION) return;
    showAt(self, position, true);
}

fn stripMoved(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.genres.exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page) loadNext(self);
}

fn stripWheel(controller: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    if (dy == 0 or dx != 0) return gtk.false_;
    const adjustment = gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, data));
    const step = if (gtk.gtk_event_controller_scroll_get_unit(gtk.cast(gtk.EventController, controller)) == gtk.SCROLL_UNIT_WHEEL)
        dy * wheel_step
    else
        dy;
    const limit = @max(gtk.gtk_adjustment_get_upper(adjustment) - gtk.gtk_adjustment_get_page_size(adjustment), 0);
    gtk.gtk_adjustment_set_value(adjustment, std.math.clamp(gtk.gtk_adjustment_get_value(adjustment) + step, 0, limit));
    return gtk.true_;
}

fn buildStrip(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.genres.store = store;
    const selection = gtk.gtk_single_selection_new(gtk.cast(gtk.ListModel, store));
    gtk.gtk_single_selection_set_autoselect(selection, gtk.false_);
    gtk.gtk_single_selection_set_can_unselect(selection, gtk.true_);
    self.genres.selection = selection;
    _ = gtk.signalConnect(selection, "notify::selected", gtk.callback(selectionChanged), self);
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupTile), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindTile), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindTile), self);
    const view = gtk.gtk_list_view_new(gtk.cast(gtk.SelectionModel, selection), factory);
    gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, view), gtk.ORIENTATION_HORIZONTAL);
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, view), gtk.LIST_TAB_ITEM);
    gtk.gtk_widget_add_css_class(view, "genre-strip");
    gtk.gtk_widget_set_tooltip_text(view, null);
    self.genres.strip = view;

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_AUTOMATIC, gtk.POLICY_NEVER);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    gtk.gtk_widget_add_css_class(scroller, "genre-strip-scroller");
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(stripMoved),
        self,
    );
    const wheel = gtk.gtk_event_controller_scroll_new(gtk.EVENT_CONTROLLER_SCROLL_VERTICAL);
    gtk.gtk_event_controller_set_propagation_phase(wheel, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(wheel, "scroll", gtk.callback(stripWheel), scroller);
    gtk.gtk_widget_add_controller(scroller, wheel);
    return scroller;
}

const IdList = struct {
    app: *App,
    ids: std.ArrayList(i64) = .empty,
};

fn collectPlayable(self: *App, genre_id: i64, sort: liborca.TrackSort, list: *IdList) void {
    const library = self.library orelse return;
    var offset: u32 = 0;
    while (list.ids.items.len < liborca.max_playlist_entries) {
        var page = self.runtime.libraryTrackQuery(library, "", .{
            .genre_id = genre_id,
            .sort = sort,
            .direction = .descending,
            .limit = app.page_size,
            .offset = offset,
        }) catch return;
        defer page.deinit();
        for (page.items) |item| {
            if (list.ids.items.len == liborca.max_playlist_entries) return;
            if (!item.has_playable_file) continue;
            list.ids.append(self.allocator, item.id) catch return;
        }
        if (page.items.len < app.page_size) return;
        offset += app.page_size;
    }
}

pub fn playGenreId(self: *App, genre_id: i64) void {
    playById(self, genre_id, false, null);
}

fn playGenre(self: *App, shuffle: bool, start_id: ?i64) void {
    const genre = self.genres.current orelse return;
    playById(self, genre.id, shuffle, start_id);
}

fn playById(self: *App, genre_id: i64, shuffle: bool, start_id: ?i64) void {
    var list: IdList = .{ .app = self };
    defer list.ids.deinit(self.allocator);
    collectPlayable(self, genre_id, self.genres.song_sort, &list);
    if (list.ids.items.len == 0) return self.toast("No song in this genre has a playable file");
    self.runtime.playerSetShuffle(self.player, shuffle) catch {};
    const wanted = start_id orelse return transport.playIds(self, list.ids.items, 0);
    const start = std.mem.indexOfScalar(i64, list.ids.items, wanted) orelse return transport.playIds(self, &.{wanted}, 0);
    transport.playIds(self, list.ids.items, @intCast(start));
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playGenre(state(data), false, null);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playGenre(state(data), true, null);
}

fn rulesJson(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const Rule = struct { field: []const u8 = "genre", op: []const u8 = "is", value: []const u8 };
    const Rules = struct { v: u8 = 1, match: []const u8 = "all", rules: []const Rule };
    var encoded = std.Io.Writer.Allocating.init(allocator);
    errdefer encoded.deinit();
    try std.json.Stringify.value(Rules{ .rules = &.{.{ .value = name }} }, .{}, &encoded.writer);
    var list = encoded.toArrayList();
    return list.toOwnedSlice(allocator);
}

fn smartPlaylistActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const name = self.genres.current_name.value;
    if (self.genres.current == null or name.len == 0) return;
    const rules = rulesJson(self.allocator, name) catch return self.toast("Could not create the playlist");
    defer self.allocator.free(rules);
    const id = self.runtime.libraryCreateSmartPlaylist(library, name, rules) catch return self.toast("Could not create the playlist");
    playlists.refresh(self);
    playlists.open(self, id);
}

fn buildHero(self: *App) *gtk.Widget {
    const hero = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(hero, "genre-hero");
    const eyebrow = gtk.gtk_label_new("GENRE");
    gtk.gtk_widget_add_css_class(eyebrow, "now-eyebrow");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, eyebrow), 0);
    const name = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(name, "genre-hero-name");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    self.genres.hero_name = gtk.cast(gtk.Label, name);
    const stats = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(stats, "genre-hero-stats");
    gtk.gtk_widget_add_css_class(stats, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, stats), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, stats), gtk.true_);
    self.genres.hero_stats = gtk.cast(gtk.Label, stats);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "genre-actions");
    const play = albums.pill("Play", "media-playback-start-symbolic", true);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    const shuffle = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), self);

    const group = gtk.g_simple_action_group_new();
    const action = gtk.g_simple_action_new("smart-playlist", null).?;
    _ = gtk.signalConnect(action, "activate", gtk.callback(smartPlaylistActivated), self);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
    gtk.gtk_widget_insert_action_group(hero, "genre", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    const model = gtk.g_menu_new();
    gtk.g_menu_append(model, "Create Smart Playlist", "genre.smart-playlist");
    const more = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, more), "view-more-symbolic");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, more), gtk.cast(gtk.GMenuModel, model));
    gtk.g_object_unref(model);
    gtk.gtk_widget_add_css_class(more, "circular");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    for ([_]*gtk.Widget{ play, shuffle, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);

    for ([_]*gtk.Widget{ eyebrow, name, stats, actions }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, hero), piece);
    return hero;
}

const Card = struct {
    widget: *gtk.Widget,
    body: *gtk.Box,
};

fn card(self: *App, title: [*:0]const u8, tooltip: [*:0]const u8, see_all: gtk.GCallback) Card {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(box, "genre-card");
    gtk.gtk_widget_set_hexpand(box, gtk.true_);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_START);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const label = gtk.gtk_label_new(title);
    gtk.gtk_widget_add_css_class(label, "genre-card-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_hexpand(label, gtk.true_);
    const button = gtk.gtk_button_new_with_label("See All \u{203a}");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "genre-see-all");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    _ = gtk.signalConnect(button, "clicked", see_all, self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), button);
    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), body);
    return .{ .widget = box, .body = gtk.cast(gtk.Box, body) };
}

fn albumsSeeAll(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const genre = self.genres.current orelse return;
    albums.showGenre(self, genre.id);
}

fn artistsSeeAll(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const genre = self.genres.current orelse return;
    artists.showGenre(self, genre.id, self.genres.current_name.value);
}

fn songsSeeAll(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const genre = self.genres.current orelse return;
    song_filters.showGenre(self, genre.id);
    browse.clearSearch(self);
    browse.clearScope(self);
    self.browse.sort = self.genres.song_sort;
    self.browse.direction = .descending;
    window.showSort(self);
    self.reload();
    window.showPage(self, .tracks);
}

fn cardLabel(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn albumTile(self: *App, release: liborca.ReleaseSummary) *gtk.Widget {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "genre-album");
    gtk.gtk_widget_set_size_request(tile, album_pixels, -1);
    const cover = art.newCover(self, art.initialsPlaceholder(), album_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release.id, .tile));
    const playing = albums.playingBadge();
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), playing);
    gtk.g_object_set_data(tile, "orca-playing", playing);
    albums.showPlaying(tile, self.playing().matches(.release, release.id));
    var buffer: [512]u8 = undefined;
    const title = cardLabel(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr, "tile-title");
    const artist = cardLabel(strings.terminated(&buffer, release.album_artist).ptr, "tile-artist");
    const date = release.release_date orelse "";
    const year = cardLabel(strings.terminated(&buffer, date[0..@min(date.len, 4)]).ptr, "tile-year");
    gtk.gtk_widget_add_css_class(year, "numeric");
    for ([_]*gtk.Widget{ frame, title, artist, year }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
    return tile;
}

fn fillAlbums(self: *App, library: liborca.LibraryHandle, genre_id: i64) void {
    const genres = &self.genres;
    const grid = genres.album_grid orelse return;
    gtk.gtk_flow_box_remove_all(grid);
    genres.release_count = 0;
    var page = self.runtime.libraryReleasePage(library, .{
        .genre_id = genre_id,
        .sort = .most_played,
        .limit = album_limit,
    }) catch return showCard(genres.album_card, false);
    defer page.deinit();
    for (page.items[0..@min(page.items.len, album_limit)], 0..) |release, index| {
        gtk.gtk_flow_box_append(grid, albumTile(self, release));
        genres.release_ids[index] = release.id;
        genres.release_count = index + 1;
    }
    showCard(genres.album_card, genres.release_count != 0);
}

fn showCard(widget: ?*gtk.Widget, visible: bool) void {
    gtk.gtk_widget_set_visible(widget orelse return, if (visible) gtk.true_ else gtk.false_);
}

fn albumActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= self.genres.release_count) return;
    const navigation = self.genres.navigation orelse return;
    albums.openAlbum(self, navigation, self.genres.release_ids[@intCast(index)]);
}

fn rank(position: usize) *gtk.Widget {
    var buffer: [8]u8 = undefined;
    const label = gtk.gtk_label_new(strings.format(&buffer, "{d}", .{position + 1}).ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.5);
    gtk.gtk_widget_set_size_request(label, 16, -1);
    gtk.gtk_widget_add_css_class(label, "genre-rank");
    gtk.gtk_widget_add_css_class(label, "numeric");
    return label;
}

fn artistRow(self: *App, artist: liborca.ArtistSummary, position: usize) *gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "genre-artist");
    const thumb = art.newCover(self, art.initialsPlaceholder(), artist_pixels);
    gtk.gtk_widget_add_css_class(thumb, "artist-thumb");
    art.setInitials(thumb, artist.name);
    art.showArtist(self, thumb, artist.id, if (artist.has_photo) .stored else .absent, artist.cover_release_id, .thumb);
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    var buffer: [512]u8 = undefined;
    const name = cardLabel(strings.terminated(&buffer, if (artist.name.len != 0) artist.name else "Unknown Artist").ptr, "genre-row-title");
    const detail = cardLabel(strings.format(&buffer, "{d} {s}", .{
        artist.track_count,
        if (artist.track_count == 1) "track" else "tracks",
    }).ptr, "genre-row-detail");
    gtk.gtk_widget_add_css_class(detail, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), rank(position));
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), thumb);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    albums.showPlaying(box, self.playing().matches(.artist, artist.id));
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    return row;
}

fn fillArtists(self: *App, library: liborca.LibraryHandle, genre_id: i64) void {
    const genres = &self.genres;
    const list = genres.artist_list orelse return;
    gtk.gtk_list_box_remove_all(list);
    genres.artist_count = 0;
    var page = self.runtime.libraryArtistPage(library, .{
        .genre_id = genre_id,
        .sort = .track_count,
        .limit = artist_limit,
    }) catch return showCard(genres.artist_card, false);
    defer page.deinit();
    for (page.items[0..@min(page.items.len, artist_limit)], 0..) |artist, index| {
        gtk.gtk_list_box_append(list, artistRow(self, artist, index));
        genres.artist_ids[index] = artist.id;
        genres.artist_count = index + 1;
    }
    showCard(genres.artist_card, genres.artist_count != 0);
}

fn rowPosition(row: ?*anyopaque) ?usize {
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0) return null;
    return @intCast(index);
}

fn artistActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = rowPosition(row) orelse return;
    if (position >= self.genres.artist_count) return;
    const navigation = self.genres.navigation orelse return;
    artists.openArtist(self, navigation, self.genres.artist_ids[position]);
}

fn marked(widget: ?*anyopaque) ?usize {
    const position = @intFromPtr(gtk.g_object_get_data(widget.?, "orca-position"));
    if (position == 0) return null;
    return position - 1;
}

fn songHeartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = marked(button) orelse return;
    if (position >= self.genres.song_count) return;
    feedback.toggle(self, self.genres.songs[position].target);
}

fn songRow(self: *App, summary: liborca.TrackSummary, position: usize) *gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "album-track-row");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "genre-song");
    const thumb = art.newCover(self, art.iconPlaceholder(song_cover_pixels), song_cover_pixels);
    gtk.gtk_widget_add_css_class(thumb, "artist-song-cover");
    art.show(self, thumb, if (summary.release_id) |release| art.Key.release(release, .thumb) else art.Key.track(summary.id, .thumb));
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    var buffer: [512]u8 = undefined;
    const title = cardLabel(strings.terminated(&buffer, if (summary.title.len != 0) summary.title else "Untitled").ptr, "genre-row-title");
    gtk.gtk_widget_add_css_class(title, "album-track-title");
    const artist = cardLabel(strings.terminated(&buffer, summary.artist).ptr, "genre-row-detail");
    const heart = feedback.newRowButton(gtk.callback(songHeartClicked), self);
    feedback.showRowButton(heart, summary.feedback);
    gtk.g_object_set_data(heart, "orca-position", @ptrFromInt(position + 1));
    gtk.gtk_widget_set_valign(heart, gtk.ALIGN_CENTER);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, title), -1);
    gtk.gtk_widget_set_hexpand(title, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), heart);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), artist);
    const duration: [:0]const u8 = if (summary.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else "")
    else
        "";
    const duration_label = gtk.gtk_label_new(duration.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration_label), 1.0);
    gtk.gtk_widget_set_size_request(duration_label, 40, -1);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "dim-label");
    for ([_]*gtk.Widget{ rank(position), thumb, labels, duration_label }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) gtk.gtk_widget_set_sensitive(row, gtk.false_);
    self.genres.songs[position] = .{
        .target = .{ .track_id = summary.id, .recording_id = summary.recording_id, .feedback = summary.feedback },
        .row = row,
        .heart = heart,
    };
    self.genres.song_ids[position] = summary.id;
    return row;
}

fn topSongs(self: *App, library: liborca.LibraryHandle, genre_id: i64, sort: liborca.TrackSort) ?liborca.TrackPage {
    return self.runtime.libraryTrackQuery(library, "", .{
        .genre_id = genre_id,
        .sort = sort,
        .direction = .descending,
        .limit = song_limit,
    }) catch null;
}

fn fillSongs(self: *App, library: liborca.LibraryHandle, genre_id: i64) void {
    const genres = &self.genres;
    const list = genres.song_list orelse return;
    gtk.gtk_list_box_remove_all(list);
    genres.song_count = 0;
    genres.song_ids = @splat(0);
    genres.song_sort = .play_count;
    var page = topSongs(self, library, genre_id, .play_count) orelse return showCard(genres.song_card, false);
    const played = for (page.items) |item| {
        if (item.play_count != 0) break true;
    } else false;
    if (!played) {
        if (topSongs(self, library, genre_id, .rating)) |rated| {
            page.deinit();
            page = rated;
            genres.song_sort = .rating;
        }
    }
    defer page.deinit();
    for (page.items[0..@min(page.items.len, song_limit)], 0..) |summary, position| {
        gtk.gtk_list_box_append(list, songRow(self, summary, position));
        genres.song_count = position + 1;
    }
    markPlaying(self, self.shown_track_id);
    showCard(genres.song_card, genres.song_count != 0);
}

fn songSelected(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = rowPosition(row orelse return) orelse return;
    if (position >= self.genres.song_count) return;
    details.choose(self, self.genres.song_ids[0..], self.genres.song_ids[position]);
}

fn songActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = rowPosition(row) orelse return;
    if (position >= self.genres.song_count) return;
    playGenre(self, false, self.genres.song_ids[position]);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const value = switch (change) {
        .feedback => |value| value,
        .rating => return,
    };
    for (self.genres.songs[0..self.genres.song_count]) |*song| {
        const recording = song.target.recording_id orelse continue;
        if (!changed.contains(recording)) continue;
        song.target.feedback = value;
        if (song.heart) |heart| feedback.showRowButton(heart, value);
    }
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    for (self.genres.songs[0..self.genres.song_count]) |song| {
        const row = song.row orelse continue;
        if (track_id == song.target.track_id)
            gtk.gtk_widget_add_css_class(row, "now-playing")
        else
            gtk.gtk_widget_remove_css_class(row, "now-playing");
    }
    const playing = self.playing();
    const genres = &self.genres;
    if (genres.album_grid) |grid| markChildren(gtk.cast(gtk.Widget, grid), genres.release_ids[0..genres.release_count], playing, .release);
    if (genres.artist_list) |list| markChildren(gtk.cast(gtk.Widget, list), genres.artist_ids[0..genres.artist_count], playing, .artist);
}

fn markChildren(container: *gtk.Widget, ids: []const i64, playing: app.Playing, kind: app.PlayingKind) void {
    var index: usize = 0;
    var child = gtk.gtk_widget_get_first_child(container);
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        if (index >= ids.len) return;
        const content = gtk.gtk_widget_get_first_child(cell) orelse continue;
        albums.showPlaying(content, playing.matches(kind, ids[index]));
        index += 1;
    }
}

fn newList(class: [*:0]const u8) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "album-tracks");
    gtk.gtk_widget_add_css_class(list, class);
    return list;
}

fn orientationSetter(breakpoint: *adw.Breakpoint, object: *gtk.Widget, orientation: c_int) void {
    var value: gtk.GValue = .{};
    _ = gtk.g_value_init(&value, gtk.gtk_orientation_get_type());
    gtk.g_value_set_enum(&value, orientation);
    adw.adw_breakpoint_add_setter(breakpoint, object, "orientation", &value);
    gtk.g_value_unset(&value);
}

fn stackBelow(bin: *gtk.Widget, condition: [*:0]const u8, outer: *gtk.Widget, inner: ?*gtk.Widget) void {
    const parsed = adw.adw_breakpoint_condition_parse(condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(parsed);
    orientationSetter(breakpoint, outer, gtk.ORIENTATION_VERTICAL);
    if (inner) |widget| orientationSetter(breakpoint, widget, gtk.ORIENTATION_VERTICAL);
    adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
}

fn buildCards(self: *App, bin: *gtk.Widget) *gtk.Widget {
    const albums_card = card(self, "Albums", "Show this genre's albums in Albums", gtk.callback(albumsSeeAll));
    self.genres.album_card = albums_card.widget;
    const grid = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_selection_mode(gtk.cast(gtk.FlowBox, grid), gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_homogeneous(gtk.cast(gtk.FlowBox, grid), gtk.true_);
    gtk.gtk_flow_box_set_min_children_per_line(gtk.cast(gtk.FlowBox, grid), 2);
    gtk.gtk_flow_box_set_max_children_per_line(gtk.cast(gtk.FlowBox, grid), album_limit);
    gtk.gtk_flow_box_set_column_spacing(gtk.cast(gtk.FlowBox, grid), 16);
    gtk.gtk_flow_box_set_row_spacing(gtk.cast(gtk.FlowBox, grid), 12);
    gtk.gtk_flow_box_set_activate_on_single_click(gtk.cast(gtk.FlowBox, grid), gtk.true_);
    gtk.gtk_widget_add_css_class(grid, "genre-albums");
    _ = gtk.signalConnect(grid, "child-activated", gtk.callback(albumActivated), self);
    self.genres.album_grid = gtk.cast(gtk.FlowBox, grid);
    gtk.gtk_box_append(albums_card.body, grid);

    const artists_card = card(self, "Top Artists", "Show this genre's artists in Artists", gtk.callback(artistsSeeAll));
    self.genres.artist_card = artists_card.widget;
    const artist_list = newList("genre-artists");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, artist_list), gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, artist_list), gtk.true_);
    _ = gtk.signalConnect(artist_list, "row-activated", gtk.callback(artistActivated), self);
    self.genres.artist_list = gtk.cast(gtk.ListBox, artist_list);
    gtk.gtk_box_append(artists_card.body, artist_list);

    const songs_card = card(self, "Top Tracks", "Show this genre's songs in Songs", gtk.callback(songsSeeAll));
    self.genres.song_card = songs_card.widget;
    const song_list = newList("genre-songs");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, song_list), gtk.SELECTION_SINGLE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, song_list), gtk.false_);
    _ = gtk.signalConnect(song_list, "row-selected", gtk.callback(songSelected), self);
    _ = gtk.signalConnect(song_list, "row-activated", gtk.callback(songActivated), self);
    self.genres.song_list = gtk.cast(gtk.ListBox, song_list);
    gtk.gtk_box_append(songs_card.body, song_list);

    const outer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 20);
    gtk.gtk_widget_add_css_class(outer, "genre-cards");
    const inner = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 20);
    gtk.gtk_widget_set_hexpand(inner, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, inner), artists_card.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, inner), songs_card.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, outer), albums_card.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, outer), inner);

    stackBelow(bin, "max-width: 1300px", outer, null);
    stackBelow(bin, "max-width: 720px", outer, inner);
    return outer;
}

fn fillClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.settings_page.tab = .library;
    window.showPage(self, .settings);
}

fn buildEmpty(self: *App) *gtk.Widget {
    const empty = adw.adw_status_page_new();
    const page = gtk.cast(adw.StatusPage, empty);
    adw.adw_status_page_set_icon_name(page, "applications-multimedia-symbolic");
    adw.adw_status_page_set_title(page, "No genres yet");
    adw.adw_status_page_set_description(page, "Genres come from your files\u{2019} tags.");
    const link = gtk.gtk_button_new_with_label("Fill missing genres from MusicBrainz");
    gtk.gtk_widget_add_css_class(link, "flat");
    gtk.gtk_widget_add_css_class(link, "genre-fill-link");
    gtk.gtk_widget_set_halign(link, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(link, "clicked", gtk.callback(fillClicked), self);
    adw.adw_status_page_set_child(page, link);
    return empty;
}

pub fn build(self: *App) *gtk.Widget {
    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "genre-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildStrip(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildHero(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), buildCards(self, bin));
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), scroller);

    const loading = adw.adw_spinner_new();
    gtk.gtk_widget_set_size_request(loading, 32, 32);
    gtk.gtk_widget_set_halign(loading, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(loading, gtk.ALIGN_CENTER);
    const body = gtk.gtk_stack_new();
    self.genres.body = gtk.cast(gtk.Stack, body);
    _ = gtk.signalConnect(body, "destroy", gtk.callback(bodyDestroyed), self);
    _ = gtk.gtk_stack_add_named(self.genres.body.?, loading, "loading");
    _ = gtk.gtk_stack_add_named(self.genres.body.?, bin, "content");
    _ = gtk.gtk_stack_add_named(self.genres.body.?, buildEmpty(self), "empty");
    gtk.gtk_stack_set_visible_child_name(self.genres.body.?, "loading");

    const title = page_ui.title("Genres");
    gtk.gtk_label_set_text(title.meta, "Explore your music by genre. Curated from your library.");
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, title.meta), "numeric");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, title.meta), "genres-tagline");

    const view = page_ui.withTitle(title, body);

    const navigation = adw.adw_navigation_view_new();
    self.genres.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(view, "Genres");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(self.genres.navigation.?, root);
    return navigation;
}
