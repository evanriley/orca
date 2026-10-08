//! Home: Daily Mixes, Start Radio, this week's listening and the library at a
//! glance, with the Daily Mix page and the grid of every mix.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const strings = @import("strings.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const playlists = @import("playlists.zig");
const radio = @import("radio.zig");
const radio_reason = @import("radio_reason.zig");
const queue = @import("queue.zig");
const transport = @import("transport.zig");
const preferences = @import("preferences.zig");

const App = app.App;

pub const navigation_tag = "home";
pub const mixes_tag = "mixes";
const mix_tag = "daily-mix";

const recent_limit = liborca.home_max_items;
const list_limit = 4;
const top_artist_limit = 5;
const history_days_needed = 14;
const top_artist_days = 30;
const day_s = std.time.s_per_day;
const mix_day_start_s = 4 * 3600;
const mix_hero_pixels = 220;
const list_art_pixels = 44;
const playing_art_pixels = 52;
const on_this_day_pixels = 56;
const anniversary_limit = 4;
const chart_bar_pixels = 80;
const chart_bar_min_width = 12;
const top_name_width = 120;
const card_link_uri = "settings";

const Tiling = struct {
    min: f64,
    max: f64,
    gap: f64,
    most: c_uint,

    fn columns(self: Tiling, width: f64) c_uint {
        const fitting = @floor((width + self.gap) / (self.min + self.gap));
        if (!(fitting > 1)) return 1;
        return @intFromFloat(@min(fitting, @as(f64, @floatFromInt(self.most))));
    }

    fn pixels(self: Tiling, width: f64, columns_: c_uint) c_int {
        const cell = (width + self.gap) / @as(f64, @floatFromInt(columns_));
        return @intFromFloat(@max(@min(@floor(cell - self.gap), self.max), 64));
    }
};

const mix_row_tiling = Tiling{ .min = 160, .max = 220, .gap = 20, .most = liborca.max_daily_mixes };
const recent_tiling = Tiling{ .min = 132, .max = 180, .gap = 20, .most = recent_limit };
const grid_tiling = Tiling{ .min = 180, .max = 240, .gap = 20, .most = 16 };

const Layout = struct {
    columns: c_uint = 1,
    pixels: c_int = 140,
};

const ListKind = enum { rediscover, deep_cuts };
const list_kinds = std.enums.values(ListKind).len;

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    scroller: ?*gtk.Widget = null,
    subline: ?*gtk.Label = null,
    recording_note: ?*gtk.Widget = null,

    mixes_section: ?*gtk.Widget = null,
    mixes_updated: ?*gtk.Label = null,
    mixes_see_all: ?*gtk.Widget = null,
    mixes_note: ?*gtk.Label = null,
    mixes_flow: ?*gtk.FlowBox = null,
    mixes_layout: Layout = .{},

    playing_cover: ?*gtk.Widget = null,
    playing_title: ?*gtk.Label = null,
    playing_artist: ?*gtk.Label = null,
    playing_track: ?i64 = null,
    playing_shown: bool = false,
    artist_example: ?*gtk.Label = null,
    genre_example: ?*gtk.Label = null,
    loved_count: ?*gtk.Label = null,

    week_card: ?*gtk.Widget = null,
    week_range: ?*gtk.Label = null,
    week_hero: ?*gtk.Label = null,
    week_counts: ?*gtk.Label = null,
    week_chart: ?*gtk.Widget = null,
    week_top: ?*gtk.Label = null,
    week_change: ?*gtk.Label = null,

    recent_section: ?*gtk.Widget = null,
    recent_flow: ?*gtk.FlowBox = null,
    recent_layout: Layout = .{},
    recent_ids: [recent_limit]i64 = @splat(0),
    recent_count: usize = 0,

    unplayed_section: ?*gtk.Widget = null,
    unplayed_flow: ?*gtk.FlowBox = null,
    unplayed_ids: [recent_limit]i64 = @splat(0),
    unplayed_count: usize = 0,

    list_row: ?*gtk.Widget = null,
    list_sections: [list_kinds]?*gtk.Widget = @splat(null),
    list_boxes: [list_kinds]?*gtk.ListBox = @splat(null),
    list_ids: [list_kinds][list_limit]i64 = @splat(@splat(0)),
    list_counts: [list_kinds]usize = @splat(0),
    list_fillers: [list_kinds - 1]?*gtk.Widget = @splat(null),

    top_panel: ?*gtk.Widget = null,
    top_list: ?*gtk.ListBox = null,
    top_ids: [top_artist_limit]i64 = @splat(0),
    top_count: usize = 0,
    collection_albums: ?*gtk.Label = null,
    collection_tracks: ?*gtk.Label = null,
    collection_hours: ?*gtk.Label = null,
    format_rows: [4]?*gtk.Widget = @splat(null),
    format_bars: [4]?*gtk.Widget = @splat(null),
    format_counts: [4]?*gtk.Label = @splat(null),
    day_panel: ?*gtk.Widget = null,
    anniversary_box: ?*gtk.Widget = null,
    anniversary_ids: [anniversary_limit]i64 = @splat(0),
    year_ago: ?*gtk.Widget = null,
    day_release: ?*gtk.Widget = null,
    day_cover: ?*gtk.Widget = null,
    day_when: ?*gtk.Label = null,
    day_title: ?*gtk.Label = null,
    day_artist: ?*gtk.Label = null,
    day_release_id: ?i64 = null,

    grid_scroller: ?*gtk.Widget = null,
    grid_flow: ?*gtk.FlowBox = null,
    grid_note: ?*gtk.Widget = null,
    grid_layout: Layout = .{},

    mix_page: ?*adw.NavigationPage = null,
    mix_backdrop: ?*gtk.Widget = null,
    mix_mosaic: ?*gtk.Widget = null,
    mix_title: ?*gtk.Label = null,
    mix_artists: ?*gtk.Label = null,
    mix_meta: ?*gtk.Label = null,
    mix_makeup: ?*gtk.Widget = null,
    mix_legend: [3]?*gtk.Label = @splat(null),
    mix_rows: ?*gtk.ListBox = null,
    mix_built: ?*gtk.Label = null,
    mix_filled: ?*gtk.Widget = null,
    mix_left: ?*gtk.Label = null,
    open_mix: ?i64 = null,
    entries: [liborca.max_daily_mix_entries]liborca.DailyMixEntry = undefined,
    entry_count: usize = 0,
    entry_ids: [liborca.max_daily_mix_entries]i64 = @splat(0),
    mix_tracks: [liborca.max_daily_mixes][liborca.max_daily_mix_entries]i64 = undefined,
    mix_track_counts: [liborca.max_daily_mixes]usize = @splat(0),

    mixes: liborca.DailyMixes = .{ .state = .not_generated },
    mix_job: ?liborca.JobHandle = null,
    mixes_failed: bool = false,
    loaded: bool = false,
    stale: bool = false,
    layout_idle: c_uint = 0,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

pub fn deinit(self: *App) void {
    if (self.home.layout_idle != 0) _ = gtk.g_source_remove(self.home.layout_idle);
    self.home.layout_idle = 0;
}

pub fn forgetLibrary(self: *App) void {
    const home = &self.home;
    if (home.mix_job) |job| self.runtime.cancelJob(job) catch {};
    home.mix_job = null;
    home.mixes_failed = false;
    home.mixes = .{ .state = .not_generated };
    home.open_mix = null;
    home.entry_count = 0;
    home.mix_track_counts = @splat(0);
    home.loaded = false;
    home.stale = true;
    home.playing_shown = false;
}

pub fn startMixes(self: *App, force: bool) void {
    const library = self.library orelse return;
    if (self.home.mix_job) |job| {
        if (!force) return;
        self.runtime.cancelJob(job) catch {};
        self.home.mix_job = null;
    }
    const clock = queue.localClock();
    self.home.mix_job = self.runtime.startDailyMixes(library, .{
        .now_s = clock.now_s,
        .utc_offset_s = clock.utc_offset_s,
        .force = force,
    }) catch null;
    self.home.mixes_failed = self.home.mix_job == null;
    self.requestTick();
}

pub fn tick(self: *App) void {
    if (self.home.mix_job) |job| finishMixes(self, job);
    if (self.current_page == .home) syncPlaying(self);
}

fn finishMixes(self: *App, job: liborca.JobHandle) void {
    self.home.mixes_failed = if (self.runtime.jobSnapshotSynced(job)) |snapshot| switch (snapshot.state) {
        .succeeded, .cancelled => false,
        .failed => true,
        else => return,
    } else |_| false;
    self.home.mix_job = null;
    mixesChanged(self);
}

fn mixesChanged(self: *App) void {
    readMixes(self);
    showMixes(self);
    showGrid(self);
    showGenreExample(self);
    if (self.home.open_mix) |mix_id| {
        if (findMix(self, mix_id) == null) {
            self.home.open_mix = null;
            if (self.home.navigation) |navigation| if (mixPageShown(self)) window.popToTag(self, navigation, navigation_tag);
        } else loadMix(self);
    }
}

pub fn reload(self: *App) void {
    self.home.stale = true;
    if (self.current_page == .home) refresh(self);
}

pub fn shown(self: *App) void {
    startMixes(self, false);
    refresh(self);
}

pub fn mixExists(self: *App, mix_id: i64) bool {
    if (!self.home.loaded) readMixes(self);
    return findMix(self, mix_id) != null;
}

fn findMix(self: *App, mix_id: i64) ?*const liborca.DailyMix {
    for (self.home.mixes.items()) |*mix| if (mix.id == mix_id) return mix;
    return null;
}

fn readMixes(self: *App) void {
    const library = self.library orelse {
        self.home.mixes = .{ .state = .not_generated };
        return;
    };
    const clock = queue.localClock();
    self.home.mixes = self.runtime.libraryDailyMixes(library, clock.now_s, clock.utc_offset_s) catch .{ .state = .not_generated };
    readMixTracks(self, library);
}

fn readMixTracks(self: *App, library: liborca.LibraryHandle) void {
    const home = &self.home;
    home.mix_track_counts = @splat(0);
    var entries: [liborca.max_daily_mix_entries]liborca.DailyMixEntry = undefined;
    for (home.mixes.items(), 0..) |mix, index| {
        if (index >= home.mix_tracks.len) break;
        const count = self.runtime.libraryDailyMixEntries(library, mix.id, &entries) catch 0;
        for (entries[0..count], 0..) |entry, position| home.mix_tracks[index][position] = entry.track_id;
        home.mix_track_counts[index] = count;
    }
}

fn mixHasTrack(self: *const App, index: usize, track_id: ?i64) bool {
    const id = track_id orelse return false;
    if (index >= self.home.mix_tracks.len) return false;
    return std.mem.indexOfScalar(i64, self.home.mix_tracks[index][0..self.home.mix_track_counts[index]], id) != null;
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    markMixRows(self, track_id);
    for ([_]?*gtk.FlowBox{ self.home.mixes_flow, self.home.grid_flow }) |maybe| {
        const flow = maybe orelse continue;
        markMixTiles(self, flow, track_id);
    }
}

fn markMixTiles(self: *App, flow: *gtk.FlowBox, track_id: ?i64) void {
    var index: usize = 0;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, flow));
    while (child) |cell| : ({
        child = gtk.gtk_widget_get_next_sibling(cell);
        index += 1;
    }) {
        const tile = gtk.gtk_flow_box_child_get_child(gtk.cast(gtk.FlowBoxChild, cell)) orelse continue;
        const mix = if (index < self.home.mixes.count) &self.home.mixes.items()[index] else continue;
        const playing = mixHasTrack(self, index, track_id);
        albums.showPlaying(tile, playing);
        labelMix(mix, cell, playing);
    }
}

fn markMixRows(self: *App, track_id: ?i64) void {
    const rows = self.home.mix_rows orelse return;
    for (self.home.entry_ids[0..self.home.entry_count], 0..) |id, index| {
        const row = gtk.gtk_list_box_get_row_at_index(rows, @intCast(index)) orelse continue;
        const playing = track_id == id;
        const widget = gtk.cast(gtk.Widget, row);
        if (playing)
            gtk.gtk_widget_add_css_class(widget, "now-playing")
        else
            gtk.gtk_widget_remove_css_class(widget, "now-playing");
        if (gtk.g_object_get_data(widget, "orca-number")) |number|
            gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, number), if (playing) "playing" else "number");
        labelMixRow(widget, index, playing);
    }
}

fn labelMixRow(row: *gtk.Widget, index: usize, playing: bool) void {
    const title = gtk.g_object_get_data(row, "orca-title") orelse return;
    const artist = gtk.g_object_get_data(row, "orca-artist") orelse return;
    const reason = gtk.g_object_get_data(row, "orca-reason") orelse return;
    var text: [800]u8 = undefined;
    setAccessibleLabel(row, strings.format(&text, "{d}. {s} by {s}, {s}{s}", .{
        index + 1,
        std.mem.span(gtk.gtk_label_get_text(gtk.cast(gtk.Label, title))),
        std.mem.span(gtk.gtk_label_get_text(gtk.cast(gtk.Label, artist))),
        std.mem.span(gtk.gtk_label_get_text(gtk.cast(gtk.Label, reason))),
        if (playing) ", now playing" else "",
    }).ptr);
}

fn localTime() liborca.HomeLocalTime {
    const clock = queue.localClock();
    return .{ .now_s = clock.now_s, .utc_offset_s = clock.utc_offset_s };
}

fn refresh(self: *App) void {
    const home = &self.home;
    home.loaded = true;
    home.stale = false;
    readMixes(self);
    showSubline(self);
    const library = self.library orelse {
        hideAll(self);
        return;
    };
    const time = localTime();
    const history = self.runtime.libraryHistoryAge(library, time) catch liborca.HomeHistoryAge{};
    const recording = history.recording_enabled;
    const enough_history = if (history.first_listen_at) |first| time.now_s - first >= history_days_needed * day_s else false;
    const stats = self.home_stats;

    if (home.recording_note) |note| gtk.gtk_widget_set_visible(note, boolean(!recording));
    if (home.mixes_section) |section| gtk.gtk_widget_set_visible(section, boolean(recording and self.home.mixes.state != .off));
    showMixes(self);
    showRadioCard(self, library);
    const week_shown = recording and enough_history and stats;
    if (home.week_card) |card| gtk.gtk_widget_set_visible(card, boolean(week_shown));
    if (week_shown) showWeek(self, library, time);
    showRecent(self, library, time, recording);
    showUnplayed(self, library, time);
    showLists(self, library, time, recording and enough_history);
    const top_shown = recording and stats;
    if (home.top_panel) |top_panel| gtk.gtk_widget_set_visible(top_panel, boolean(top_shown));
    if (top_shown) showTopArtists(self, library, time);
    showCollection(self, library);
    showOnThisDay(self, library, time, recording);
    showGrid(self);
    syncPlaying(self);
}

fn hideAll(self: *App) void {
    const home = &self.home;
    for ([_]?*gtk.Widget{ home.mixes_section, home.week_card, home.recent_section, home.unplayed_section, home.list_row, home.top_panel, home.recording_note }) |maybe|
        if (maybe) |widget| gtk.gtk_widget_set_visible(widget, gtk.false_);
}

fn showSubline(self: *App) void {
    const subline = self.home.subline orelse return;
    const now = gtk.g_date_time_new_now_local() orelse return;
    defer gtk.g_date_time_unref(now);
    const date = gtk.g_date_time_format(now, "%A, %B %-e") orelse return;
    defer gtk.g_free(date);
    var buffer: [256]u8 = undefined;
    const text = strings.format(&buffer, "{s} · Everything here is built on this computer from your library and listening history.", .{std.mem.span(date)});
    gtk.gtk_label_set_text(subline, text.ptr);
}

fn label(text: ?[*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    return widget;
}

fn ellipsized(text: ?[*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    return widget;
}

fn wrapped(text: ?[*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, widget), gtk.WRAP_WORD_CHAR);
    return widget;
}

fn asideText(text: ?[*:0]const u8) *gtk.Widget {
    const widget = wrapped(text, "daily-mix-aside-text");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, widget), 1);
    return widget;
}

fn box(orientation: c_int, spacing: c_int, class: ?[*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_box_new(orientation, spacing);
    if (class) |name| gtk.gtk_widget_add_css_class(widget, name);
    return widget;
}

fn append(parent: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, parent), child);
}

fn setText(maybe: ?*gtk.Label, text: [:0]const u8) void {
    if (maybe) |widget| gtk.gtk_label_set_text(widget, text.ptr);
}

fn setAccessibleLabel(widget: *gtk.Widget, text: [*:0]const u8) void {
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, widget), gtk.ACCESSIBLE_PROPERTY_LABEL, text, @as(c_int, -1));
}

fn setAccessibleDescription(widget: *gtk.Widget, text: [*:0]const u8) void {
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, widget), gtk.ACCESSIBLE_PROPERTY_DESCRIPTION, text, @as(c_int, -1));
}

fn clearBox(parent: *gtk.Widget) void {
    while (gtk.gtk_widget_get_first_child(parent)) |child| gtk.gtk_box_remove(gtk.cast(gtk.Box, parent), child);
}

fn sectionTitle(text: [*:0]const u8) *gtk.Widget {
    const title = label(text, "section-title");
    gtk.gtk_widget_add_css_class(title, "home-section-title");
    return title;
}

fn overline(text: [*:0]const u8) *gtk.Widget {
    const widget = label(text, "section-label");
    gtk.gtk_widget_add_css_class(widget, "home-overline");
    return widget;
}

fn newList(class: [*:0]const u8) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "home-list");
    gtk.gtk_widget_add_css_class(list, class);
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.true_);
    return list;
}

fn newFlow(class: [*:0]const u8) *gtk.FlowBox {
    const widget = gtk.gtk_flow_box_new();
    const flow = gtk.cast(gtk.FlowBox, widget);
    gtk.gtk_widget_add_css_class(widget, "home-tiles");
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_flow_box_set_selection_mode(flow, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_homogeneous(flow, gtk.true_);
    gtk.gtk_flow_box_set_column_spacing(flow, 20);
    gtk.gtk_flow_box_set_row_spacing(flow, 24);
    gtk.gtk_flow_box_set_activate_on_single_click(flow, gtk.true_);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_START);
    gtk.gtk_widget_set_halign(widget, gtk.ALIGN_START);
    return flow;
}

fn linkLabel(markup: [*:0]const u8, class: [*:0]const u8, self: *App) *gtk.Widget {
    const widget = wrapped(null, class);
    gtk.gtk_label_set_markup(gtk.cast(gtk.Label, widget), markup);
    _ = gtk.signalConnect(widget, "activate-link", gtk.callback(settingsLinkActivated), self);
    return widget;
}

fn settingsLinkActivated(_: ?*anyopaque, _: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    openListeningSettings(state(data));
    return gtk.true_;
}

fn openListeningSettings(self: *App) void {
    preferences.selectTab(self, .listening);
    window.goTo(self, .settings);
}

const cell_keys = [_][*:0]const u8{ "orca-cell-0", "orca-cell-1", "orca-cell-2", "orca-cell-3" };

fn newMixArt(self: *App, mix: *const liborca.DailyMix, pixels: c_int) *gtk.Widget {
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "home-mix-art");
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(frame, gtk.ALIGN_START);
    const sizer = box(gtk.ORIENTATION_VERTICAL, 0, null);
    gtk.gtk_widget_set_size_request(sizer, pixels, pixels);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), sizer);
    gtk.g_object_set_data(frame, "orca-art-sizer", sizer);
    const covers = mix.coverReleases();
    if (covers.len >= cell_keys.len) {
        const grid = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
        gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, grid), gtk.true_);
        for (0..2) |row_index| {
            const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
            gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, row), gtk.true_);
            for (0..2) |column| {
                const cell = playlists.fillingCover(self, 24);
                art.show(self, cell, art.Key.release(covers[row_index * 2 + column], .medium));
                gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            }
            gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
        }
        gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), grid);
    } else {
        const single = playlists.fillingCover(self, 40);
        if (covers.len != 0) art.show(self, single, art.Key.release(covers[0], .tile));
        gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), single);
    }
    var buffer: [16]u8 = undefined;
    const chip = label(strings.format(&buffer, "Mix {d}", .{mixNumber(mix)}).ptr, "home-mix-chip");
    gtk.gtk_widget_set_halign(chip, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(chip, gtk.ALIGN_END);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), chip);
    return frame;
}

fn mixNumber(mix: *const liborca.DailyMix) u16 {
    return @as(u16, mix.ordinal) + 1;
}

fn writeArtists(writer: *std.Io.Writer, mix: *const liborca.DailyMix) !void {
    const artists = mix.mixArtists();
    const named = @min(artists.len, 3);
    for (artists[0..named], 0..) |*artist, index| {
        if (index != 0) try writer.writeAll(if (index + 1 == named and artists.len <= 3) " and " else ", ");
        try writer.writeAll(artist.name());
    }
    if (artists.len > 3) try writer.writeAll(" and more");
}

fn writeKindSummary(writer: *std.Io.Writer, mix: *const liborca.DailyMix) !void {
    switch (mix.kind) {
        .genre => {},
        .rarely_played => try writer.writeAll("Tracks from your library you haven't heard in a year"),
        .decade => if (mix.decade) |decade|
            try writer.print("Tracks released in the {d}s", .{decade})
        else
            try writer.print("Tracks released in the {s}", .{mix.name()}),
        .new_to_you => try writer.writeAll("Albums you haven't played by artists you listen to"),
        .deep_cuts => try writer.writeAll("Rarely played tracks by artists you play most"),
        .upbeat => try writer.writeAll("The most energetic third of your analyzed music"),
        .wind_down => try writer.writeAll("The calmest third of your analyzed music"),
    }
}

fn artistsText(buffer: []u8, mix: *const liborca.DailyMix) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (mix.kind == .rarely_played or mix.mixArtists().len == 0)
        writeKindSummary(&writer, mix) catch {}
    else
        writeArtists(&writer, mix) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn newMixTile(self: *App, mix: *const liborca.DailyMix, pixels: c_int) *gtk.Widget {
    const tile = box(gtk.ORIENTATION_VERTICAL, 0, "home-mix-tile");
    const frame = newMixArt(self, mix, pixels);
    gtk.g_object_set_data(tile, "orca-art", frame);
    const badge = albums.playingBadge();
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), badge);
    gtk.g_object_set_data(tile, "orca-playing", badge);
    var name_buffer: [300]u8 = undefined;
    const name = strings.terminated(&name_buffer, mix.name());
    const title = ellipsized(name.ptr, "home-tile-title");
    var artists_buffer: [1200]u8 = undefined;
    const artists = artistsText(&artists_buffer, mix);
    const detail = wrapped(artists.ptr, "home-tile-detail");
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, detail), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, detail), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, detail), 1);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, title), 1);
    append(tile, &.{ frame, title, detail });
    return tile;
}

fn sizeTiles(flow: *gtk.FlowBox, pixels: c_int) void {
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, flow));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        const tile = gtk.gtk_flow_box_child_get_child(gtk.cast(gtk.FlowBoxChild, cell)) orelse continue;
        const frame = playlists.part(tile, "orca-art") orelse continue;
        const sizer = playlists.part(frame, "orca-art-sizer") orelse continue;
        gtk.gtk_widget_set_size_request(sizer, pixels, pixels);
    }
}

fn showFirstCells(flow: *gtk.FlowBox, count: c_uint) void {
    var index: c_uint = 0;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, flow));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        gtk.gtk_widget_set_visible(cell, boolean(index < count));
        index += 1;
    }
}

fn fillMixes(self: *App, flow: *gtk.FlowBox, layout: Layout) void {
    gtk.gtk_flow_box_remove_all(flow);
    for (self.home.mixes.items(), 0..) |*mix, index| {
        const tile = newMixTile(self, mix, layout.pixels);
        gtk.gtk_flow_box_append(flow, tile);
        const playing = mixHasTrack(self, index, self.shown_track_id);
        albums.showPlaying(tile, playing);
        if (gtk.gtk_widget_get_parent(tile)) |cell| labelMix(mix, cell, playing);
    }
}

fn labelMix(mix: *const liborca.DailyMix, widget: *gtk.Widget, playing: bool) void {
    var name_buffer: [300]u8 = undefined;
    const name = strings.terminated(&name_buffer, mix.name());
    var artists_buffer: [1200]u8 = undefined;
    const artists = artistsText(&artists_buffer, mix);
    var accessible: [1600]u8 = undefined;
    setAccessibleLabel(widget, strings.format(&accessible, "Mix {d}, {s}: {s}{s}", .{ mixNumber(mix), name, artists, if (playing) ", playing" else "" }).ptr);
}

fn updatedText(buffer: []u8, mixes: *const liborca.DailyMixes, clock: radio_reason.Clock, capital: bool) [:0]const u8 {
    const day = mixes.local_day orelse return strings.terminated(buffer, "");
    const today = @divFloor(clock.now_s + clock.utc_offset_s - mix_day_start_s, day_s);
    const started = day * day_s + mix_day_start_s - clock.utc_offset_s;
    const moment = gtk.g_date_time_new_from_unix_local(started) orelse return strings.terminated(buffer, "");
    defer gtk.g_date_time_unref(moment);
    const time = gtk.g_date_time_format(moment, "%-l:%M %p") orelse return strings.terminated(buffer, "");
    defer gtk.g_free(time);
    const verb = if (capital) "Updated" else "updated";
    if (day == today) return strings.format(buffer, "{s} today at {s}", .{ verb, std.mem.span(time) });
    if (day + 1 == today) return strings.format(buffer, "{s} yesterday at {s}", .{ verb, std.mem.span(time) });
    const date = gtk.g_date_time_format(moment, "%B %-e") orelse return strings.terminated(buffer, "");
    defer gtk.g_free(date);
    return strings.format(buffer, "{s} {s}", .{ verb, std.mem.span(date) });
}

fn showMixes(self: *App) void {
    const home = &self.home;
    const flow = home.mixes_flow orelse return;
    const mixes = &home.mixes;
    const ready = mixes.state == .ready and mixes.count != 0;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, flow), boolean(ready));
    if (home.mixes_see_all) |see_all| gtk.gtk_widget_set_visible(see_all, boolean(ready));
    if (home.mixes_section) |section| if (mixes.state == .off) gtk.gtk_widget_set_visible(section, gtk.false_);
    var buffer: [128]u8 = undefined;
    setText(home.mixes_updated, if (ready) updatedText(&buffer, mixes, queue.localClock(), true) else "");
    if (home.mixes_note) |note| {
        const text: [:0]const u8 = switch (mixes.state) {
            .ready => if (mixes.count == 0) "No mixes today." else "",
            .not_enough_history => "Mixes appear after a few days of listening.",
            .not_generated => if (home.mix_job != null)
                "Making today\u{2019}s mixes\u{2026}"
            else if (home.mixes_failed)
                "Today\u{2019}s mixes could not be made. Orca tries again when you come back to Home."
            else
                "Mixes appear after a few days of listening.",
            .off => "",
        };
        gtk.gtk_label_set_text(note, text.ptr);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, note), boolean(text.len != 0));
    }
    fillMixes(self, flow, home.mixes_layout);
}

fn showGrid(self: *App) void {
    const home = &self.home;
    const flow = home.grid_flow orelse return;
    fillMixes(self, flow, home.grid_layout);
    if (home.grid_note) |note| gtk.gtk_widget_set_visible(note, boolean(home.mixes.count == 0));
}

fn mixActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    const items = self.home.mixes.items();
    if (index < 0 or @as(usize, @intCast(index)) >= items.len) return;
    openMix(self, items[@intCast(index)].id);
}

fn seeAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    openGrid(state(data));
}

pub fn openGrid(self: *App) void {
    window.showPage(self, .home);
    const navigation = self.home.navigation orelse return;
    const visible = adw.adw_navigation_view_get_visible_page_tag(navigation);
    if (visible != null and std.mem.eql(u8, std.mem.span(visible.?), mixes_tag)) return;
    window.popToTag(self, navigation, navigation_tag);
    adw.adw_navigation_view_push_by_tag(navigation, mixes_tag);
}

fn seedButton(self: *App, icon: [*:0]const u8, title: [*:0]const u8, detail: *gtk.Widget, picker: ?radio.HomeSeed) *gtk.Widget {
    const content = box(gtk.ORIENTATION_HORIZONTAL, 10, null);
    const image = gtk.gtk_image_new_from_icon_name(icon);
    gtk.gtk_widget_add_css_class(image, "home-seed-icon");
    gtk.gtk_widget_set_valign(image, gtk.ALIGN_CENTER);
    const text = box(gtk.ORIENTATION_VERTICAL, 1, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    append(text, &.{ ellipsized(title, "home-seed-title"), detail });
    append(content, &.{ image, text });
    const button = if (picker != null) gtk.gtk_menu_button_new() else gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "home-seed");
    gtk.gtk_widget_set_hexpand(button, gtk.true_);
    setAccessibleLabel(button, title);
    if (picker) |seed| {
        gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), content);
        radio.buildHomePicker(self, seed, button);
    } else {
        gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
        _ = gtk.signalConnect(button, "clicked", gtk.callback(lovedClicked), self);
    }
    return button;
}

fn lovedClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    radio.startFromLoved(state(data));
}

fn startPlayingClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    radio.startFromPlaying(state(data));
}

fn buildRadioCard(self: *App) *gtk.Widget {
    const home = &self.home;
    const card = box(gtk.ORIENTATION_VERTICAL, 14, "home-card");
    gtk.gtk_widget_add_css_class(card, "home-radio-card");
    gtk.gtk_widget_set_hexpand(card, gtk.true_);
    const heading = box(gtk.ORIENTATION_HORIZONTAL, 10, "home-card-heading");
    const icon = gtk.gtk_image_new_from_icon_name("orca-radio-symbolic");
    gtk.gtk_widget_add_css_class(icon, "home-card-icon");
    const title = label("Start Radio", "home-card-title");
    const subtitle = ellipsized("Endless, from music you already own", "home-card-subtitle");
    append(heading, &.{ icon, title, subtitle });

    const playing = box(gtk.ORIENTATION_HORIZONTAL, 14, "home-playing");
    const cover = art.newCover(self, art.iconPlaceholder(playing_art_pixels), playing_art_pixels);
    gtk.gtk_widget_add_css_class(cover, "home-playing-cover");
    home.playing_cover = cover;
    const text = box(gtk.ORIENTATION_VERTICAL, 1, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    const from = label("From what\u{2019}s playing", "home-playing-from");
    const track = ellipsized(null, "home-playing-title");
    const artist = ellipsized(null, "home-playing-artist");
    home.playing_title = gtk.cast(gtk.Label, track);
    home.playing_artist = gtk.cast(gtk.Label, artist);
    append(text, &.{ from, track, artist });
    const start = albums.pill("Start", "orca-play-symbolic", true);
    gtk.gtk_widget_add_css_class(start, "home-start");
    gtk.gtk_widget_set_valign(start, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(start, "Start Radio from what\u{2019}s playing");
    _ = gtk.signalConnect(start, "clicked", gtk.callback(startPlayingClicked), self);
    append(playing, &.{ cover, text, start });

    const artist_example = ellipsized("Search your artists", "home-seed-detail");
    const genre_example = ellipsized("Search your genres", "home-seed-detail");
    const loved = ellipsized(null, "home-seed-detail");
    home.artist_example = gtk.cast(gtk.Label, artist_example);
    home.genre_example = gtk.cast(gtk.Label, genre_example);
    home.loved_count = gtk.cast(gtk.Label, loved);
    const seeds = gtk.gtk_grid_new();
    gtk.gtk_grid_set_column_spacing(gtk.cast(gtk.Grid, seeds), 8);
    gtk.gtk_grid_set_row_spacing(gtk.cast(gtk.Grid, seeds), 8);
    gtk.gtk_grid_set_column_homogeneous(gtk.cast(gtk.Grid, seeds), gtk.true_);
    const grid = gtk.cast(gtk.Grid, seeds);
    gtk.gtk_grid_attach(grid, seedButton(self, "orca-artists-symbolic", "From an artist", artist_example, .artist), 0, 0, 1, 1);
    gtk.gtk_grid_attach(grid, seedButton(self, "orca-genres-symbolic", "From a genre", genre_example, .genre), 1, 0, 1, 1);
    gtk.gtk_grid_attach(grid, seedButton(self, "orca-clock-symbolic", "From a decade", ellipsized("e.g. 2010s", "home-seed-detail"), .decade), 0, 1, 1, 1);
    gtk.gtk_grid_attach(grid, seedButton(self, "orca-heart-outline-symbolic", "From your loved tracks", loved, null), 1, 1, 1, 1);
    append(card, &.{ heading, playing, seeds });
    return card;
}

fn showRadioCard(self: *App, library: liborca.LibraryHandle) void {
    const home = &self.home;
    const loved = self.runtime.libraryTrackMatchCount(library, .{ .loved_only = true }) catch 0;
    var buffer: [64]u8 = undefined;
    setText(home.loved_count, strings.format(&buffer, "{f} loved", .{strings.grouped(loved)}));
    var top: [1]liborca.HomeTopArtist = undefined;
    const time = localTime();
    const found = self.runtime.libraryTopArtists(library, time, top_artist_days, &top) catch 0;
    var artist_buffer: [300]u8 = undefined;
    setText(home.artist_example, if (found != 0) strings.format(&artist_buffer, "e.g. {s}", .{top[0].name.slice()}) else "Search your artists");
    showGenreExample(self);
    home.playing_shown = false;
    syncPlaying(self);
}

fn showGenreExample(self: *App) void {
    var buffer: [300]u8 = undefined;
    setText(self.home.genre_example, if (firstGenreMix(self)) |mix| strings.format(&buffer, "e.g. {s}", .{mix.name()}) else "Search your genres");
}

fn firstGenreMix(self: *App) ?*const liborca.DailyMix {
    for (self.home.mixes.items()) |*mix| if (mix.kind == .genre) return mix;
    return null;
}

fn syncPlaying(self: *App) void {
    const home = &self.home;
    const cover = home.playing_cover orelse return;
    const status = self.runtime.playerStatus(self.player) catch return;
    if (home.playing_shown and std.meta.eql(home.playing_track, status.track_id)) return;
    home.playing_shown = true;
    home.playing_track = status.track_id;
    const library = self.library orelse return;
    const track_id = status.track_id orelse {
        art.clear(self, cover);
        setText(home.playing_title, "Nothing playing");
        setText(home.playing_artist, "Starts from your recent listening");
        return;
    };
    const summary = (self.runtime.libraryTrackSummary(library, track_id) catch null) orelse return;
    defer summary.deinit(self.allocator);
    var title: [512]u8 = undefined;
    var artist: [512]u8 = undefined;
    setText(home.playing_title, strings.terminated(&title, summary.title));
    setText(home.playing_artist, strings.terminated(&artist, summary.artist));
    if (summary.release_id) |release_id|
        art.show(self, cover, art.Key.release(release_id, .thumb))
    else
        art.show(self, cover, art.Key.track(track_id, .thumb));
}

const weekday_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const weekday_long = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

fn weekday(local_day: i64) usize {
    return @intCast(@mod(local_day + 4, 7));
}

fn writeHours(writer: *std.Io.Writer, ms: u64, comptime spaced: bool) !void {
    const minutes = (ms + 30_000) / 60_000;
    const hours = minutes / 60;
    const rest = minutes % 60;
    const gap = if (spaced) " " else "";
    if (hours == 0) return writer.print("{d}{s}m", .{ rest, gap });
    if (spaced) return writer.print("{d} h {d:0>2} m", .{ hours, rest });
    try writer.print("{d}h {d}m", .{ hours, rest });
}

fn writeSpokenHours(writer: *std.Io.Writer, ms: u64) !void {
    const minutes = (ms + 30_000) / 60_000;
    const hours = minutes / 60;
    const rest = minutes % 60;
    if (hours != 0) try writer.print("{d} hour{s}", .{ hours, if (hours == 1) "" else "s" });
    if (hours != 0 and rest != 0) try writer.writeAll(" ");
    if (rest != 0 or hours == 0) try writer.print("{d} minute{s}", .{ rest, if (rest == 1) "" else "s" });
}

fn hoursText(buffer: []u8, ms: u64, comptime spaced: bool) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeHours(&writer, ms, spaced) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn buildWeekCard(self: *App) *gtk.Widget {
    const home = &self.home;
    const card = box(gtk.ORIENTATION_VERTICAL, 14, "home-card");
    gtk.gtk_widget_add_css_class(card, "home-week-card");
    gtk.gtk_widget_set_hexpand(card, gtk.true_);
    const heading = box(gtk.ORIENTATION_HORIZONTAL, 10, "home-card-heading");
    const title = label("This week", "home-card-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const range = label(null, "home-card-subtitle");
    home.week_range = gtk.cast(gtk.Label, range);
    append(heading, &.{ title, range });
    const hero = box(gtk.ORIENTATION_HORIZONTAL, 14, "home-week-hero");
    const time = label(null, "home-week-time");
    gtk.gtk_widget_set_valign(time, gtk.ALIGN_BASELINE_FILL);
    const counts = ellipsized(null, "home-week-counts");
    gtk.gtk_widget_set_valign(counts, gtk.ALIGN_BASELINE_FILL);
    home.week_hero = gtk.cast(gtk.Label, time);
    home.week_counts = gtk.cast(gtk.Label, counts);
    append(hero, &.{ time, counts });
    const chart = box(gtk.ORIENTATION_HORIZONTAL, 10, "home-chart");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, chart), gtk.true_);
    gtk.gtk_widget_set_focusable(chart, gtk.true_);
    gtk.gtk_widget_set_vexpand(chart, gtk.true_);
    gtk.gtk_widget_set_valign(chart, gtk.ALIGN_END);
    home.week_chart = chart;
    const footer = box(gtk.ORIENTATION_HORIZONTAL, 12, "home-week-footer");
    const top = ellipsized(null, "home-week-footer-text");
    gtk.gtk_widget_set_hexpand(top, gtk.true_);
    const change = label(null, "home-week-footer-text");
    home.week_top = gtk.cast(gtk.Label, top);
    home.week_change = gtk.cast(gtk.Label, change);
    append(footer, &.{ top, change });
    append(card, &.{ heading, hero, chart, footer });
    return card;
}

fn chartColumn(day_name: []const u8, value: u64, peak: u64, is_today: bool, is_peak: bool) *gtk.Widget {
    const column = box(gtk.ORIENTATION_VERTICAL, 6, "home-chart-day");
    if (is_today) gtk.gtk_widget_add_css_class(column, "today");
    var value_buffer: [32]u8 = undefined;
    const value_text = if ((is_today or is_peak) and value != 0) hoursText(&value_buffer, value, false) else "";
    const value_label = label(value_text.ptr, "home-chart-value");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value_label), 0.5);
    gtk.gtk_widget_set_vexpand(value_label, gtk.true_);
    gtk.gtk_widget_set_valign(value_label, gtk.ALIGN_END);
    const bar = box(gtk.ORIENTATION_VERTICAL, 0, "home-chart-bar");
    const height: c_int = if (peak == 0 or value == 0) 3 else @intCast(@max(4, (value * chart_bar_pixels + peak / 2) / peak));
    gtk.gtk_widget_set_size_request(bar, chart_bar_min_width, height);
    gtk.gtk_widget_set_valign(bar, gtk.ALIGN_END);
    const bar_holder = gtk.gtk_grid_new();
    gtk.gtk_grid_set_column_homogeneous(gtk.cast(gtk.Grid, bar_holder), gtk.true_);
    gtk.gtk_widget_set_hexpand(bar, gtk.true_);
    gtk.gtk_grid_attach(gtk.cast(gtk.Grid, bar_holder), bar, 1, 0, 2, 1);
    for ([_]c_int{ 0, 3 }) |side| {
        const margin = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_set_hexpand(margin, gtk.true_);
        gtk.gtk_grid_attach(gtk.cast(gtk.Grid, bar_holder), margin, side, 0, 1, 1);
    }
    var day_buffer: [16]u8 = undefined;
    const day_label = label(if (is_today) "Today" else strings.terminated(&day_buffer, day_name).ptr, "home-chart-label");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, day_label), 0.5);
    append(column, &.{ value_label, bar_holder, day_label });
    var tooltip: [64]u8 = undefined;
    var hours: [32]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(column, strings.format(&tooltip, "{s}: {s}", .{ day_name, hoursText(&hours, value, false) }).ptr);
    return column;
}

fn chartDescription(buffer: []u8, week: *const liborca.HomeListeningWeek, peak_index: usize) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    const today_index = week.day_listened_ms.len - 1;
    write: {
        writer.writeAll("Listening time per day this week.") catch break :write;
        const peak = week.day_listened_ms[peak_index];
        if (peak != 0 and peak_index != today_index) {
            writer.print(" Highest {s}, ", .{weekday_long[weekday(week.first_local_day + @as(i64, @intCast(peak_index)))]}) catch break :write;
            writeSpokenHours(&writer, peak) catch break :write;
            writer.writeAll(";") catch break :write;
        }
        writer.writeAll(" today ") catch break :write;
        writeSpokenHours(&writer, week.day_listened_ms[today_index]) catch break :write;
        writer.writeAll(" so far.") catch break :write;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn showWeek(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime) void {
    const home = &self.home;
    const week = self.runtime.libraryListeningWeek(library, time) catch return;
    const today_index = week.day_listened_ms.len - 1;
    var range: [32]u8 = undefined;
    setText(home.week_range, strings.format(&range, "{s} \u{2013} {s}", .{
        weekday_short[weekday(week.first_local_day)],
        weekday_short[weekday(week.first_local_day + @as(i64, @intCast(today_index)))],
    }));
    var hero: [32]u8 = undefined;
    setText(home.week_hero, hoursText(&hero, week.listened_ms, true));
    var counts: [128]u8 = undefined;
    setText(home.week_counts, strings.format(&counts, "{f} plays · {f} artists · {f} albums", .{
        strings.grouped(week.plays), strings.grouped(week.artists), strings.grouped(week.releases),
    }));
    var peak_index: usize = 0;
    for (week.day_listened_ms, 0..) |value, index| {
        if (value > week.day_listened_ms[peak_index]) peak_index = index;
    }
    const peak = week.day_listened_ms[peak_index];
    if (home.week_chart) |chart| {
        clearBox(chart);
        for (week.day_listened_ms, 0..) |value, index| {
            const day = week.first_local_day + @as(i64, @intCast(index));
            append(chart, &.{chartColumn(weekday_short[weekday(day)], value, peak, index == today_index, index == peak_index)});
        }
        var description: [256]u8 = undefined;
        setAccessibleLabel(chart, "This week\u{2019}s listening chart");
        setAccessibleDescription(chart, chartDescription(&description, &week, peak_index).ptr);
        gtk.gtk_widget_set_tooltip_text(chart, chartDescription(&description, &week, peak_index).ptr);
    }
    var top: [512]u8 = undefined;
    if (home.week_top) |top_label| {
        if (week.top_artist) |artist| {
            const escaped = gtk.g_markup_escape_text(artist.name.slice().ptr, @intCast(artist.name.slice().len));
            defer gtk.g_free(escaped);
            gtk.gtk_label_set_markup(top_label, strings.format(&top, "Most played: <span foreground=\"#D9DBDA\">{s}</span> · {d} plays", .{ std.mem.span(escaped), artist.plays }).ptr);
        } else gtk.gtk_label_set_text(top_label, "");
    }
    if (home.week_change) |change_label| {
        const current = week.listened_ms;
        const previous = week.previous_listened_ms;
        const difference = if (current >= previous) current - previous else previous - current;
        var amount: [32]u8 = undefined;
        var change: [160]u8 = undefined;
        gtk.gtk_label_set_markup(change_label, strings.format(&change, "vs last week <span foreground=\"#D9DBDA\">{s}{s}</span>", .{
            if (current >= previous) "+" else "\u{2212}",
            hoursText(&amount, difference, true),
        }).ptr);
    }
}

fn whenText(buffer: []u8, played_at: i64, time: liborca.HomeLocalTime) []const u8 {
    if (time.now_s - played_at < 15 * 60) return "Now";
    const today = @divFloor(time.now_s + time.utc_offset_s, day_s);
    const day = @divFloor(played_at + time.utc_offset_s, day_s);
    if (day == today) return "Today";
    if (day + 1 == today) return "Yesterday";
    if (today - day < 7) return weekday_long[weekday(day)];
    const moment = gtk.g_date_time_new_from_unix_local(played_at) orelse return "";
    defer gtk.g_date_time_unref(moment);
    const date = gtk.g_date_time_format(moment, "%B %-e") orelse return "";
    defer gtk.g_free(date);
    return strings.terminated(buffer, std.mem.span(date));
}

fn newReleaseTile(self: *App, release_id: i64, title_text: []const u8, detail_text: [:0]const u8, pixels: c_int) *gtk.Widget {
    const tile = box(gtk.ORIENTATION_VERTICAL, 0, "home-recent-tile");
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "home-recent-art");
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(frame, gtk.ALIGN_START);
    const sizer = box(gtk.ORIENTATION_VERTICAL, 0, null);
    gtk.gtk_widget_set_size_request(sizer, pixels, pixels);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), sizer);
    gtk.g_object_set_data(frame, "orca-art-sizer", sizer);
    const cover = playlists.fillingCover(self, 40);
    art.show(self, cover, art.Key.release(release_id, .medium));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), cover);
    gtk.g_object_set_data(tile, "orca-art", frame);
    var title_buffer: [300]u8 = undefined;
    const title = ellipsized(strings.terminated(&title_buffer, if (title_text.len != 0) title_text else "Untitled").ptr, "home-tile-title");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, title), 1);
    const detail = ellipsized(detail_text.ptr, "home-tile-detail");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, detail), 1);
    append(tile, &.{ frame, title, detail });
    return tile;
}

fn appendReleaseTile(flow: *gtk.FlowBox, tile: *gtk.Widget, index: usize, columns: c_uint, accessible: [:0]const u8) void {
    gtk.gtk_flow_box_append(flow, tile);
    const cell = gtk.gtk_widget_get_parent(tile) orelse return;
    gtk.gtk_widget_set_visible(cell, boolean(index < columns));
    setAccessibleLabel(cell, accessible.ptr);
}

fn showRecent(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime, recording: bool) void {
    const home = &self.home;
    const flow = home.recent_flow orelse return;
    gtk.gtk_flow_box_remove_all(flow);
    home.recent_count = 0;
    var releases: [recent_limit]liborca.HomePlayedRelease = undefined;
    const count = if (recording) self.runtime.libraryRecentReleases(library, time, &releases) catch 0 else 0;
    for (releases[0..count], 0..) |*release, index| {
        home.recent_ids[index] = release.release_id;
        var when_buffer: [64]u8 = undefined;
        var detail: [400]u8 = undefined;
        const tile = newReleaseTile(self, release.release_id, release.title.slice(), strings.format(&detail, "{s} · {s}", .{
            release.artist.slice(), whenText(&when_buffer, release.last_played_at, time),
        }), home.recent_layout.pixels);
        var accessible: [700]u8 = undefined;
        appendReleaseTile(flow, tile, index, home.recent_layout.columns, strings.format(&accessible, "{s} by {s}", .{ release.title.slice(), release.artist.slice() }));
    }
    home.recent_count = count;
    if (home.recent_section) |section| gtk.gtk_widget_set_visible(section, boolean(count != 0));
}

fn showUnplayed(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime) void {
    const home = &self.home;
    const flow = home.unplayed_flow orelse return;
    gtk.gtk_flow_box_remove_all(flow);
    home.unplayed_count = 0;
    var releases: [recent_limit]liborca.HomeRelease = undefined;
    const count = self.runtime.libraryUnplayedReleases(library, time, &releases) catch 0;
    for (releases[0..count], 0..) |*release, index| {
        home.unplayed_ids[index] = release.release_id;
        var detail: [400]u8 = undefined;
        var accessible: [700]u8 = undefined;
        const detail_text = if (release.year) |year|
            strings.format(&detail, "{s} · {d}", .{ release.artist.slice(), year })
        else
            strings.terminated(&detail, release.artist.slice());
        const tile = newReleaseTile(self, release.release_id, release.title.slice(), detail_text, home.recent_layout.pixels);
        const spoken = if (release.year) |year|
            strings.format(&accessible, "{s} by {s}, {d}", .{ release.title.slice(), release.artist.slice(), year })
        else
            strings.format(&accessible, "{s} by {s}", .{ release.title.slice(), release.artist.slice() });
        appendReleaseTile(flow, tile, index, home.recent_layout.columns, spoken);
    }
    home.unplayed_count = count;
    if (home.unplayed_section) |section| gtk.gtk_widget_set_visible(section, boolean(count != 0));
}

fn unplayedActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= self.home.unplayed_count) return;
    window.showAlbum(self, self.home.unplayed_ids[@intCast(index)]);
}

fn recentActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_flow_box_child_get_index(gtk.cast(gtk.FlowBoxChild, child));
    if (index < 0 or @as(usize, @intCast(index)) >= self.home.recent_count) return;
    window.showAlbum(self, self.home.recent_ids[@intCast(index)]);
}

fn listRow(self: *App, release_id: ?i64, line_text: [:0]const u8, reason: [:0]const u8) *gtk.Widget {
    const row = box(gtk.ORIENTATION_HORIZONTAL, 12, "home-list-row");
    const cover = art.newCover(self, art.iconPlaceholder(list_art_pixels), list_art_pixels);
    gtk.gtk_widget_add_css_class(cover, "home-list-cover");
    if (release_id) |id| art.show(self, cover, art.Key.release(id, .thumb));
    const text = box(gtk.ORIENTATION_VERTICAL, 2, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    const line = ellipsized(line_text.ptr, "home-list-title");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, line), 1);
    const why = ellipsized(reason.ptr, "home-list-reason");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, why), 1);
    append(text, &.{ line, why });
    append(row, &.{ cover, text });
    return row;
}

fn listSection(self: *App, kind: ListKind, title: [*:0]const u8, definition: [*:0]const u8) *gtk.Widget {
    const section = box(gtk.ORIENTATION_VERTICAL, 0, "home-list-section");
    gtk.gtk_widget_set_hexpand(section, gtk.true_);
    const heading = box(gtk.ORIENTATION_VERTICAL, 2, "home-list-heading");
    append(heading, &.{ sectionTitle(title), ellipsized(definition, "home-definition") });
    const list = newList("home-reason-list");
    setAccessibleLabel(list, title);
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(listActivated), self);
    gtk.g_object_set_data(list, "orca-home-list", @ptrFromInt(@as(usize, @backingInt(kind)) + 1));
    self.home.list_sections[@backingInt(kind)] = section;
    self.home.list_boxes[@backingInt(kind)] = gtk.cast(gtk.ListBox, list);
    append(section, &.{ heading, list });
    return section;
}

fn listActivated(list: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tag = @intFromPtr(gtk.g_object_get_data(list.?, "orca-home-list") orelse return);
    const kind: usize = tag - 1;
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0 or @as(usize, @intCast(index)) >= self.home.list_counts[kind]) return;
    const release_id = self.home.list_ids[kind][@intCast(index)];
    if (release_id != 0) window.showAlbum(self, release_id);
}

fn writeLastPlayed(writer: *std.Io.Writer, played_at: i64, time: liborca.HomeLocalTime) !void {
    const moment = gtk.g_date_time_new_from_unix_local(played_at) orelse return;
    defer gtk.g_date_time_unref(moment);
    const years = localYear(time.now_s, time) - localYear(played_at, time);
    const format = if (years <= 0) "%B" else if (years == 1) "last %B" else "%B %Y";
    const text = gtk.g_date_time_format(moment, format) orelse return;
    defer gtk.g_free(text);
    try writer.print(" · last played {s}", .{std.mem.span(text)});
}

fn localYear(unix_s: i64, time: liborca.HomeLocalTime) i64 {
    const day = @divFloor(unix_s + time.utc_offset_s, day_s);
    if (day < 0) return 0;
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day) };
    return epoch_day.calculateYearDay().year;
}

fn fillList(self: *App, kind: ListKind, count: usize) void {
    const home = &self.home;
    home.list_counts[@backingInt(kind)] = count;
    arrangeLists(home);
}

fn arrangeLists(home: *State) void {
    const stacked = if (home.list_row) |row|
        gtk.gtk_orientable_get_orientation(gtk.cast(gtk.Orientable, row)) == gtk.ORIENTATION_VERTICAL
    else
        false;
    var visible: usize = 0;
    for (home.list_sections, home.list_counts) |maybe, count| {
        const section = maybe orelse continue;
        gtk.gtk_widget_set_visible(section, boolean(count != 0));
        if (count != 0) visible += 1;
    }
    for (home.list_fillers, 0..) |maybe, index| {
        const filler = maybe orelse continue;
        gtk.gtk_widget_set_visible(filler, boolean(!stacked and visible != 0 and index + visible < home.list_sections.len));
    }
}

fn listsReoriented(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    arrangeLists(&state(data).home);
}

fn showLists(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime, with_history: bool) void {
    const home = &self.home;
    const clock: radio_reason.Clock = .{ .now_s = time.now_s, .utc_offset_s = time.utc_offset_s };
    for (home.list_boxes) |maybe| if (maybe) |list| gtk.gtk_list_box_remove_all(list);

    var released: [list_limit]liborca.HomePlayedRelease = undefined;
    const rediscovered = if (with_history) self.runtime.libraryRediscover(library, time, &released) catch 0 else 0;
    if (home.list_boxes[@backingInt(ListKind.rediscover)]) |list| for (released[0..rediscovered], 0..) |*release, index| {
        home.list_ids[@backingInt(ListKind.rediscover)][index] = release.release_id;
        var line: [600]u8 = undefined;
        var reason: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(reason[0 .. reason.len - 1]);
        writer.print("{f} plays", .{strings.grouped(release.plays)}) catch {};
        writeLastPlayed(&writer, release.last_played_at, time) catch {};
        reason[writer.end] = 0;
        gtk.gtk_list_box_append(list, listRow(self, release.release_id, strings.format(&line, "{s} · {s}", .{ release.title.slice(), release.artist.slice() }), reason[0..writer.end :0]));
    };
    fillList(self, .rediscover, rediscovered);

    var tracks: [list_limit]liborca.HomeTrack = undefined;
    const deep = if (with_history) self.runtime.libraryDeepCuts(library, time, &tracks) catch 0 else 0;
    if (home.list_boxes[@backingInt(ListKind.deep_cuts)]) |list| for (tracks[0..deep], 0..) |*track, index| {
        home.list_ids[@backingInt(ListKind.deep_cuts)][index] = track.release_id orelse 0;
        var line: [600]u8 = undefined;
        var reason: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(reason[0 .. reason.len - 1]);
        if (track.plays == 0)
            writer.writeAll("Never played") catch {}
        else
            radio_reason.writePart(&writer, .{ .kind = .rarely_played, .a = track.plays }, "", clock) catch {};
        reason[writer.end] = 0;
        gtk.gtk_list_box_append(list, listRow(self, track.release_id, strings.format(&line, "{s} · {s}", .{ track.title.slice(), track.artist.slice() }), reason[0..writer.end :0]));
    };
    fillList(self, .deep_cuts, deep);
    if (home.list_row) |row| gtk.gtk_widget_set_visible(row, boolean(rediscovered + deep != 0));
}

fn panel(title: [*:0]const u8) *gtk.Widget {
    const widget = box(gtk.ORIENTATION_VERTICAL, 10, "home-panel");
    gtk.gtk_widget_set_hexpand(widget, gtk.true_);
    append(widget, &.{overline(title)});
    return widget;
}

fn thinBar(fraction: f64, class: [*:0]const u8) *gtk.Widget {
    const bar = gtk.gtk_progress_bar_new();
    gtk.gtk_widget_add_css_class(bar, "home-bar");
    gtk.gtk_widget_add_css_class(bar, class);
    gtk.gtk_widget_set_valign(bar, gtk.ALIGN_CENTER);
    gtk.gtk_progress_bar_set_fraction(gtk.cast(gtk.ProgressBar, bar), fraction);
    return bar;
}

fn buildTopPanel(self: *App) *gtk.Widget {
    const widget = panel("Top artists · last 30 days");
    const list = newList("home-top-list");
    setAccessibleLabel(list, "Top artists in the last 30 days");
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(topActivated), self);
    self.home.top_list = gtk.cast(gtk.ListBox, list);
    self.home.top_panel = widget;
    append(widget, &.{list});
    return widget;
}

fn showTopArtists(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime) void {
    const home = &self.home;
    const list = home.top_list orelse return;
    gtk.gtk_list_box_remove_all(list);
    var artists: [top_artist_limit]liborca.HomeTopArtist = undefined;
    const count = self.runtime.libraryTopArtists(library, time, top_artist_days, &artists) catch 0;
    home.top_count = count;
    const most: f64 = if (count != 0) @floatFromInt(@max(artists[0].plays, 1)) else 1;
    for (artists[0..count], 0..) |*artist, index| {
        home.top_ids[index] = artist.artist_id;
        const row = box(gtk.ORIENTATION_HORIZONTAL, 10, "home-top-row");
        var rank_buffer: [8]u8 = undefined;
        const rank = label(strings.format(&rank_buffer, "{d}", .{index + 1}).ptr, "home-top-rank");
        gtk.gtk_widget_set_size_request(rank, 18, -1);
        var name_buffer: [300]u8 = undefined;
        const name = ellipsized(strings.terminated(&name_buffer, artist.name.slice()).ptr, "home-top-name");
        gtk.gtk_widget_set_size_request(name, top_name_width, -1);
        gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, name), 1);
        const bar = thinBar(@as(f64, @floatFromInt(artist.plays)) / most, "home-top-bar");
        gtk.gtk_widget_set_hexpand(bar, gtk.true_);
        var count_buffer: [16]u8 = undefined;
        const plays = label(strings.format(&count_buffer, "{f}", .{strings.grouped(artist.plays)}).ptr, "home-top-count");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, plays), 1);
        gtk.gtk_widget_set_size_request(plays, 34, -1);
        append(row, &.{ rank, name, bar, plays });
        gtk.gtk_list_box_append(list, row);
        if (gtk.gtk_widget_get_parent(row)) |list_row| {
            var accessible: [400]u8 = undefined;
            setAccessibleLabel(list_row, strings.format(&accessible, "{d}. {s}, {d} plays", .{ index + 1, artist.name.slice(), artist.plays }).ptr);
        }
    }
    if (home.top_panel) |widget| if (count == 0) gtk.gtk_widget_set_visible(widget, gtk.false_);
}

fn topActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0 or @as(usize, @intCast(index)) >= self.home.top_count) return;
    window.showArtist(self, self.home.top_ids[@intCast(index)]);
}

fn stat(value: *?*gtk.Label, caption: [*:0]const u8) *gtk.Widget {
    const column = box(gtk.ORIENTATION_VERTICAL, 0, "home-stat");
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    const number = label(null, "home-stat-value");
    gtk.gtk_widget_add_css_class(number, "numeric");
    value.* = gtk.cast(gtk.Label, number);
    append(column, &.{ number, label(caption, "home-stat-caption") });
    return column;
}

const format_names = [_][*:0]const u8{ "FLAC", "ALAC", "MP3", "Other" };

fn buildCollectionPanel(self: *App) *gtk.Widget {
    const home = &self.home;
    const widget = panel("Collection");
    const stats = box(gtk.ORIENTATION_HORIZONTAL, 12, "home-stats");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, stats), gtk.true_);
    append(stats, &.{
        stat(&home.collection_albums, "Albums"),
        stat(&home.collection_tracks, "Tracks"),
        stat(&home.collection_hours, "Playing time"),
    });
    const formats = box(gtk.ORIENTATION_VERTICAL, 8, "home-formats");
    append(formats, &.{label("Formats", "home-formats-heading")});
    for (format_names, 0..) |name, index| {
        const row = box(gtk.ORIENTATION_HORIZONTAL, 10, "home-format-row");
        const caption = label(name, "home-format-name");
        gtk.gtk_widget_set_size_request(caption, 52, -1);
        const bar = thinBar(0, "home-format-bar");
        gtk.gtk_widget_set_hexpand(bar, gtk.true_);
        const count = label(null, "home-format-count");
        gtk.gtk_widget_add_css_class(count, "numeric");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, count), 1);
        gtk.gtk_widget_set_size_request(count, 58, -1);
        home.format_rows[index] = row;
        home.format_bars[index] = bar;
        home.format_counts[index] = gtk.cast(gtk.Label, count);
        append(row, &.{ caption, bar, count });
        append(formats, &.{row});
    }
    append(widget, &.{ stats, formats });
    return widget;
}

fn showCollection(self: *App, library: liborca.LibraryHandle) void {
    const home = &self.home;
    const formats = self.runtime.libraryFormats(library) catch return;
    var buffer: [32]u8 = undefined;
    setText(home.collection_albums, strings.format(&buffer, "{f}", .{strings.grouped(formats.releases)}));
    setText(home.collection_tracks, strings.format(&buffer, "{f}", .{strings.grouped(formats.tracks)}));
    setText(home.collection_hours, strings.format(&buffer, "{f} h", .{strings.grouped((formats.duration_ms + 1_800_000) / 3_600_000)}));
    const counts = [_]u64{ formats.flac, formats.alac, formats.mp3, formats.other };
    const total: f64 = @floatFromInt(@max(formats.tracks, 1));
    for (counts, home.format_rows, home.format_bars, home.format_counts) |count, row, bar, count_label| {
        if (row) |widget| gtk.gtk_widget_set_visible(widget, boolean(count != 0));
        if (bar) |widget| gtk.gtk_progress_bar_set_fraction(gtk.cast(gtk.ProgressBar, widget), @as(f64, @floatFromInt(count)) / total);
        setText(count_label, strings.format(&buffer, "{f}", .{strings.grouped(count)}));
    }
}

fn buildDayPanel(self: *App) *gtk.Widget {
    const home = &self.home;
    const widget = panel("This week in music");
    const anniversaries = box(gtk.ORIENTATION_VERTICAL, 2, "home-anniversaries");
    home.anniversary_box = anniversaries;
    const release = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(release, "flat");
    gtk.gtk_widget_add_css_class(release, "home-day-release");
    _ = gtk.signalConnect(release, "clicked", gtk.callback(dayReleaseClicked), self);
    const content = box(gtk.ORIENTATION_HORIZONTAL, 14, null);
    const cover = art.newCover(self, art.iconPlaceholder(on_this_day_pixels), on_this_day_pixels);
    gtk.gtk_widget_add_css_class(cover, "home-day-cover");
    const text = box(gtk.ORIENTATION_VERTICAL, 1, null);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    const when = ellipsized(null, "home-day-when");
    const title = ellipsized(null, "home-day-title");
    const artist = ellipsized(null, "home-day-artist");
    for ([_]*gtk.Widget{ when, title, artist }) |part| gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, part), 1);
    append(text, &.{ when, title, artist });
    append(content, &.{ cover, text });
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, release), content);
    home.day_release = release;
    home.day_cover = cover;
    home.day_when = gtk.cast(gtk.Label, when);
    home.day_title = gtk.cast(gtk.Label, title);
    home.day_artist = gtk.cast(gtk.Label, artist);
    const year_ago = box(gtk.ORIENTATION_VERTICAL, 6, "home-year-ago");
    append(year_ago, &.{ label("A year ago you were playing", "home-year-ago-heading"), release });
    home.year_ago = year_ago;
    append(widget, &.{ anniversaries, year_ago });
    home.day_panel = widget;
    return widget;
}

fn dayReleaseClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    window.showAlbum(self, self.home.day_release_id orelse return);
}

fn anniversaryClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = @intFromPtr(gtk.g_object_get_data(button.?, "orca-anniversary") orelse return);
    if (position == 0 or position > self.home.anniversary_ids.len) return;
    window.showAlbum(self, self.home.anniversary_ids[position - 1]);
}

fn anniversaryButton(self: *App, index: usize, anniversary: *const liborca.HomeAnniversary, today: i64) *gtk.Widget {
    const day = weekday(today + anniversary.day_offset);
    const years: []const u8 = if (anniversary.years_ago == 1) "year" else "years";
    var line: [600]u8 = undefined;
    var reason: [64]u8 = undefined;
    const row = listRow(self, anniversary.release_id, strings.format(&line, "{s} · {s}", .{ anniversary.title.slice(), anniversary.artist.slice() }), strings.format(&reason, "{d} {s} ago · {s}", .{
        anniversary.years_ago, years, if (anniversary.day_offset == 0) "Today" else weekday_short[day],
    }));
    const button = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "home-anniversary");
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), row);
    var accessible: [700]u8 = undefined;
    setAccessibleLabel(button, strings.format(&accessible, "{s} by {s}, released {d} {s} ago {s}", .{
        anniversary.title.slice(), anniversary.artist.slice(), anniversary.years_ago, years, if (anniversary.day_offset == 0) "today" else weekday_long[day],
    }).ptr);
    gtk.g_object_set_data(button, "orca-anniversary", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(button, "clicked", gtk.callback(anniversaryClicked), self);
    return button;
}

fn showAnniversaries(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime) usize {
    const home = &self.home;
    const parent = home.anniversary_box orelse return 0;
    clearBox(parent);
    var anniversaries: [anniversary_limit]liborca.HomeAnniversary = undefined;
    const count = self.runtime.libraryReleaseAnniversaries(library, time, &anniversaries) catch 0;
    const today = @divFloor(time.now_s + time.utc_offset_s, day_s);
    for (anniversaries[0..count], 0..) |*anniversary, index| {
        home.anniversary_ids[index] = anniversary.release_id;
        append(parent, &.{anniversaryButton(self, index, anniversary, today)});
    }
    gtk.gtk_widget_set_visible(parent, boolean(count != 0));
    return count;
}

fn showOnThisDay(self: *App, library: liborca.LibraryHandle, time: liborca.HomeLocalTime, recording: bool) void {
    const home = &self.home;
    const anniversaries = showAnniversaries(self, library, time);
    const day = self.runtime.libraryOnThisDay(library, time) catch liborca.HomeOnThisDay{};
    const release = if (recording) day.top_release else null;
    if (home.day_panel) |widget| gtk.gtk_widget_set_visible(widget, boolean(anniversaries != 0 or release != null));
    if (home.year_ago) |widget| {
        gtk.gtk_widget_set_visible(widget, boolean(release != null));
        if (anniversaries != 0) gtk.gtk_widget_add_css_class(widget, "after-rows") else gtk.gtk_widget_remove_css_class(widget, "after-rows");
    }
    home.day_release_id = null;
    const played = release orelse return;
    const release_widget = home.day_release orelse return;
    home.day_release_id = played.release_id;
    if (home.day_cover) |cover| art.show(self, cover, art.Key.release(played.release_id, .thumb));
    var buffer: [64]u8 = undefined;
    var when: [128]u8 = undefined;
    const year_ago = gtk.g_date_time_new_from_unix_local(time.now_s) orelse return;
    defer gtk.g_date_time_unref(year_ago);
    const last_year = gtk.g_date_time_add_years(year_ago, -1) orelse return;
    defer gtk.g_date_time_unref(last_year);
    const date = gtk.g_date_time_format(last_year, "%B %-e, %Y") orelse return;
    defer gtk.g_free(date);
    const times: []const u8 = switch (played.plays) {
        1 => "once",
        2 => "twice",
        else => strings.format(buffer[0..], "{d} times", .{played.plays}),
    };
    setText(home.day_when, strings.format(&when, "{s} · you played it {s}", .{ std.mem.span(date), times }));
    var title: [300]u8 = undefined;
    var artist: [300]u8 = undefined;
    setText(home.day_title, strings.terminated(&title, played.title.slice()));
    setText(home.day_artist, strings.terminated(&artist, played.artist.slice()));
    var accessible: [700]u8 = undefined;
    setAccessibleLabel(release_widget, strings.format(&accessible, "A year ago you were playing {s} by {s}", .{ played.title.slice(), played.artist.slice() }).ptr);
}

fn contentWidth(self: *App, scroller: *gtk.Widget) f64 {
    const adjustment = gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
    return gtk.gtk_adjustment_get_page_size(adjustment) - @as(f64, if (self.window_narrow) 32 else 64);
}

fn layoutFor(tiling: Tiling, width: f64) Layout {
    const columns = tiling.columns(width);
    return .{ .columns = columns, .pixels = tiling.pixels(width, columns) };
}

fn measure(self: *App) bool {
    const home = &self.home;
    var changed = false;
    if (home.scroller) |scroller| {
        const width = contentWidth(self, scroller);
        if (width > 0) {
            const mixes = layoutFor(mix_row_tiling, width);
            const recent = layoutFor(recent_tiling, width);
            changed = changed or !std.meta.eql(mixes, home.mixes_layout) or !std.meta.eql(recent, home.recent_layout);
            home.mixes_layout = mixes;
            home.recent_layout = recent;
        }
    }
    if (home.grid_scroller) |scroller| {
        const width = contentWidth(self, scroller);
        if (width > 0) {
            const grid = layoutFor(grid_tiling, width);
            changed = changed or !std.meta.eql(grid, home.grid_layout);
            home.grid_layout = grid;
        }
    }
    return changed;
}

fn applyLayout(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const home = &self.home;
    home.layout_idle = 0;
    for ([_]?*gtk.FlowBox{ home.mixes_flow, home.recent_flow, home.unplayed_flow, home.grid_flow }, [_]Layout{ home.mixes_layout, home.recent_layout, home.recent_layout, home.grid_layout }) |maybe, layout| {
        const flow = maybe orelse continue;
        gtk.gtk_flow_box_set_max_children_per_line(flow, layout.columns);
        sizeTiles(flow, layout.pixels);
    }
    for ([_]?*gtk.FlowBox{ home.recent_flow, home.unplayed_flow }) |maybe| if (maybe) |flow| showFirstCells(flow, home.recent_layout.columns);
    return gtk.SOURCE_REMOVE;
}

fn scheduleLayout(self: *App) void {
    if (self.home.layout_idle == 0) self.home.layout_idle = gtk.g_idle_add(applyLayout, self);
}

fn resized(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (measure(self)) scheduleLayout(self);
}

pub fn setNarrow(self: *App) void {
    if (measure(self)) scheduleLayout(self);
}

fn watchWidth(self: *App, scroller: *gtk.Widget) void {
    const adjustment = gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
    _ = gtk.signalConnect(adjustment, "changed", gtk.callback(resized), self);
}

fn scrollerFor(child: *gtk.Widget) *gtk.Widget {
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), child);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    return scroller;
}

fn buildMixesSection(self: *App) *gtk.Widget {
    const home = &self.home;
    const section = box(gtk.ORIENTATION_VERTICAL, 14, "home-section");
    const heading = box(gtk.ORIENTATION_HORIZONTAL, 12, "home-section-heading");
    const title = sectionTitle("Daily Mixes");
    gtk.gtk_widget_set_valign(title, gtk.ALIGN_BASELINE_FILL);
    const updated = label(null, "home-updated");
    gtk.gtk_widget_set_valign(updated, gtk.ALIGN_BASELINE_FILL);
    gtk.gtk_widget_set_hexpand(updated, gtk.true_);
    home.mixes_updated = gtk.cast(gtk.Label, updated);
    const see_all = gtk.gtk_button_new_with_label("See all");
    gtk.gtk_widget_add_css_class(see_all, "flat");
    gtk.gtk_widget_add_css_class(see_all, "home-link");
    gtk.gtk_widget_set_valign(see_all, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(see_all, "Show every Daily Mix");
    _ = gtk.signalConnect(see_all, "clicked", gtk.callback(seeAllClicked), self);
    home.mixes_see_all = see_all;
    append(heading, &.{ title, updated, see_all });
    const note = label(null, "home-note");
    home.mixes_note = gtk.cast(gtk.Label, note);
    const flow = newFlow("home-mixes");
    setAccessibleLabel(gtk.cast(gtk.Widget, flow), "Daily Mixes");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(mixActivated), self);
    home.mixes_flow = flow;
    append(section, &.{ heading, note, gtk.cast(gtk.Widget, flow) });
    home.mixes_section = section;
    return section;
}

fn buildRecentSection(self: *App) *gtk.Widget {
    const home = &self.home;
    const section = box(gtk.ORIENTATION_VERTICAL, 14, "home-section");
    append(section, &.{sectionTitle("Jump back in")});
    const flow = newFlow("home-recent");
    setAccessibleLabel(gtk.cast(gtk.Widget, flow), "Jump back in");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(recentActivated), self);
    home.recent_flow = flow;
    append(section, &.{gtk.cast(gtk.Widget, flow)});
    home.recent_section = section;
    return section;
}

fn buildUnplayedSection(self: *App) *gtk.Widget {
    const home = &self.home;
    const section = box(gtk.ORIENTATION_VERTICAL, 14, "home-section");
    append(section, &.{sectionTitle("Albums you haven\u{2019}t played")});
    const flow = newFlow("home-unplayed");
    setAccessibleLabel(gtk.cast(gtk.Widget, flow), "Albums you haven\u{2019}t played");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(unplayedActivated), self);
    home.unplayed_flow = flow;
    append(section, &.{gtk.cast(gtk.Widget, flow)});
    gtk.gtk_widget_set_visible(section, gtk.false_);
    home.unplayed_section = section;
    return section;
}

fn buildHomePage(self: *App) *gtk.Widget {
    const home = &self.home;
    const content = box(gtk.ORIENTATION_VERTICAL, 40, "home-page");
    const header = box(gtk.ORIENTATION_VERTICAL, 4, "home-header");
    const title = label("Home", "display-page");
    const subline = wrapped(null, "home-subline");
    home.subline = gtk.cast(gtk.Label, subline);
    append(header, &.{ title, subline });

    const note = box(gtk.ORIENTATION_HORIZONTAL, 10, "home-recording-note");
    const note_icon = gtk.gtk_image_new_from_icon_name("orca-info-symbolic");
    gtk.gtk_widget_set_valign(note_icon, gtk.ALIGN_START);
    const note_text = linkLabel("Listening history is off, so Home shows only your library. Turn it on in <a href=\"" ++ card_link_uri ++ "\">Settings \u{2192} Listening</a>.", "home-note-text", self);
    gtk.gtk_widget_set_hexpand(note_text, gtk.true_);
    append(note, &.{ note_icon, note_text });
    gtk.gtk_widget_set_visible(note, gtk.false_);
    home.recording_note = note;

    const cards = box(gtk.ORIENTATION_HORIZONTAL, 24, "home-cards");
    const week = buildWeekCard(self);
    home.week_card = week;
    append(cards, &.{ buildRadioCard(self), week });

    const lists = box(gtk.ORIENTATION_HORIZONTAL, 28, "home-lists");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, lists), gtk.true_);
    append(lists, &.{
        listSection(self, .rediscover, "Rediscover", "Albums you played a lot, then stopped"),
        listSection(self, .deep_cuts, "Deep cuts", "Rarely played tracks by artists you play most"),
    });
    for (&home.list_fillers) |*filler| {
        const slot = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_set_hexpand(slot, gtk.true_);
        gtk.gtk_widget_set_visible(slot, gtk.false_);
        gtk.gtk_box_append(gtk.cast(gtk.Box, lists), slot);
        filler.* = slot;
    }
    _ = gtk.signalConnect(lists, "notify::orientation", gtk.callback(listsReoriented), self);
    home.list_row = lists;

    const library_section = box(gtk.ORIENTATION_VERTICAL, 14, "home-section");
    const panels = box(gtk.ORIENTATION_HORIZONTAL, 24, "home-panels");
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, panels), gtk.true_);
    append(panels, &.{ buildTopPanel(self), buildCollectionPanel(self), buildDayPanel(self) });
    append(library_section, &.{ sectionTitle("Your library"), panels });

    append(content, &.{ header, note, buildMixesSection(self), cards, buildRecentSection(self), buildUnplayedSection(self), lists, library_section });
    const scroller = scrollerFor(content);
    home.scroller = scroller;
    watchWidth(self, scroller);
    const bin = page_ui.breakpointBin(scroller);
    page_ui.stackBelow(bin, "max-width: 980px", &.{ cards, lists, panels }, &.{});
    return bin;
}

fn buildGridPage(self: *App) *adw.NavigationPage {
    const home = &self.home;
    const content = box(gtk.ORIENTATION_VERTICAL, 18, "home-page");
    gtk.gtk_widget_add_css_class(content, "home-grid-page");
    const header = box(gtk.ORIENTATION_VERTICAL, 4, "home-header");
    append(header, &.{ label("Daily Mixes", "display-page"), wrapped("Made on this computer from your library and listening history. New mixes every day.", "home-subline") });
    const note = label("Mixes appear after a few days of listening.", "home-note");
    home.grid_note = note;
    const flow = newFlow("home-grid");
    setAccessibleLabel(gtk.cast(gtk.Widget, flow), "Daily Mixes");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(mixActivated), self);
    home.grid_flow = flow;
    append(content, &.{ header, note, gtk.cast(gtk.Widget, flow) });
    const scroller = scrollerFor(content);
    home.grid_scroller = scroller;
    watchWidth(self, scroller);
    const page = adw.adw_navigation_page_new(scroller, "Daily Mixes");
    adw.adw_navigation_page_set_tag(page, mixes_tag);
    return page;
}

pub fn build(self: *App) *gtk.Widget {
    const home = &self.home;
    const navigation = adw.adw_navigation_view_new();
    home.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(buildHomePage(self), "Home");
    adw.adw_navigation_page_set_tag(root, navigation_tag);
    adw.adw_navigation_view_add(home.navigation.?, root);
    adw.adw_navigation_view_add(home.navigation.?, buildGridPage(self));
    const mix_page = buildMixPage(self);
    home.mix_page = mix_page;
    adw.adw_navigation_view_add(home.navigation.?, mix_page);
    return navigation;
}

fn mixPageShown(self: *App) bool {
    const navigation = self.home.navigation orelse return false;
    const visible = adw.adw_navigation_view_get_visible_page_tag(navigation) orelse return false;
    return std.mem.eql(u8, std.mem.span(visible), mix_tag);
}

pub fn openMix(self: *App, mix_id: i64) void {
    if (!self.home.loaded) readMixes(self);
    if (findMix(self, mix_id) == null) return;
    self.home.open_mix = mix_id;
    loadMix(self);
    window.showPage(self, .home);
    const navigation = self.home.navigation orelse return;
    const page = self.home.mix_page orelse return;
    window.markPushed(page, .{ .daily_mix = mix_id });
    if (!mixPageShown(self)) {
        window.popToTag(self, navigation, navigation_tag);
        adw.adw_navigation_view_push_by_tag(navigation, mix_tag);
    }
    page_ui.refresh(self);
}

fn tableHeader() *gtk.Widget {
    const row = box(gtk.ORIENTATION_HORIZONTAL, 12, "daily-mix-head");
    const number = label("#", "daily-mix-head-cell");
    gtk.gtk_widget_set_size_request(number, 24, -1);
    const middle = box(gtk.ORIENTATION_HORIZONTAL, 16, null);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, middle), gtk.true_);
    gtk.gtk_widget_set_hexpand(middle, gtk.true_);
    const headings = [_]*gtk.Widget{ ellipsized("Title", "daily-mix-head-cell"), ellipsized("Album", "daily-mix-head-cell"), ellipsized("Why it\u{2019}s here", "daily-mix-head-cell") };
    for (headings) |heading| gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, heading), 1);
    append(middle, &headings);
    const time = label("Time", "daily-mix-head-cell");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, time), 1);
    gtk.gtk_widget_set_size_request(time, 56, -1);
    const action = box(gtk.ORIENTATION_HORIZONTAL, 0, null);
    gtk.gtk_widget_set_size_request(action, 30, -1);
    append(row, &.{ number, middle, time, action });
    return row;
}

fn makeupDraw(area: ?*gtk.DrawingArea, cr: *gtk.Cairo, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const mix = findMix(self, self.home.open_mix orelse return) orelse return;
    const widget = gtk.cast(gtk.Widget, area.?);
    const counts = [_]u32{ mix.makeup.favorite, mix.makeup.rarely_played, mix.makeup.never_played };
    const colors = [_][:0]const u8{ "orca_text_artist", "orca_text_3", "orca_makeup_never" };
    var total: u32 = 0;
    for (counts) |count| total += count;
    if (total == 0) return;
    const gap: f64 = 2;
    var segments: f64 = 0;
    for (counts) |count| {
        if (count != 0) segments += 1;
    }
    const full: f64 = @floatFromInt(width);
    const available = full - gap * (segments - 1);
    const bar_height: f64 = @floatFromInt(height);
    var x: f64 = 0;
    for (counts, colors) |count, color_name| {
        if (count == 0) continue;
        const segment = available * @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total));
        var color: gtk.GdkRGBA = undefined;
        if (gtk.gtk_style_context_lookup_color(gtk.gtk_widget_get_style_context(widget), color_name.ptr, &color) == 0) gtk.gtk_widget_get_color(widget, &color);
        gtk.cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha);
        gtk.cairo_rectangle(cr, x, 0, segment, bar_height);
        gtk.cairo_fill(cr);
        x += segment + gap;
    }
}

fn legendItem(value: *?*gtk.Label, class: [*:0]const u8) *gtk.Widget {
    const item = box(gtk.ORIENTATION_HORIZONTAL, 6, "daily-mix-legend-item");
    const swatch = box(gtk.ORIENTATION_VERTICAL, 0, "daily-mix-swatch");
    gtk.gtk_widget_add_css_class(swatch, class);
    gtk.gtk_widget_set_valign(swatch, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(swatch, 8, 8);
    const text = label(null, "daily-mix-legend-text");
    value.* = gtk.cast(gtk.Label, text);
    append(item, &.{ swatch, text });
    return item;
}

fn asideSection(title: [*:0]const u8, body: *gtk.Widget) *gtk.Widget {
    const section = box(gtk.ORIENTATION_VERTICAL, 6, "daily-mix-aside-section");
    append(section, &.{ overline(title), body });
    return section;
}

fn buildAside(self: *App) *gtk.Widget {
    const home = &self.home;
    const aside = box(gtk.ORIENTATION_VERTICAL, 16, "daily-mix-aside");
    gtk.gtk_widget_set_size_request(aside, page_ui.side_panel_width, -1);
    gtk.gtk_widget_set_hexpand(aside, gtk.false_);
    gtk.gtk_widget_set_valign(aside, gtk.ALIGN_START);
    const title = label("How this mix was made", "daily-mix-aside-title");
    const built = asideText(null);
    home.mix_built = gtk.cast(gtk.Label, built);
    const filled = box(gtk.ORIENTATION_VERTICAL, 6, "daily-mix-bullets");
    home.mix_filled = filled;
    const left = asideText(null);
    home.mix_left = gtk.cast(gtk.Label, left);
    const note = box(gtk.ORIENTATION_HORIZONTAL, 10, "daily-mix-note");
    const icon = gtk.gtk_image_new_from_icon_name("orca-info-symbolic");
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_START);
    const note_text = linkLabel("Made on this computer. Nothing about your listening leaves it. <a href=\"" ++ card_link_uri ++ "\">Mix settings</a>", "daily-mix-note-text", self);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, note_text), 1);
    gtk.gtk_widget_set_hexpand(note_text, gtk.true_);
    append(note, &.{ icon, note_text });
    append(aside, &.{
        title,
        asideSection("Built around", built),
        asideSection("Filled out with", filled),
        asideSection("Left out", left),
        note,
    });
    return aside;
}

fn buildMixPage(self: *App) *adw.NavigationPage {
    const home = &self.home;
    const hero = box(gtk.ORIENTATION_HORIZONTAL, 32, "daily-mix-hero");
    const mosaic = playlists.newMosaic(self, mix_hero_pixels);
    gtk.gtk_widget_add_css_class(mosaic, "daily-mix-mosaic");
    home.mix_mosaic = mosaic;
    const facts = box(gtk.ORIENTATION_VERTICAL, 8, null);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const eyebrow = label("DAILY MIX", "album-kind");
    const title = wrapped(null, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
    const artists = wrapped(null, "daily-mix-artists");
    const meta = wrapped(null, "album-meta");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    home.mix_title = gtk.cast(gtk.Label, title);
    home.mix_artists = gtk.cast(gtk.Label, artists);
    home.mix_meta = gtk.cast(gtk.Label, meta);
    const actions = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, actions), 10);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, actions), 8);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "artist-actions");
    gtk.gtk_widget_add_css_class(actions, "playlist-actions");
    const play_button = albums.pill("Play", "orca-play-symbolic", true);
    const shuffle_button = albums.pill("Shuffle", "orca-shuffle-symbolic", false);
    const save_button = albums.pill("Save as Playlist", "orca-plus-symbolic", false);
    const more = playlists.roundButton("orca-more-symbolic", "Mix Menu", false);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(shuffle_button, "clicked", gtk.callback(shuffleClicked), self);
    _ = gtk.signalConnect(save_button, "clicked", gtk.callback(saveClicked), self);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    for ([_]*gtk.Widget{ play_button, shuffle_button, save_button, more }) |button| adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, actions), button);
    append(facts, &.{ eyebrow, title, artists, meta, actions });
    append(hero, &.{ mosaic, facts });

    const makeup = box(gtk.ORIENTATION_VERTICAL, 8, "daily-mix-makeup");
    const bar = gtk.gtk_drawing_area_new();
    gtk.gtk_widget_add_css_class(bar, "daily-mix-makeup-bar");
    gtk.gtk_drawing_area_set_content_height(gtk.cast(gtk.DrawingArea, bar), 6);
    gtk.gtk_drawing_area_set_draw_func(gtk.cast(gtk.DrawingArea, bar), makeupDraw, self, null);
    gtk.gtk_widget_set_hexpand(bar, gtk.true_);
    home.mix_makeup = bar;
    const legend = box(gtk.ORIENTATION_HORIZONTAL, 18, "daily-mix-legend");
    append(legend, &.{
        legendItem(&home.mix_legend[0], "favorite"),
        legendItem(&home.mix_legend[1], "rarely"),
        legendItem(&home.mix_legend[2], "never"),
    });
    append(makeup, &.{ bar, legend });

    const rows = newList("daily-mix-rows");
    setAccessibleLabel(rows, "Tracks in this mix");
    _ = gtk.signalConnect(rows, "row-activated", gtk.callback(rowActivated), self);
    home.mix_rows = gtk.cast(gtk.ListBox, rows);
    const table = box(gtk.ORIENTATION_VERTICAL, 0, "daily-mix-table");
    append(table, &.{ tableHeader(), rows });

    const main = box(gtk.ORIENTATION_VERTICAL, 26, "daily-mix-main");
    gtk.gtk_widget_set_hexpand(main, gtk.true_);
    append(main, &.{ hero, makeup, table });
    const row = box(gtk.ORIENTATION_HORIZONTAL, 32, "daily-mix-page");
    append(row, &.{ main, buildAside(self) });

    const layers = gtk.gtk_overlay_new();
    const backdrop = art.newBackdrop(self, .header);
    gtk.gtk_widget_add_css_class(backdrop, "playlist-backdrop");
    home.mix_backdrop = backdrop;
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), backdrop);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), row);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), row, gtk.true_);
    const scroller = scrollerFor(layers);
    const bin = page_ui.breakpointBin(scroller);
    page_ui.stackBelow(bin, "max-width: 959px", &.{row}, &.{});
    page_ui.stackBelow(bin, "max-width: 700px", &.{ row, hero }, &.{});
    page_ui.extendUnderBar(self, bin, scroller);
    const page = adw.adw_navigation_page_new(bin, "Daily Mix");
    adw.adw_navigation_page_set_tag(page, mix_tag);
    return page;
}

fn mixRow(self: *App, index: usize, entry: *const liborca.DailyMixEntry, clock: radio_reason.Clock) *gtk.Widget {
    const library = self.library.?;
    const summary = (self.runtime.libraryTrackSummary(library, entry.track_id) catch null);
    defer if (summary) |found| found.deinit(self.allocator);
    const title_text: []const u8 = if (summary) |found| found.title else "Unknown track";
    const artist_text: []const u8 = if (summary) |found| found.artist else "";
    const album_text: []const u8 = if (summary) |found| found.album else "";
    const row = box(gtk.ORIENTATION_HORIZONTAL, 12, "daily-mix-row");
    var number_buffer: [8]u8 = undefined;
    const number = label(strings.format(&number_buffer, "{d}", .{index + 1}).ptr, "daily-mix-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    const playing_glyph = gtk.gtk_image_new_from_icon_name("orca-play-symbolic");
    gtk.gtk_widget_set_halign(playing_glyph, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(playing_glyph, "album-track-playing");
    const number_column = gtk.gtk_stack_new();
    gtk.gtk_widget_set_size_request(number_column, 24, -1);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, number_column), number, "number");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, number_column), playing_glyph, "playing");
    const middle = box(gtk.ORIENTATION_HORIZONTAL, 16, null);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, middle), gtk.true_);
    gtk.gtk_widget_set_hexpand(middle, gtk.true_);
    const names = box(gtk.ORIENTATION_VERTICAL, 1, null);
    gtk.gtk_widget_set_valign(names, gtk.ALIGN_CENTER);
    var title_buffer: [300]u8 = undefined;
    var artist_buffer: [300]u8 = undefined;
    var album_buffer: [300]u8 = undefined;
    const title = ellipsized(strings.terminated(&title_buffer, title_text).ptr, "daily-mix-title");
    const artist = ellipsized(strings.terminated(&artist_buffer, artist_text).ptr, "daily-mix-artist");
    append(names, &.{ title, artist });
    const album = ellipsized(strings.terminated(&album_buffer, album_text).ptr, "daily-mix-album");
    var reason_buffer: [queue.reason_capacity]u8 = undefined;
    const reason = wrapped(queue.formatReason(self, &reason_buffer, entry.reason, clock).ptr, "daily-mix-reason");
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, reason), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, reason), gtk.ELLIPSIZE_END);
    for ([_]*gtk.Widget{ title, artist, album, reason }) |text| gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, text), 1);
    gtk.gtk_widget_set_valign(album, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(reason, gtk.ALIGN_CENTER);
    append(middle, &.{ names, album, reason });
    var time_buffer: [16]u8 = undefined;
    const duration: u64 = @intCast(@max(entry.duration_ms orelse 0, 0));
    const time = label(if (entry.duration_ms != null) strings.formatMs(&time_buffer, duration).ptr else "", "daily-mix-time");
    gtk.gtk_widget_add_css_class(time, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, time), 1);
    gtk.gtk_widget_set_size_request(time, 56, -1);
    const remove = gtk.gtk_button_new_from_icon_name("orca-circle-minus-symbolic");
    gtk.gtk_widget_add_css_class(remove, "flat");
    gtk.gtk_widget_add_css_class(remove, "daily-mix-not-for-me");
    gtk.gtk_widget_set_valign(remove, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(remove, "Not for me");
    var accessible: [400]u8 = undefined;
    setAccessibleLabel(remove, strings.format(&accessible, "Not for me: remove {s} from mixes", .{title_text}).ptr);
    gtk.g_object_set_data(remove, "orca-entry", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(remove, "clicked", gtk.callback(notForMeClicked), self);
    append(row, &.{ number_column, middle, time, remove });
    const list_row = gtk.gtk_list_box_row_new();
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, list_row), row);
    gtk.g_object_set_data(list_row, "orca-number", number_column);
    gtk.g_object_set_data(list_row, "orca-title", title);
    gtk.g_object_set_data(list_row, "orca-artist", artist);
    gtk.g_object_set_data(list_row, "orca-reason", reason);
    labelMixRow(list_row, index, false);
    return list_row;
}

fn metaText(buffer: []u8, mix: *const liborca.DailyMix, mixes: *const liborca.DailyMixes) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    write: {
        writer.print("{d} {s}", .{ mix.entry_count, if (mix.entry_count == 1) "track" else "tracks" }) catch break :write;
        var duration: [32]u8 = undefined;
        if (mix.entry_count != 0) writer.print(" · {s}", .{strings.totalDuration(&duration, @intCast(mix.duration_ms))}) catch break :write;
        var updated: [128]u8 = undefined;
        const when = updatedText(&updated, mixes, queue.localClock(), false);
        if (when.len != 0) writer.print(" · {s} · new mix tomorrow", .{when}) catch break :write;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

const Signal = struct { kind: liborca.ReasonKind, text: [*:0]const u8 };

const signal_lines = [_]Signal{
    .{ .kind = .related_artist, .text = "Related artists from MusicBrainz" },
    .{ .kind = .similar_sound, .text = "Tracks with a similar tempo and energy (audio analysis)" },
    .{ .kind = .often_after, .text = "Tracks you often play in the same session" },
    .{ .kind = .shared_genre, .text = "Tracks that share its genre tags" },
    .{ .kind = .same_artist, .text = "More from the same artists" },
    .{ .kind = .loved, .text = "Tracks you loved" },
    .{ .kind = .played, .text = "Tracks you play often" },
    .{ .kind = .rarely_played, .text = "Tracks you rarely play" },
    .{ .kind = .never_played, .text = "Tracks you haven\u{2019}t played yet" },
    .{ .kind = .added, .text = "Tracks you added recently" },
};

fn showSignals(self: *App, mix: *const liborca.DailyMix) void {
    const filled = self.home.mix_filled orelse return;
    clearBox(filled);
    for (signal_lines) |line| {
        if (mix.signals & (@as(u32, 1) << @intCast(@backingInt(line.kind))) == 0) continue;
        const item = box(gtk.ORIENTATION_HORIZONTAL, 8, "daily-mix-bullet");
        const dot = label("•", "daily-mix-bullet-dot");
        gtk.gtk_widget_set_valign(dot, gtk.ALIGN_START);
        const text = asideText(line.text);
        gtk.gtk_widget_set_hexpand(text, gtk.true_);
        append(item, &.{ dot, text });
        append(filled, &.{item});
    }
}

const highlight_open = "<span foreground=\"#F2F2F0\">";
const highlight_close = "</span>";
const decade_choice = ". Orca picks the decade you played most in the last 30 days, or the one with the most music in your library.";

fn builtAroundMarkup(buffer: []u8, mix: *const liborca.DailyMix) [:0]const u8 {
    switch (mix.kind) {
        .rarely_played => return strings.terminated(buffer, "Tracks you\u{2019}ve played before but not in the last year."),
        .new_to_you => return strings.terminated(buffer, "Albums you haven\u{2019}t played yet by artists you listened to in the last 90 days."),
        .deep_cuts => return strings.terminated(buffer, "Tracks you\u{2019}ve played once or never by the 10 artists you played most in the last 90 days."),
        .upbeat => return strings.terminated(buffer, "The most energetic third of your analyzed music."),
        .wind_down => return strings.terminated(buffer, "The calmest third of your analyzed music."),
        .decade => {
            if (mix.decade) |decade| return strings.format(buffer, "Tracks released in the " ++ highlight_open ++ "{d}s" ++ highlight_close ++ decade_choice, .{decade});
            const escaped = gtk.g_markup_escape_text(mix.name().ptr, @intCast(mix.name().len));
            defer gtk.g_free(escaped);
            return strings.format(buffer, "Tracks released in the " ++ highlight_open ++ "{s}" ++ highlight_close ++ decade_choice, .{std.mem.span(escaped)});
        },
        .genre => {
            const escaped = gtk.g_markup_escape_text(mix.name().ptr, @intCast(mix.name().len));
            defer gtk.g_free(escaped);
            return strings.format(buffer, "The artists you played most in the last 30 days that share the " ++ highlight_open ++ "{s}" ++ highlight_close ++ " tag.", .{std.mem.span(escaped)});
        },
    }
}

fn leftOutText(buffer: []u8, mix: *const liborca.DailyMix, avoid_days: u8) [:0]const u8 {
    var parts: [6][128]u8 = undefined;
    var texts: [6][]const u8 = undefined;
    var count: usize = 0;
    const left = mix.left_out;
    if (avoid_days != 0 and mix.kind != .rarely_played) {
        texts[count] = std.fmt.bufPrint(&parts[count], "anything played in the last {d} {s}", .{ avoid_days, if (avoid_days == 1) "day" else "days" }) catch "";
        count += 1;
    }
    texts[count] = "live recordings";
    count += 1;
    if (left.hated != 0) {
        texts[count] = std.fmt.bufPrint(&parts[count], "{d} {s} you disliked", .{ left.hated, if (left.hated == 1) "track" else "tracks" }) catch "";
        count += 1;
    }
    if (left.other_mix != 0) {
        texts[count] = std.fmt.bufPrint(&parts[count], "{d} {s} already in an earlier mix", .{ left.other_mix, if (left.other_mix == 1) "track" else "tracks" }) catch "";
        count += 1;
    }
    if (left.not_for_me != 0) {
        texts[count] = std.fmt.bufPrint(&parts[count], "{d} {s} you marked \u{201C}Not for me\u{201D}", .{ left.not_for_me, if (left.not_for_me == 1) "track" else "tracks" }) catch "";
        count += 1;
    }
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (texts[0..count], 0..) |text, index| {
        if (index != 0) writer.writeAll(if (index + 1 == count) ", and " else ", ") catch break;
        if (index == 0 and text.len != 0) {
            writer.writeByte(std.ascii.toUpper(text[0])) catch break;
            writer.writeAll(text[1..]) catch break;
        } else writer.writeAll(text) catch break;
    }
    writer.writeAll(".") catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn loadMix(self: *App) void {
    const home = &self.home;
    const mix_id = home.open_mix orelse return;
    const library = self.library orelse return;
    const mix = findMix(self, mix_id) orelse return;
    home.entry_count = self.runtime.libraryDailyMixEntries(library, mix_id, &home.entries) catch 0;
    for (home.entries[0..home.entry_count], 0..) |entry, index| home.entry_ids[index] = entry.track_id;

    var name: [400]u8 = undefined;
    const title = strings.format(&name, "Mix {d} · {s}", .{ mixNumber(mix), mix.name() });
    setText(home.mix_title, title);
    if (home.mix_page) |page| adw.adw_navigation_page_set_title(page, strings.format(&name, "Mix {d}", .{mixNumber(mix)}).ptr);
    var artists: [1200]u8 = undefined;
    var writer = std.Io.Writer.fixed(artists[0 .. artists.len - 1]);
    writeArtists(&writer, mix) catch {};
    artists[writer.end] = 0;
    setText(home.mix_artists, artists[0..writer.end :0]);
    if (home.mix_artists) |widget| gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, widget), boolean(writer.end != 0));
    var meta: [256]u8 = undefined;
    setText(home.mix_meta, metaText(&meta, mix, &home.mixes));

    if (home.mix_mosaic) |mosaic| {
        playlists.showMosaic(self, mosaic, mix.coverReleases());
        if (home.mix_backdrop) |backdrop| playlists.showMosaicBackdrop(self, backdrop, mosaic, mix.coverReleases().len);
    }
    const counts = [_]u32{ mix.makeup.favorite, mix.makeup.rarely_played, mix.makeup.never_played };
    const nouns = [_][2][]const u8{ .{ "favorite", "favorites" }, .{ "rarely played", "rarely played" }, .{ "never played", "never played" } };
    var legend: [64]u8 = undefined;
    var description: [160]u8 = undefined;
    for (counts, nouns, home.mix_legend) |count, noun, maybe| {
        const widget = maybe orelse continue;
        gtk.gtk_label_set_text(widget, strings.format(&legend, "{d} {s}", .{ count, if (count == 1) noun[0] else noun[1] }).ptr);
        if (gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, widget))) |item| gtk.gtk_widget_set_visible(item, boolean(count != 0));
    }
    if (home.mix_makeup) |bar| {
        setAccessibleLabel(bar, strings.format(&description, "Mix makeup: {d} favorites, {d} rarely played, {d} never played", .{ counts[0], counts[1], counts[2] }).ptr);
        gtk.gtk_widget_queue_draw(bar);
    }

    var built: [512]u8 = undefined;
    if (home.mix_built) |widget| gtk.gtk_label_set_markup(widget, builtAroundMarkup(&built, mix).ptr);
    showSignals(self, mix);
    const settings = self.runtime.libraryDiscoverySettings(library) catch liborca.DiscoverySettings{};
    var left: [512]u8 = undefined;
    setText(home.mix_left, leftOutText(&left, mix, @backingInt(settings.avoid_days)));

    const rows = home.mix_rows orelse return;
    gtk.gtk_list_box_remove_all(rows);
    const clock = queue.localClock();
    for (home.entries[0..home.entry_count], 0..) |*entry, index| gtk.gtk_list_box_append(rows, mixRow(self, index, entry, clock));
    markMixRows(self, self.shown_track_id);
}

fn rowActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0 or @as(usize, @intCast(index)) >= self.home.entry_count) return;
    self.runtime.playerSetShuffle(self.player, false) catch {};
    transport.playIds(self, self.home.entry_ids[0..self.home.entry_count], @intCast(index));
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    play(state(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    play(state(data), true);
}

fn play(self: *App, shuffle: bool) void {
    if (self.home.entry_count == 0) return;
    self.runtime.playerSetShuffle(self.player, shuffle) catch {};
    transport.playIds(self, self.home.entry_ids[0..self.home.entry_count], 0);
}

fn moreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const home = &self.home;
    if (home.entry_count == 0) return;
    self.context.reset(.tracks);
    for (home.entries[0..home.entry_count]) |entry| {
        self.context.addTrack(self.allocator, entry.track_id, entry.recording_id, .none) catch return;
    }
    albums.popupBelow(self, gtk.cast(gtk.Widget, button.?));
}

const SavedMix = struct {
    self: *App,
    library: liborca.LibraryHandle,
    playlist_id: i64,

    fn free(data: ?*anyopaque) callconv(.c) void {
        const saved: *SavedMix = @ptrCast(@alignCast(data.?));
        saved.self.allocator.destroy(saved);
    }

    fn clicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const saved: *SavedMix = @ptrCast(@alignCast(data.?));
        const self = saved.self;
        const library = self.library orelse return;
        if (!library.eql(saved.library)) return;
        playlists.open(self, saved.playlist_id);
    }
};

fn saveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const mix_id = self.home.open_mix orelse return;
    const mix = findMix(self, mix_id) orelse return;
    var name_buffer: [400]u8 = undefined;
    const name = strings.format(&name_buffer, "Mix {d} · {s}", .{ mixNumber(mix), mix.name() });
    const playlist_id = self.runtime.librarySaveDailyMix(library, mix_id, name) catch |err| return self.toast(switch (err) {
        error.PlaylistNameTaken => "A playlist with that name already exists",
        else => "Could not save the mix as a playlist",
    });
    playlists.refresh(self);
    const overlay = self.toasts orelse return;
    const saved = self.allocator.create(SavedMix) catch return self.toast("Saved as a playlist");
    saved.* = .{ .self = self, .library = library, .playlist_id = playlist_id };
    var text: [480]u8 = undefined;
    const item = adw.adw_toast_new(strings.format(&text, "Saved \u{201C}{s}\u{201D} as a playlist", .{name}).ptr);
    adw.adw_toast_set_timeout(item, 8);
    adw.adw_toast_set_button_label(item, "Open");
    gtk.g_object_set_data_full(item, "orca-saved-mix", saved, SavedMix.free);
    _ = gtk.signalConnect(item, "button-clicked", gtk.callback(SavedMix.clicked), saved);
    adw.adw_toast_overlay_add_toast(overlay, item);
}

const Removal = struct {
    self: *App,
    library: liborca.LibraryHandle,
    track_id: i64,

    fn free(data: ?*anyopaque) callconv(.c) void {
        const removal: *Removal = @ptrCast(@alignCast(data.?));
        removal.self.allocator.destroy(removal);
    }

    fn undo(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const removal: *Removal = @ptrCast(@alignCast(data.?));
        const self = removal.self;
        const library = self.library orelse return;
        if (!library.eql(removal.library)) return;
        self.runtime.libraryClearNotForMe(library, removal.track_id) catch return self.toast("Could not put the track back");
        feedbackChanged(self);
    }
};

fn feedbackChanged(self: *App) void {
    readMixes(self);
    showMixes(self);
    showGrid(self);
    loadMix(self);
}

fn notForMeClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const position = @intFromPtr(gtk.g_object_get_data(button.?, "orca-entry") orelse return);
    if (position == 0 or position > self.home.entry_count) return;
    const track_id = self.home.entries[position - 1].track_id;
    self.runtime.libraryNotForMe(library, track_id, queue.localClock().now_s) catch return self.toast("Could not remove the track");
    feedbackChanged(self);
    if (self.home.mix_rows) |rows| {
        const next = @min(position - 1, self.home.entry_count -| 1);
        if (self.home.entry_count != 0) if (gtk.gtk_list_box_get_row_at_index(rows, @intCast(next))) |row| {
            _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, row));
        };
    }
    const overlay = self.toasts orelse return;
    const removal = self.allocator.create(Removal) catch return self.toast("Removed from your mixes");
    removal.* = .{ .self = self, .library = library, .track_id = track_id };
    const item = adw.adw_toast_new("Removed from your mixes");
    adw.adw_toast_set_timeout(item, 8);
    adw.adw_toast_set_button_label(item, "Undo");
    gtk.g_object_set_data_full(item, "orca-not-for-me", removal, Removal.free);
    _ = gtk.signalConnect(item, "button-clicked", gtk.callback(Removal.undo), removal);
    adw.adw_toast_overlay_add_toast(overlay, item);
}
