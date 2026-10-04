const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const albums = @import("albums.zig");
const artist_page = @import("artist_page.zig");
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const menu = @import("menu.zig");
const playlists = @import("playlists.zig");
const settings = @import("settings.zig");
const strings = @import("strings.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");

const App = app.App;

pub const navigation_tag = "genres";

const index_pixels: c_int = 230;
const album_pixels: c_int = 132;
const artist_pixels: c_int = 36;
const album_limit = 6;
const artist_limit = 5;
const track_limit = 5;

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

const Track = struct {
    target: feedback.Target,
    row: ?*gtk.Widget = null,
};

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    selected: ?i64 = null,
    stale: bool = true,
    idle: c_uint = 0,
    list: ?*gtk.ListBox = null,
    summaries: std.ArrayList(Summary) = .empty,
    loaded: u32 = 0,
    exhausted: bool = false,
    suppress: bool = false,
    body: ?*gtk.Stack = null,
    empty: ?*adw.StatusPage = null,
    fill_link: ?*gtk.Widget = null,
    filter: app.OwnedText = .{},
    current: ?Summary = null,
    current_name: app.OwnedText = .{},
    hero_name: ?*gtk.Label = null,
    hero_stats: ?*gtk.Box = null,
    album_section: ?*gtk.Widget = null,
    artist_section: ?*gtk.Widget = null,
    track_section: ?*gtk.Widget = null,
    see_all: ?*gtk.Widget = null,
    album_grid: ?*gtk.FlowBox = null,
    artist_list: ?*gtk.ListBox = null,
    track_list: ?*gtk.ListBox = null,
    release_ids: [album_limit]i64 = @splat(0),
    release_count: usize = 0,
    artist_ids: [artist_limit]i64 = @splat(0),
    artist_count: usize = 0,
    tracks: [track_limit]Track = undefined,
    track_ids: [track_limit]i64 = @splat(0),
    track_count: usize = 0,
    track_sort: liborca.TrackSort = .play_count,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.idle != 0) _ = gtk.g_source_remove(self.idle);
        self.idle = 0;
        self.summaries.deinit(allocator);
        self.current_name.clear(allocator);
        self.filter.clear(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn marked(widget: ?*anyopaque) ?usize {
    const position = @intFromPtr(gtk.g_object_get_data(widget.?, "orca-position"));
    if (position == 0) return null;
    return position - 1;
}

fn markPosition(widget: *gtk.Widget, position: usize) void {
    gtk.g_object_set_data(widget, "orca-position", @ptrFromInt(position + 1));
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
    const list = genres.list orelse return;
    genres.suppress = true;
    gtk.gtk_list_box_remove_all(list);
    genres.suppress = false;
    genres.summaries.clearRetainingCapacity();
    genres.loaded = 0;
    genres.exhausted = false;
    loadNext(self);
    const body = genres.body orelse return;
    if (genres.summaries.items.len == 0) {
        genres.current = null;
        genres.current_name.clear(self.allocator);
        showEmpty(self);
        gtk.gtk_stack_set_visible_child_name(body, "empty");
        return;
    }
    gtk.gtk_stack_set_visible_child_name(body, "content");
    restoreSelection(self);
}

pub fn setFilter(self: *App, text: []const u8) void {
    const genres = &self.genres;
    if (std.mem.eql(u8, text, genres.filter.value)) return;
    genres.filter.set(self.allocator, text);
    if (genres.idle != 0) _ = gtk.g_source_remove(genres.idle);
    genres.idle = 0;
    load(self);
}

fn showEmpty(self: *App) void {
    const empty = self.genres.empty orelse return;
    const searching = self.genres.filter.value.len != 0;
    adw.adw_status_page_set_title(empty, if (searching) "No matching genres" else "No genres yet");
    adw.adw_status_page_set_description(empty, if (searching) "Try another search." else "Genres come from your files\u{2019} tags.");
    if (self.genres.fill_link) |link| gtk.gtk_widget_set_visible(link, @intFromBool(!searching));
}

fn loadNext(self: *App) void {
    const genres = &self.genres;
    const list = genres.list orelse return;
    if (genres.exhausted) return;
    const library = self.library orelse {
        genres.exhausted = true;
        return;
    };
    var page = self.runtime.libraryGenrePage(library, .{
        .filter = genres.filter.value,
        .sort = .track_count,
        .limit = app.page_size,
        .offset = genres.loaded,
    }) catch {
        genres.exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) genres.exhausted = true;
    for (page.items) |genre| {
        genres.summaries.append(self.allocator, Summary.of(genre)) catch {
            genres.exhausted = true;
            break;
        };
        gtk.gtk_list_box_append(list, indexRow(genre));
    }
    genres.loaded += @intCast(page.items.len);
}

fn indexRow(genre: liborca.GenreSummary) *gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "genre-index-row");
    var buffer: [512]u8 = undefined;
    const name = label(strings.terminated(&buffer, genre.name).ptr, "genre-index-name");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    const count = gtk.gtk_label_new(strings.format(&buffer, "{d}", .{genre.track_count}).ptr);
    gtk.gtk_widget_add_css_class(count, "genre-index-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), count);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    gtk.g_object_set_data(row, "orca-name", name);
    return row;
}

fn restoreSelection(self: *App) void {
    const genres = &self.genres;
    if (genres.selected) |wanted| {
        for (genres.summaries.items, 0..) |summary, position| {
            if (summary.id == wanted) return select(self, position);
        }
        if (genres.filter.value.len == 0 and showById(self, wanted)) return;
    }
    select(self, 0);
}

fn select(self: *App, position: usize) void {
    const genres = &self.genres;
    const list = genres.list orelse return;
    const row = gtk.gtk_list_box_get_row_at_index(list, @intCast(position)) orelse return;
    genres.suppress = true;
    gtk.gtk_list_box_select_row(list, row);
    genres.suppress = false;
    showAt(self, row, false);
}

fn showAt(self: *App, row: *gtk.ListBoxRow, persist: bool) void {
    const genres = &self.genres;
    const index = gtk.gtk_list_box_row_get_index(row);
    if (index < 0 or @as(usize, @intCast(index)) >= genres.summaries.items.len) return;
    const name = gtk.g_object_get_data(gtk.cast(gtk.Widget, row), "orca-name") orelse return;
    const text = std.mem.span(gtk.gtk_label_get_text(gtk.cast(gtk.Label, name)));
    showGenre(self, genres.summaries.items[@intCast(index)], text, persist);
}

fn showById(self: *App, genre_id: i64) bool {
    const library = self.library orelse return false;
    const genre = (self.runtime.libraryGenre(library, genre_id) catch null) orelse return false;
    defer genre.deinit(self.allocator);
    if (self.genres.list) |list| {
        self.genres.suppress = true;
        gtk.gtk_list_box_unselect_all(list);
        self.genres.suppress = false;
    }
    showGenre(self, Summary.of(genre), genre.name, false);
    return true;
}

fn rowSelected(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.genres.suppress) return;
    showAt(self, gtk.cast(gtk.ListBoxRow, row orelse return), true);
}

fn listMoved(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.genres.exhausted or self.genres.stale) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page) loadNext(self);
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
    if (genres.hero_name) |hero_name| gtk.gtk_label_set_text(hero_name, strings.terminated(&buffer, name).ptr);
    if (genres.hero_stats) |stats| showStats(stats, summary);
    const library = self.library orelse return;
    fillAlbums(self, library, summary);
    fillArtists(self, library, summary.id);
    fillTracks(self, library, summary.id);
}

fn durationText(buffer: []u8, milliseconds: i64) ?[:0]const u8 {
    if (milliseconds <= 0) return null;
    const seconds: u64 = @intCast(@divTrunc(milliseconds, 1000));
    const minutes = seconds / 60;
    if (minutes >= 60) return strings.format(buffer, "{d}h {d}m", .{ minutes / 60, minutes % 60 });
    if (minutes > 0) return strings.format(buffer, "{d}m", .{minutes});
    if (seconds > 0) return strings.format(buffer, "{d}s", .{seconds});
    return null;
}

fn statLabel(box: *gtk.Box, text: [*:0]const u8) void {
    if (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box)) != null) {
        const separator = gtk.gtk_label_new("·");
        gtk.gtk_widget_add_css_class(separator, "artist-genre-separator");
        gtk.gtk_box_append(box, separator);
    }
    const piece = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(piece, "numeric");
    gtk.gtk_box_append(box, piece);
}

fn countText(buffer: []u8, count: u32, one: []const u8, many: []const u8) [:0]const u8 {
    return strings.format(buffer, "{d} {s}", .{ count, if (count == 1) one else many });
}

fn showStats(box: *gtk.Box, summary: Summary) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
    var buffer: [48]u8 = undefined;
    statLabel(box, countText(&buffer, summary.track_count, "track", "tracks").ptr);
    statLabel(box, countText(&buffer, summary.release_count, "album", "albums").ptr);
    statLabel(box, countText(&buffer, summary.artist_count, "artist", "artists").ptr);
    if (durationText(&buffer, summary.total_duration_ms)) |duration| statLabel(box, duration.ptr);
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, widget), 1);
    gtk.gtk_widget_add_css_class(widget, class);
    return widget;
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
    collectPlayable(self, genre_id, self.genres.track_sort, &list);
    if (list.ids.items.len == 0) return self.toast("No track in this genre has a playable file");
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

fn moreClicked(button: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const widget = gtk.cast(gtk.Widget, button.?);
    const model = gtk.g_menu_new();
    defer gtk.g_object_unref(model);
    gtk.g_menu_append(model, "Create Smart Playlist", "genre.smart-playlist");
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popupModel(widget, gtk.cast(gtk.GMenuModel, model), x, y);
}

fn buildHeader(self: *App) *gtk.Widget {
    const header = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(header, "genre-header");
    const eyebrow = gtk.gtk_label_new("Genre");
    gtk.gtk_widget_add_css_class(eyebrow, "artist-overline");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, eyebrow), 0);
    const name = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(name, "genre-hero-name");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, name), gtk.true_);
    self.genres.hero_name = gtk.cast(gtk.Label, name);
    const stats = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(stats, "genre-hero-stats");
    self.genres.hero_stats = gtk.cast(gtk.Box, stats);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "artist-actions");
    const play = albums.pill("Play", "orca-play-symbolic", true);
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    const shuffle = albums.pill("Shuffle", "orca-shuffle-symbolic", false);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), self);

    const group = gtk.g_simple_action_group_new();
    const action = gtk.g_simple_action_new("smart-playlist", null).?;
    _ = gtk.signalConnect(action, "activate", gtk.callback(smartPlaylistActivated), self);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
    gtk.gtk_widget_insert_action_group(header, "genre", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    const more = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    for ([_]*gtk.Widget{ play, shuffle, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);

    for ([_]*gtk.Widget{ eyebrow, name, stats, actions }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, header), piece);
    return header;
}

fn sectionHeading(text: [*:0]const u8) *gtk.Widget {
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(heading, "artist-section-heading");
    const title = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0);
    gtk.gtk_widget_add_css_class(title, "artist-section-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    return heading;
}

fn section(text: [*:0]const u8, spacing: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, spacing);
    gtk.gtk_widget_add_css_class(box, "genre-section");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), sectionHeading(text));
    return box;
}

fn showSection(widget: ?*gtk.Widget, visible: bool) void {
    gtk.gtk_widget_set_visible(widget orelse return, if (visible) gtk.true_ else gtk.false_);
}

fn albumsSeeAll(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const genre = self.genres.current orelse return;
    albums.showGenre(self, genre.id);
}

fn albumPlayClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = marked(button) orelse return;
    if (position >= self.genres.release_count) return;
    albums.playRelease(self, self.genres.release_ids[position]);
}

fn albumTile(self: *App, release: liborca.ReleaseSummary, position: usize, size: art.Size) *gtk.Widget {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_add_css_class(tile, "artist-album-tile");
    gtk.gtk_widget_add_css_class(tile, "genre-album-tile");
    gtk.gtk_widget_set_size_request(tile, album_pixels, -1);
    const cover = art.newCover(self, art.initialsPlaceholder(), album_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release.id, size));
    const play_button = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    for ([_][*:0]const u8{ "tile-play", "tile-action", "circular" }) |class| gtk.gtk_widget_add_css_class(play_button, class);
    gtk.gtk_widget_set_halign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(play_button, "Play Album");
    markPosition(play_button, position);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(albumPlayClicked), self);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "album-cover-frame");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), play_button);
    const playing = albums.playingBadge();
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), playing);
    gtk.g_object_set_data(tile, "orca-playing", playing);
    albums.showPlaying(tile, self.playing().matches(.release, release.id));
    var buffer: [512]u8 = undefined;
    const title = label(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr, "tile-title");
    const artist = label(strings.terminated(&buffer, release.album_artist).ptr, "tile-artist");
    for ([_]*gtk.Widget{ frame, title, artist }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
    return tile;
}

fn fillAlbums(self: *App, library: liborca.LibraryHandle, summary: Summary) void {
    const genres = &self.genres;
    const grid = genres.album_grid orelse return;
    gtk.gtk_flow_box_remove_all(grid);
    genres.release_count = 0;
    var page = self.runtime.libraryReleasePage(library, .{
        .genre_id = summary.id,
        .sort = .most_played,
        .limit = album_limit,
    }) catch return showSection(genres.album_section, false);
    defer page.deinit();
    const size = albums.coverArtSize(gtk.cast(gtk.Widget, grid), album_pixels);
    for (page.items[0..@min(page.items.len, album_limit)], 0..) |release, index| {
        gtk.gtk_flow_box_append(grid, albumTile(self, release, index, size));
        genres.release_ids[index] = release.id;
        genres.release_count = index + 1;
    }
    if (genres.see_all) |see_all| {
        var buffer: [48]u8 = undefined;
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, see_all), strings.format(&buffer, "See all {d}", .{summary.release_count}).ptr);
        showSection(see_all, summary.release_count > genres.release_count);
    }
    showSection(genres.album_section, genres.release_count != 0);
}

fn albumActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= self.genres.release_count) return;
    const navigation = self.genres.navigation orelse return;
    albums.openAlbum(self, navigation, self.genres.release_ids[@intCast(index)]);
}

fn artistRow(self: *App, artist: liborca.ArtistSummary) *gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "genre-artist");
    const photo = art.newCover(self, art.initialsPlaceholder(), artist_pixels);
    gtk.gtk_widget_add_css_class(photo, "artist-photo");
    gtk.gtk_widget_add_css_class(photo, "genre-artist-photo");
    gtk.gtk_widget_set_valign(photo, gtk.ALIGN_CENTER);
    art.setInitials(photo, artist.name);
    art.showArtist(self, photo, artist.id, if (artist.has_photo) .stored else .absent, null, art.Size.atLeast(artist_pixels));
    var buffer: [512]u8 = undefined;
    const name = label(strings.terminated(&buffer, if (artist.name.len != 0) artist.name else "Unknown Artist").ptr, "genre-row-title");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    const count = gtk.gtk_label_new(countText(&buffer, artist.track_count, "track", "tracks").ptr);
    gtk.gtk_widget_add_css_class(count, "genre-row-detail");
    gtk.gtk_widget_add_css_class(count, "numeric");
    for ([_]*gtk.Widget{ photo, name, count }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
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
    }) catch return showSection(genres.artist_section, false);
    defer page.deinit();
    for (page.items[0..@min(page.items.len, artist_limit)], 0..) |artist, index| {
        gtk.gtk_list_box_append(list, artistRow(self, artist));
        genres.artist_ids[index] = artist.id;
        genres.artist_count = index + 1;
    }
    showSection(genres.artist_section, genres.artist_count != 0);
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
    artist_page.openArtist(self, navigation, self.genres.artist_ids[position]);
}

fn trackRow(self: *App, summary: liborca.TrackSummary, position: usize) *gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "artist-track-row");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "artist-track");
    var buffer: [512]u8 = undefined;
    const title = label(strings.terminated(&buffer, if (summary.title.len != 0) summary.title else "Untitled").ptr, "artist-track-title");
    const artist = label(strings.terminated(&buffer, summary.artist).ptr, "artist-track-album");
    const titles = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(titles, gtk.true_);
    gtk.gtk_widget_set_valign(titles, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, titles), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, titles), artist);
    const duration: [:0]const u8 = if (summary.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else "")
    else
        "";
    const duration_label = gtk.gtk_label_new(duration.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration_label), 1.0);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "artist-track-duration");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), titles);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), duration_label);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) gtk.gtk_widget_set_sensitive(row, gtk.false_);
    self.genres.tracks[position] = .{
        .target = .{ .track_id = summary.id, .recording_id = summary.recording_id, .feedback = summary.feedback },
        .row = row,
    };
    self.genres.track_ids[position] = summary.id;
    return row;
}

fn topTracks(self: *App, library: liborca.LibraryHandle, genre_id: i64, sort: liborca.TrackSort) ?liborca.TrackPage {
    return self.runtime.libraryTrackQuery(library, "", .{
        .genre_id = genre_id,
        .sort = sort,
        .direction = .descending,
        .limit = track_limit,
    }) catch null;
}

fn fillTracks(self: *App, library: liborca.LibraryHandle, genre_id: i64) void {
    const genres = &self.genres;
    const list = genres.track_list orelse return;
    gtk.gtk_list_box_remove_all(list);
    genres.track_count = 0;
    genres.track_ids = @splat(0);
    genres.track_sort = .play_count;
    var page = topTracks(self, library, genre_id, .play_count) orelse return showSection(genres.track_section, false);
    const played = for (page.items) |item| {
        if (item.play_count != 0) break true;
    } else false;
    if (!played) {
        if (topTracks(self, library, genre_id, .rating)) |rated| {
            page.deinit();
            page = rated;
            genres.track_sort = .rating;
        }
    }
    defer page.deinit();
    for (page.items[0..@min(page.items.len, track_limit)], 0..) |summary, position| {
        gtk.gtk_list_box_append(list, trackRow(self, summary, position));
        genres.track_count = position + 1;
    }
    markPlaying(self, self.shown_track_id);
    showSection(genres.track_section, genres.track_count != 0);
}

fn trackSelected(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = rowPosition(row orelse return) orelse return;
    if (position >= self.genres.track_count) return;
    details.choose(self, self.genres.track_ids[0..], self.genres.track_ids[position]);
}

fn trackActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = rowPosition(row) orelse return;
    if (position >= self.genres.track_count) return;
    playGenre(self, false, self.genres.track_ids[position]);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const value = switch (change) {
        .feedback => |value| value,
        .rating => return,
    };
    for (self.genres.tracks[0..self.genres.track_count]) |*track| {
        const recording = track.target.recording_id orelse continue;
        if (changed.contains(recording)) track.target.feedback = value;
    }
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    for (self.genres.tracks[0..self.genres.track_count]) |track| {
        const row = track.row orelse continue;
        if (track_id == track.target.track_id)
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
    gtk.gtk_widget_add_css_class(list, "artist-tracks");
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

fn buildAlbums(self: *App) *gtk.Widget {
    const box = section("Albums", 14);
    self.genres.album_section = box;
    const see_all = gtk.gtk_button_new_with_label("See all");
    gtk.gtk_widget_add_css_class(see_all, "flat");
    gtk.gtk_widget_add_css_class(see_all, "see-all");
    gtk.gtk_widget_set_valign(see_all, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(see_all, "Show this genre\u{2019}s albums in Albums");
    _ = gtk.signalConnect(see_all, "clicked", gtk.callback(albumsSeeAll), self);
    self.genres.see_all = see_all;
    if (gtk.gtk_widget_get_first_child(box)) |heading| gtk.gtk_box_append(gtk.cast(gtk.Box, heading), see_all);
    const grid = gtk.gtk_flow_box_new();
    const flow = gtk.cast(gtk.FlowBox, grid);
    gtk.gtk_flow_box_set_selection_mode(flow, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_homogeneous(flow, gtk.true_);
    gtk.gtk_flow_box_set_min_children_per_line(flow, 2);
    gtk.gtk_flow_box_set_max_children_per_line(flow, album_limit);
    gtk.gtk_flow_box_set_column_spacing(flow, 20);
    gtk.gtk_flow_box_set_row_spacing(flow, 20);
    gtk.gtk_flow_box_set_activate_on_single_click(flow, gtk.true_);
    gtk.gtk_widget_set_halign(grid, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(grid, "artist-albums");
    _ = gtk.signalConnect(grid, "child-activated", gtk.callback(albumActivated), self);
    self.genres.album_grid = flow;
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), grid);
    return box;
}

fn buildDetail(self: *App, bin: *gtk.Widget) *gtk.Widget {
    const detail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 32);
    gtk.gtk_widget_add_css_class(detail, "genre-detail");
    gtk.gtk_widget_set_hexpand(detail, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, detail), buildHeader(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, detail), buildAlbums(self));

    const artist_section = section("Artists", 10);
    gtk.gtk_widget_set_hexpand(artist_section, gtk.true_);
    self.genres.artist_section = artist_section;
    const artist_list = newList("genre-artists");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, artist_list), gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, artist_list), gtk.true_);
    _ = gtk.signalConnect(artist_list, "row-activated", gtk.callback(artistActivated), self);
    self.genres.artist_list = gtk.cast(gtk.ListBox, artist_list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, artist_section), artist_list);

    const track_section = section("Representative Tracks", 10);
    gtk.gtk_widget_set_hexpand(track_section, gtk.true_);
    self.genres.track_section = track_section;
    const track_list = newList("genre-tracks");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, track_list), gtk.SELECTION_SINGLE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, track_list), gtk.false_);
    _ = gtk.signalConnect(track_list, "row-selected", gtk.callback(trackSelected), self);
    _ = gtk.signalConnect(track_list, "row-activated", gtk.callback(trackActivated), self);
    self.genres.track_list = gtk.cast(gtk.ListBox, track_list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, track_section), track_list);

    const pair = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 36);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, pair), gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, pair), artist_section);
    gtk.gtk_box_append(gtk.cast(gtk.Box, pair), track_section);
    gtk.gtk_box_append(gtk.cast(gtk.Box, detail), pair);
    stackBelow(bin, "max-width: 950px", pair, null);
    return detail;
}

fn buildIndex(self: *App) *gtk.Widget {
    const index = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(index, "genre-index");
    gtk.gtk_widget_set_size_request(index, index_pixels, -1);
    gtk.gtk_widget_set_valign(index, gtk.ALIGN_START);
    const heading = gtk.gtk_label_new("Genres");
    gtk.gtk_widget_add_css_class(heading, "display-page");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0);
    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "genre-index-list");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_SINGLE);
    _ = gtk.signalConnect(list, "row-selected", gtk.callback(rowSelected), self);
    self.genres.list = gtk.cast(gtk.ListBox, list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, index), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, index), list);
    return index;
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
    self.genres.empty = page;
    const link = gtk.gtk_button_new_with_label("Fill missing genres from MusicBrainz");
    gtk.gtk_widget_add_css_class(link, "flat");
    gtk.gtk_widget_add_css_class(link, "genre-fill-link");
    gtk.gtk_widget_set_halign(link, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(link, "clicked", gtk.callback(fillClicked), self);
    self.genres.fill_link = link;
    adw.adw_status_page_set_child(page, link);
    return empty;
}

pub fn build(self: *App) *gtk.Widget {
    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 36);
    gtk.gtk_widget_add_css_class(row, "genre-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), buildIndex(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), buildDetail(self, bin));
    stackBelow(bin, "max-width: 890px", row, null);

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), row);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(listMoved),
        self,
    );
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

    const navigation = adw.adw_navigation_view_new();
    self.genres.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(body, "Genres");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(self.genres.navigation.?, root);
    return navigation;
}
