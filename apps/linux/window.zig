//! The main window: a sidebar of pages beside the page itself, the player bar
//! along the bottom, and toasts over both.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const details = @import("details.zig");
const browse = @import("browse.zig");
const queue = @import("queue.zig");
const albums = @import("albums.zig");
const nowplaying = @import("nowplaying.zig");
const artists = @import("artists.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const ratings = @import("ratings.zig");
const health = @import("health.zig");
const matches = @import("matches.zig");
const playlists = @import("playlists.zig");
const loved = @import("loved.zig");
const genres = @import("genres.zig");
const folders = @import("folders.zig");
const page_ui = @import("page.zig");
const track_table = @import("track_table.zig");
const track_filters = @import("track_filters.zig");
const preferences = @import("preferences.zig");
const palette = @import("palette.zig");
const lyrics = @import("lyrics.zig");

const App = app.App;
const Column = track_model.Column;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn scrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.page_exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) -
        (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page) self.loadNextPage();
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    track_table.markPlaying(&.{ &self.tracks, &self.loved.tracks, &self.playlists.tracks }, track_id);
}

const SortChoice = struct {
    label: [*:0]const u8,
    sort: liborca.TrackSort,
    direction: liborca.SortDirection,
};

const sort_choices = [_]SortChoice{
    .{ .label = "Default", .sort = .id, .direction = .ascending },
    .{ .label = "Title", .sort = .title, .direction = .ascending },
    .{ .label = "Artist", .sort = .artist, .direction = .ascending },
    .{ .label = "Album", .sort = .album, .direction = .ascending },
    .{ .label = "Track Number", .sort = .track_number, .direction = .ascending },
    .{ .label = "Date Added", .sort = .date_added, .direction = .descending },
    .{ .label = "Last Played", .sort = .last_played, .direction = .descending },
    .{ .label = "Play Count", .sort = .play_count, .direction = .descending },
    .{ .label = "Rating", .sort = .rating, .direction = .descending },
    .{ .label = "Loved", .sort = .loved, .direction = .ascending },
    .{ .label = "Year", .sort = .year, .direction = .descending },
    .{ .label = "Duration", .sort = .duration, .direction = .ascending },
};

fn sortChoiceIndex(sort: liborca.TrackSort) c_uint {
    for (sort_choices, 0..) |choice, index| {
        if (choice.sort == sort) return @intCast(index);
    }
    return 0;
}

/// Numbers the rows by disc and track only where the order is the album's,
/// and highlights the sorted column's title.
fn showSortedColumn(self: *App) void {
    self.tracks.positions = self.browse.sort != .track_number and self.browse.sort != .album;
    track_table.markSorted(&self.tracks, if (self.browse.sort == .id) null else self.browse.sort);
}

pub fn showSort(self: *App) void {
    // Sorting the view or choosing an entry is indistinguishable from a user's
    // click to GTK, and their signals would arrive back as one.
    const previous = self.suppress_browse_signals;
    self.suppress_browse_signals = true;
    defer self.suppress_browse_signals = previous;
    if (self.sort_dropdown) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, sortChoiceIndex(self.browse.sort));
    showSortedColumn(self);
    const view = self.tracks.view orelse return;
    var chosen: ?*gtk.ColumnViewColumn = null;
    for (Column.all) |column| {
        if (column.sortKey()) |key| {
            if (key == self.browse.sort) chosen = self.tracks.header(column);
        }
    }
    gtk.gtk_column_view_sort_by_column(
        view,
        chosen,
        if (self.browse.direction == .descending) gtk.SORT_DESCENDING else gtk.SORT_ASCENDING,
    );
}

fn sortChosen(dropdown: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_browse_signals) return;
    const index = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, dropdown));
    if (index >= sort_choices.len) return;
    self.browse.sort = sort_choices[index].sort;
    self.browse.direction = sort_choices[index].direction;
    showSort(self);
    self.reload();
}

/// A header click, turned into a new engine query.
///
/// The whole result is re-ordered and the listing restarts at its first page,
/// because reordering the rows already loaded would sort only one page.
fn sortChanged(sorter: ?*anyopaque, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_browse_signals) return;
    const view = gtk.cast(gtk.Widget, self.tracks.view orelse return);
    if (gtk.gtk_widget_get_root(view) == null) return;
    const column_sorter = gtk.cast(gtk.ColumnViewSorter, sorter);
    const primary = gtk.gtk_column_view_sorter_get_primary_sort_column(column_sorter);
    self.browse.sort = .id;
    self.browse.direction = .ascending;
    if (primary) |chosen| {
        for (Column.all) |column| {
            if (self.tracks.header(column) == chosen) {
                if (column.sortKey()) |key| self.browse.sort = key;
            }
        }
        self.browse.direction =
            if (gtk.gtk_column_view_sorter_get_primary_sort_order(column_sorter) ==
            gtk.SORT_DESCENDING) .descending else .ascending;
    }
    if (self.sort_dropdown) |dropdown| {
        self.suppress_browse_signals = true;
        defer self.suppress_browse_signals = false;
        gtk.gtk_drop_down_set_selected(dropdown, sortChoiceIndex(self.browse.sort));
    }
    showSortedColumn(self);
    self.reload();
}

fn filterTracks(self: *App, text: []const u8) void {
    if (std.mem.eql(u8, text, self.query.value)) return;
    self.query.set(self.allocator, text);
    // A text match and a browse scope are alternatives to liborca, so a search
    // takes the listing over rather than narrowing what a pane already chose.
    // The Artist pane's filter is untouched: it says which Artists are listed,
    // not which tracks, so it survives a search that clears the selection.
    if (self.query.value.len != 0) browse.clearScope(self);
    self.reload();
}

pub fn filterTarget(self: *App) ?Page {
    return switch (self.current_page) {
        .albums, .artists, .tracks, .playlists => |page| if (pushedPage(self, page) == null) page else null,
        else => null,
    };
}

fn applyFilter(self: *App, page: Page, text: []const u8) void {
    switch (page) {
        .albums => albums.setFilter(self, text),
        .artists => artists.setFilter(self, text),
        .tracks => filterTracks(self, text),
        .playlists => playlists.setFilter(self, text),
        else => {},
    }
}

pub fn searchChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry)));
    const target = filterTarget(self);
    if (self.filtered_page) |page| {
        if (page != target) applyFilter(self, page, "");
    }
    self.filtered_page = null;
    const page = target orelse return;
    applyFilter(self, page, text);
    if (text.len != 0) self.filtered_page = page;
}

pub fn clearSearch(self: *App) void {
    palette.dismiss(self);
    if (self.filtered_page) |page| applyFilter(self, page, "");
    self.filtered_page = null;
    const entry = self.top_bar.entry orelse return;
    if (gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry))[0] == 0) return;
    self.palette.suppress = true;
    defer self.palette.suppress = false;
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), "");
}

pub fn searchActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (filterTarget(self) != .tracks or self.palette.popover != null) return;
    var ids = track_table.playableIds(&self.tracks, self.allocator);
    defer ids.deinit(self.allocator);
    if (ids.items.len != 0) transport.playIds(self, ids.items, 0);
}

fn addFolderClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.chooseFolder(state(data));
}

/// Returns true only when it actually consumed the key. Reached in the bubble
/// phase, so the focused widget has already declined it, which keeps Ctrl+arrows
/// moving by word in the search entry.
fn windowKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    const held = modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT);
    if (held == gtk.MODIFIER_CONTROL and keyval == gtk.KEY_Right) {
        transport.next(self);
        return gtk.true_;
    }
    if (held == gtk.MODIFIER_CONTROL and keyval == gtk.KEY_Left) {
        transport.previous(self);
        return gtk.true_;
    }
    if (held != 0 or !plainKeysApply(self)) return gtk.false_;
    if (keyval == gtk.KEY_l or keyval == gtk.KEY_L) {
        feedback.toggleLoveOfPlaying(self);
        return gtk.true_;
    }
    if (keyval >= gtk.KEY_1 and keyval <= gtk.KEY_5) {
        const target = feedback.playingTarget(self) orelse return gtk.false_;
        ratings.change(self, &.{target}, ratings.menuRating(keyval - gtk.KEY_1 + 1));
        return gtk.true_;
    }
    return gtk.false_;
}

fn plainKeysApply(self: *App) bool {
    const window = self.window orelse return false;
    if (adw.adw_application_window_get_visible_dialog(gtk.cast(adw.ApplicationWindow, window)) != null) return false;
    const focus = gtk.gtk_window_get_focus(window) orelse return true;
    if (gtk.g_type_check_instance_is_a(focus, gtk.gtk_editable_get_type()) != 0) return false;
    return gtk.gtk_widget_get_ancestor(focus, gtk.gtk_popover_get_type()) == null;
}

/// Runs in the capture phase so that focused buttons, rows and tiles cannot
/// consume Space before it toggles playback.
fn windowSpaceKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    const held = modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT);
    if (keyval != gtk.KEY_space or held != 0) return gtk.false_;
    if (!plainKeysApply(self)) return gtk.false_;
    transport.toggle(self);
    return gtk.true_;
}

/// Runs in the capture phase so that the navigation views' own Alt+Left pop
/// cannot step around the window's history.
fn windowHistoryKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    const held = modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT);
    if (held != gtk.MODIFIER_ALT) return gtk.false_;
    switch (keyval) {
        gtk.KEY_Left => back(self),
        gtk.KEY_Right => forward(self),
        else => return gtk.false_,
    }
    return gtk.true_;
}

const mouse_back_button: c_uint = 8;
const mouse_forward_button: c_uint = 9;

pub const Page = enum(c_uint) {
    albums,
    artists,
    tracks,
    genres,
    folders,
    loved,
    health,
    matches,
    now_playing,
    queue,
    playlists,
    settings,

    pub fn name(self: Page) [*:0]const u8 {
        return switch (self) {
            .albums => "albums",
            .artists => "artists",
            .tracks => "tracks",
            .genres => genres.navigation_tag,
            .folders => "folders",
            .loved => loved.navigation_tag,
            .health => "health",
            .matches => "matches",
            .now_playing => "now-playing",
            .queue => "queue",
            .playlists => "playlists",
            .settings => "settings",
        };
    }

    pub fn title(self: Page) [*:0]const u8 {
        return switch (self) {
            .albums => "Albums",
            .artists => "Artists",
            .tracks => "Tracks",
            .genres => "Genres",
            .folders => "Folders",
            .loved => "Loved",
            .health => "Health",
            .matches => "Matches",
            .now_playing => "Now Playing",
            .queue => "Queue",
            .playlists => "Playlists",
            .settings => "Settings",
        };
    }

    pub fn windowTitle(self: Page) [*:0]const u8 {
        return if (self == .health) "Library Health" else self.title();
    }
};

pub fn showPage(self: *App, page: Page) void {
    switchTo(self, page);
}

const history_limit = 32;

pub const Pushed = union(enum) {
    album: i64,
    artist: i64,
    playlist: i64,
};

fn pushedKey(comptime kind: std.meta.Tag(Pushed)) [*:0]const u8 {
    return "orca-pushed-" ++ @tagName(kind);
}

pub fn markPushed(page: *adw.NavigationPage, pushed: Pushed) void {
    switch (pushed) {
        inline else => |id, kind| {
            const value = std.math.cast(usize, id) orelse return;
            gtk.g_object_set_data(page, pushedKey(kind), @ptrFromInt(value));
        },
    }
}

fn pushedOf(self: *App, page: *adw.NavigationPage) ?Pushed {
    inline for (.{ .album, .artist }) |kind| {
        if (gtk.g_object_get_data(page, pushedKey(kind))) |value|
            return @unionInit(Pushed, @tagName(kind), @intCast(@intFromPtr(value)));
    }
    if (adw.adw_navigation_page_get_tag(page)) |tag| {
        if (std.mem.eql(u8, std.mem.span(tag), playlists.page_tag))
            return .{ .playlist = self.playlists.open_id orelse return null };
    }
    return null;
}

const Visit = struct {
    page: Page,
    pushed: ?Pushed,

    fn eql(self: Visit, other: Visit) bool {
        return self.page == other.page and std.meta.eql(self.pushed, other.pushed);
    }
};

pub const History = struct {
    visits: [history_limit]Visit = undefined,
    len: usize = 0,
    index: usize = 0,
    pending: c_uint = 0,
    navigating: bool = false,

    pub fn deinit(self: *History) void {
        if (self.pending != 0) _ = gtk.g_source_remove(self.pending);
        self.pending = 0;
        self.len = 0;
        self.index = 0;
    }

    fn remove(self: *History, at: usize) void {
        std.mem.copyForwards(Visit, self.visits[at .. self.len - 1], self.visits[at + 1 .. self.len]);
        self.len -= 1;
        if (self.index > at) self.index -= 1;
    }

    fn append(self: *History, visit: Visit) void {
        if (self.len != 0) self.len = self.index + 1;
        if (self.len == history_limit) self.remove(0);
        self.visits[self.len] = visit;
        self.index = self.len;
        self.len += 1;
    }

    fn insertAfterCurrent(self: *History, visit: Visit) void {
        if (self.len == history_limit) self.remove(if (self.index == 0) self.len - 1 else 0);
        const at = self.index + 1;
        std.mem.copyBackwards(Visit, self.visits[at + 1 .. self.len + 1], self.visits[at..self.len]);
        self.visits[at] = visit;
        self.len += 1;
    }
};

pub fn releaseMoved(self: *App, old_id: i64, new_id: i64) void {
    const history = &self.history;
    for (history.visits[0..history.len]) |*visit| {
        const pushed = visit.pushed orelse continue;
        if (std.meta.eql(pushed, Pushed{ .album = old_id })) visit.pushed = .{ .album = new_id };
    }
    var at: usize = 1;
    while (at < history.len) {
        if (history.visits[at].eql(history.visits[at - 1])) history.remove(at - 1) else at += 1;
    }
}

pub fn pageNavigation(self: *App, page: Page) ?*adw.NavigationView {
    return switch (page) {
        .albums => self.albums_navigation,
        .artists => self.artists_navigation,
        .genres => self.genres.navigation,
        .loved => self.loved.navigation,
        .playlists => self.playlists.navigation,
        else => null,
    };
}

pub fn pushedPage(self: *App, page: Page) ?*adw.NavigationPage {
    const navigation = pageNavigation(self, page) orelse return null;
    const visible = adw.adw_navigation_view_get_visible_page(navigation) orelse return null;
    if (adw.adw_navigation_view_get_visible_page_tag(navigation)) |tag| {
        if (std.mem.eql(u8, std.mem.span(tag), std.mem.span(page.name()))) return null;
    }
    return visible;
}

pub fn visibleContent(self: *App) ?*gtk.Widget {
    if (pageNavigation(self, self.current_page)) |navigation| {
        const visible = adw.adw_navigation_view_get_visible_page(navigation) orelse return null;
        return gtk.cast(gtk.Widget, visible);
    }
    const pages = self.pages orelse return null;
    return gtk.gtk_stack_get_child_by_name(pages, self.current_page.name());
}

fn sectionSource(self: *App, page: Page) details.Source {
    return switch (page) {
        .tracks => .{ .selection = self.tracks.selection orelse return .playing },
        .loved => .{ .selection = self.loved.tracks.selection orelse return .playing },
        .genres => .{ .ids = self.genres.track_ids[0..] },
        else => .playing,
    };
}

fn pushedSource(self: *App, page: *adw.NavigationPage) ?details.Source {
    return switch (pushedOf(self, page) orelse return null) {
        .album => albums.inspectorSource(self, page),
        .artist => artists.inspectorSource(self, page),
        .playlist => |id| .{ .playlist = .{
            .selection = self.playlists.tracks.selection orelse return null,
            .playlist_id = id,
        } },
    };
}

/// Points the inspector at the Tracks of the page showing.
pub fn syncInspector(self: *App) void {
    const pushed = if (pushedPage(self, self.current_page)) |page| pushedSource(self, page) else null;
    details.setSource(self, pushed orelse sectionSource(self, self.current_page));
}

pub fn shows(self: *App, pushed: Pushed) bool {
    return std.meta.eql(currentVisit(self).pushed, pushed);
}

fn currentVisit(self: *App) Visit {
    const pushed = pushedPage(self, self.current_page);
    return .{ .page = self.current_page, .pushed = if (pushed) |page| pushedOf(self, page) else null };
}

fn record(self: *App) void {
    const history = &self.history;
    if (history.pending != 0) _ = gtk.g_source_remove(history.pending);
    history.pending = 0;
    const visit = currentVisit(self);
    if (history.len != 0 and history.visits[history.index].eql(visit)) return;
    history.append(visit);
}

fn recordLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.history.pending = 0;
    record(self);
    page_ui.refresh(self);
    return gtk.SOURCE_REMOVE;
}

/// Waits for the end of the change, so opening an album from another page is
/// one step and not the album section's root followed by the album.
fn navigated(self: *App) void {
    page_ui.refresh(self);
    if (self.history.pending == 0) self.history.pending = gtk.g_idle_add(recordLater, self);
}

pub fn canGoBack(self: *App) bool {
    return pushedPage(self, self.current_page) != null or self.history.index != 0;
}

pub fn canGoForward(self: *App) bool {
    return self.history.index + 1 < self.history.len;
}

fn findInStack(self: *App, navigation: *adw.NavigationView, pushed: Pushed) ?*adw.NavigationPage {
    var at = adw.adw_navigation_view_get_visible_page(navigation);
    while (at) |shown| : (at = adw.adw_navigation_view_get_previous_page(navigation, shown)) {
        const shown_pushed = pushedOf(self, shown) orelse continue;
        if (std.meta.eql(shown_pushed, pushed)) return shown;
    }
    return null;
}

fn open(self: *App, navigation: *adw.NavigationView, pushed: Pushed) void {
    switch (pushed) {
        .album => |release_id| albums.openAlbum(self, navigation, release_id),
        .artist => |artist_id| artists.openArtist(self, navigation, artist_id),
        .playlist => |playlist_id| playlists.open(self, playlist_id),
    }
}

fn revisit(self: *App, visit: Visit) bool {
    if (visit.pushed) |pushed| switch (pushed) {
        .playlist => |playlist_id| if (!playlists.exists(self, playlist_id)) return false,
        else => {},
    };
    switchTo(self, visit.page);
    const navigation = pageNavigation(self, visit.page) orelse return true;
    const pushed = visit.pushed orelse {
        popToTag(self, navigation, visit.page.name());
        return true;
    };
    if (findInStack(self, navigation, pushed)) |page| {
        popToPage(self, navigation, page);
        return true;
    }
    popToTag(self, navigation, visit.page.name());
    open(self, navigation, pushed);
    return currentVisit(self).eql(visit);
}

fn popUnrecorded(self: *App) void {
    const navigation = pageNavigation(self, self.current_page) orelse return;
    if (pushedPage(self, self.current_page) == null) return;
    const history = &self.history;
    const popped = history.visits[history.index];
    pop(self, navigation);
    history.visits[history.index] = currentVisit(self);
    history.insertAfterCurrent(popped);
}

fn keepPopped(self: *App, popped: Visit) void {
    const history = &self.history;
    if (history.pending != 0) _ = gtk.g_source_remove(history.pending);
    history.pending = 0;
    const current = currentVisit(self);
    if (history.index > 0 and history.visits[history.index - 1].eql(current)) {
        history.index -= 1;
    } else if (history.len != 0 and history.visits[history.index].eql(popped)) {
        history.visits[history.index] = current;
        history.insertAfterCurrent(popped);
    } else record(self);
}

fn beginNavigating(self: *App) bool {
    const was = self.history.navigating;
    self.history.navigating = true;
    return was;
}

fn pop(self: *App, navigation: *adw.NavigationView) void {
    const was = beginNavigating(self);
    defer self.history.navigating = was;
    _ = adw.adw_navigation_view_pop(navigation);
}

pub fn popToTag(self: *App, navigation: *adw.NavigationView, tag: [*:0]const u8) void {
    const was = beginNavigating(self);
    defer self.history.navigating = was;
    _ = adw.adw_navigation_view_pop_to_tag(navigation, tag);
}

pub fn popToPage(self: *App, navigation: *adw.NavigationView, page: *adw.NavigationPage) void {
    const was = beginNavigating(self);
    defer self.history.navigating = was;
    _ = adw.adw_navigation_view_pop_to_page(navigation, page);
}

const Direction = enum { back, forward };

fn step(self: *App, direction: Direction) void {
    const history = &self.history;
    var skipped = false;
    while (switch (direction) {
        .back => history.index != 0,
        .forward => history.index + 1 < history.len,
    }) {
        const at = switch (direction) {
            .back => history.index - 1,
            .forward => history.index + 1,
        };
        if (revisit(self, history.visits[at])) {
            history.index = at;
            return;
        }
        history.remove(at);
        skipped = true;
    }
    if (skipped) _ = revisit(self, history.visits[history.index]);
}

pub fn back(self: *App) void {
    record(self);
    if (self.history.index == 0) popUnrecorded(self) else step(self, .back);
    record(self);
    page_ui.refresh(self);
}

pub fn forward(self: *App) void {
    record(self);
    step(self, .forward);
    record(self);
    page_ui.refresh(self);
}

pub fn popSection(self: *App) void {
    if (pushedPage(self, self.current_page) == null) return;
    _ = adw.adw_navigation_view_pop(pageNavigation(self, self.current_page).?);
}

fn backPressed(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_gesture_set_state(gtk.cast(gtk.Gesture, gesture), gtk.EVENT_SEQUENCE_CLAIMED);
    back(state(data));
}

fn forwardPressed(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_gesture_set_state(gtk.cast(gtk.Gesture, gesture), gtk.EVENT_SEQUENCE_CLAIMED);
    forward(state(data));
}

fn addMouseButton(window: *gtk.Widget, button: c_uint, pressed: gtk.GCallback, self: *App) void {
    const press = gtk.gtk_gesture_click_new();
    gtk.gtk_gesture_single_set_button(gtk.cast(gtk.GestureSingle, press), button);
    gtk.gtk_event_controller_set_propagation_phase(press, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(press, "pressed", pressed, self);
    gtk.gtk_widget_add_controller(window, press);
}

fn sectionChanged(navigation: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const showing = pageNavigation(self, self.current_page) orelse return;
    if (@as(?*anyopaque, showing) != navigation) return;
    clearSearch(self);
    settleFocus(self);
    syncInspector(self);
    navigated(self);
}

fn sectionPopped(navigation: ?*anyopaque, page: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.history.navigating) return;
    const showing = pageNavigation(self, self.current_page) orelse return;
    if (@as(?*anyopaque, showing) != navigation) return;
    const popped: *adw.NavigationPage = @ptrCast(page orelse return);
    keepPopped(self, .{ .page = self.current_page, .pushed = pushedOf(self, popped) });
    page_ui.refresh(self);
}

fn watchSections(self: *App) void {
    for ([_]Page{ .albums, .artists, .genres, .loved, .playlists }) |page| {
        const navigation = pageNavigation(self, page) orelse continue;
        _ = gtk.signalConnect(navigation, "notify::visible-page", gtk.callback(sectionChanged), self);
        _ = gtk.signalConnect(navigation, "popped", gtk.callback(sectionPopped), self);
    }
}

fn mainList(self: *App) ?*gtk.Widget {
    if (pushedPage(self, self.current_page) != null) return null;
    return switch (self.current_page) {
        .albums => if (self.albums_body) |body| gtk.cast(gtk.Widget, body) else null,
        .artists => if (self.artists_body) |body| gtk.cast(gtk.Widget, body) else null,
        .tracks => if (self.tracks_body) |body| gtk.cast(gtk.Widget, body) else null,
        else => null,
    };
}

fn focusPage(self: *App, content: *gtk.Widget) void {
    if (mainList(self)) |list| {
        if (gtk.gtk_widget_child_focus(list, gtk.DIR_TAB_FORWARD) != 0) return;
    }
    _ = gtk.gtk_widget_child_focus(content, gtk.DIR_TAB_FORWARD);
}

fn settleFocus(self: *App) void {
    const root = self.window orelse return;
    const content = visibleContent(self) orelse return;
    if (gtk.gtk_window_get_focus(root)) |focus| {
        if (focus == content or gtk.gtk_widget_is_ancestor(focus, content) != 0) return;
        const pages = gtk.cast(gtk.Widget, self.pages orelse return);
        const in_pages = gtk.gtk_widget_is_ancestor(focus, pages) != 0;
        const search = self.top_bar.search orelse return;
        const in_search = gtk.gtk_widget_is_ancestor(focus, gtk.cast(gtk.Widget, search)) != 0;
        if (!in_pages and !in_search) return;
    }
    focusPage(self, content);
}

pub const LibraryCount = enum { albums, artists, tracks };

const NavItem = struct { page: Page, icon: [*:0]const u8 };
const NavGroup = struct { title: [*:0]const u8, items: []const NavItem };

const nav_groups = [_]NavGroup{
    .{ .title = "Library", .items = &.{
        .{ .page = .albums, .icon = "orca-albums-symbolic" },
        .{ .page = .artists, .icon = "orca-artists-symbolic" },
        .{ .page = .tracks, .icon = "orca-tracks-symbolic" },
        .{ .page = .genres, .icon = "orca-genres-symbolic" },
        .{ .page = .folders, .icon = "orca-folders-symbolic" },
        .{ .page = .loved, .icon = "orca-loved-symbolic" },
    } },
    .{ .title = "Collection", .items = &.{
        .{ .page = .playlists, .icon = "orca-playlists-symbolic" },
    } },
    .{ .title = "Playback", .items = &.{
        .{ .page = .now_playing, .icon = "orca-now-playing-symbolic" },
        .{ .page = .queue, .icon = "orca-queue-symbolic" },
    } },
    .{ .title = "Library Tools", .items = &.{
        .{ .page = .health, .icon = "orca-health-symbolic" },
        .{ .page = .matches, .icon = "orca-matches-symbolic" },
    } },
    .{ .title = "Settings", .items = &.{
        .{ .page = .settings, .icon = "orca-settings-symbolic" },
    } },
};

pub fn syncSidebarSelection(self: *App) void {
    for (std.enums.values(Page)) |page| {
        const item = self.nav_items.get(page) orelse continue;
        if (page == self.current_page)
            gtk.gtk_widget_add_css_class(item, "selected")
        else
            gtk.gtk_widget_remove_css_class(item, "selected");
    }
}

pub fn focusSidebar(self: *App) void {
    const item = self.nav_items.get(self.current_page) orelse self.nav_items.get(.albums) orelse return;
    _ = gtk.gtk_widget_grab_focus(item);
}

pub fn refreshCounts(self: *App) void {
    const stats: ?liborca.LibraryStats = if (self.appearance.sidebar_counts)
        if (self.library) |library| self.runtime.libraryStats(library) catch null else null
    else
        null;
    for (std.enums.values(LibraryCount)) |kind| {
        const label = self.library_counts.get(kind) orelse continue;
        const value = stats orelse {
            gtk.gtk_label_set_text(label, "");
            continue;
        };
        var buffer: [32]u8 = undefined;
        const total = switch (kind) {
            .albums => value.releases,
            .artists => value.artists,
            .tracks => value.tracks,
        };
        const text: [:0]const u8 = strings.printZ(&buffer, "{f}", .{strings.grouped(total)}) catch "";
        gtk.gtk_label_set_text(label, text.ptr);
    }
}

fn switchTo(self: *App, page: Page) void {
    if (page != self.current_page) clearSearch(self);
    if (self.current_page == .settings and page != .settings) preferences.leave(self);
    self.current_page = page;
    if (self.pages) |pages| gtk.gtk_stack_set_visible_child_name(pages, page.name());
    if (self.content_page) |content| adw.adw_navigation_page_set_title(content, page.title());
    syncSidebarSelection(self);
    if (page == .loved) loved.reload(self);
    if (page == .genres) genres.shown(self);
    if (page == .folders) folders.shown(self);
    if (page == .settings) preferences.show(self);
    if (self.split_view) |split| adw.adw_navigation_split_view_set_show_content(split, gtk.true_);
    self.queue_visible = page == .queue;
    if (self.queue_visible) {
        queue.invalidate(self);
        queue.tick(self);
    }
    settleFocus(self);
    syncInspector(self);
    navigated(self);
}

pub fn showAlbum(self: *App, release_id: i64) void {
    showPage(self, .albums);
    const navigation = self.albums_navigation orelse return;
    popToTag(self, navigation, "albums");
    albums.openAlbum(self, navigation, release_id);
}

pub fn showArtist(self: *App, artist_id: i64) void {
    showPage(self, .artists);
    const navigation = self.artists_navigation orelse return;
    popToTag(self, navigation, "artists");
    artists.openArtist(self, navigation, artist_id);
}

pub fn goTo(self: *App, page: Page) void {
    if (pageNavigation(self, page)) |navigation| popToTag(self, navigation, page.name());
    showPage(self, page);
}

fn navClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    for (std.enums.values(Page)) |page| {
        const item = self.nav_items.get(page) orelse continue;
        if (@as(?*anyopaque, item) == button) return goTo(self, page);
    }
}

fn navItem(self: *App, item: NavItem) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(item.icon);
    gtk.gtk_widget_add_css_class(icon, "nav-icon");
    const label = gtk.gtk_label_new(item.page.title());
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_widget_set_hexpand(label, gtk.true_);
    const count = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_widget_add_css_class(count, "nav-count");
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    for ([_]*gtk.Widget{ icon, label, count }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, row), child);
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), row);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "nav-item");
    _ = gtk.signalConnect(button, "clicked", gtk.callback(navClicked), self);
    self.nav_items.set(item.page, button);
    const count_label = gtk.cast(gtk.Label, count);
    switch (item.page) {
        .albums => self.library_counts.set(.albums, count_label),
        .artists => self.library_counts.set(.artists, count_label),
        .tracks => self.library_counts.set(.tracks, count_label),
        .queue => self.queue_count = count_label,
        .matches => self.matches_count = count_label,
        else => {},
    }
    return button;
}

fn buildSidebar(self: *App) *gtk.Widget {
    const groups = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for (nav_groups) |group| {
        const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(box, "nav-group");
        const title = gtk.gtk_label_new(group.title);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
        gtk.gtk_widget_add_css_class(title, "nav-group-label");
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), title);
        for (group.items) |item| gtk.gtk_box_append(gtk.cast(gtk.Box, box), navItem(self, item));
        gtk.gtk_box_append(gtk.cast(gtk.Box, groups), box);
    }
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), groups);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);

    const wordmark = gtk.gtk_label_new("Orca");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, wordmark), 0.0);
    gtk.gtk_widget_add_css_class(wordmark, "wordmark");
    const handle = gtk.gtk_window_handle_new();
    gtk.gtk_window_handle_set_child(gtk.cast(gtk.WindowHandle, handle), wordmark);

    const nav = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(nav, "nav");
    gtk.gtk_box_append(gtk.cast(gtk.Box, nav), handle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, nav), scroller);
    gtk.gtk_box_append(gtk.cast(gtk.Box, nav), jobs.build(self));
    syncSidebarSelection(self);
    refreshCounts(self);
    return nav;
}

fn browseToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const panes = self.browse_panes orelse return;
    gtk.gtk_widget_set_visible(panes, gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)));
}

pub fn focusSearch(self: *App) void {
    if (self.header_compact) return palette.summon(self);
    const entry = self.top_bar.entry orelse return;
    _ = gtk.gtk_widget_grab_focus(entry);
}

fn buildTrackList(self: *App) *gtk.Widget {
    const view = track_table.build(&self.tracks, self, .{ .multiple = true, .sortable = true, .config = &self.track_columns });
    _ = gtk.signalConnect(
        gtk.gtk_column_view_get_sorter(self.tracks.view.?),
        "changed",
        gtk.callback(sortChanged),
        self,
    );

    const scroller = gtk.gtk_scrolled_window_new();
    self.scroller = scroller;
    gtk.gtk_widget_add_css_class(scroller, "tracks-page");
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(scrolled),
        self,
    );
    return scroller;
}

fn buildSortDropdown(self: *App) *gtk.Widget {
    var labels: [sort_choices.len + 1]?[*:0]const u8 = @splat(null);
    for (sort_choices, 0..) |choice, index| labels[index] = choice.label;
    const dropdown = gtk.gtk_drop_down_new_from_strings(&labels);
    self.sort_dropdown = gtk.cast(gtk.DropDown, dropdown);
    gtk.gtk_widget_add_css_class(dropdown, "sort-dropdown");
    gtk.gtk_widget_set_tooltip_text(dropdown, "Sort tracks");
    gtk.gtk_widget_set_valign(dropdown, gtk.ALIGN_CENTER);
    gtk.gtk_drop_down_set_selected(self.sort_dropdown.?, sortChoiceIndex(self.browse.sort));
    _ = gtk.signalConnect(dropdown, "notify::selected", gtk.callback(sortChosen), self);
    return dropdown;
}

fn buildWelcome(self: *App) *gtk.Widget {
    const page = adw.adw_status_page_new();
    self.welcome = gtk.cast(adw.StatusPage, page);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_CENTER);
    const button = gtk.gtk_button_new_with_label("Add Music Folder…");
    self.welcome_button = button;
    gtk.gtk_widget_add_css_class(button, "pill");
    gtk.gtk_widget_add_css_class(button, "suggested-action");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, button), "app.add-folder");
    const spinner = adw.adw_spinner_new();
    self.welcome_spinner = spinner;
    gtk.gtk_widget_set_size_request(spinner, 32, 32);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), spinner);
    adw.adw_status_page_set_child(self.welcome.?, actions);
    self.updateWelcome();
    return page;
}

fn buildTracksPage(self: *App) *gtk.Widget {
    const split = gtk.gtk_paned_new(gtk.ORIENTATION_HORIZONTAL);
    const panes = browse.build(self);
    self.browse_panes = panes;
    gtk.gtk_widget_add_css_class(panes, "browse-panes");
    gtk.gtk_paned_set_start_child(gtk.cast(gtk.Paned, split), panes);
    gtk.gtk_paned_set_end_child(gtk.cast(gtk.Paned, split), buildTrackList(self));
    gtk.gtk_paned_set_position(gtk.cast(gtk.Paned, split), 280);
    gtk.gtk_paned_set_resize_start_child(gtk.cast(gtk.Paned, split), gtk.false_);
    gtk.gtk_paned_set_shrink_start_child(gtk.cast(gtk.Paned, split), gtk.false_);
    gtk.gtk_paned_set_shrink_end_child(gtk.cast(gtk.Paned, split), gtk.false_);

    const no_results = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, no_results), "edit-find-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, no_results), "No results");
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, no_results), "Try a different search.");

    const body = gtk.gtk_stack_new();
    self.tracks_body = gtk.cast(gtk.Stack, body);
    gtk.gtk_stack_set_transition_type(self.tracks_body.?, gtk.STACK_TRANSITION_CROSSFADE);
    _ = gtk.gtk_stack_add_named(self.tracks_body.?, split, "list");
    _ = gtk.gtk_stack_add_named(self.tracks_body.?, buildWelcome(self), "welcome");
    _ = gtk.gtk_stack_add_named(self.tracks_body.?, no_results, "no-results");

    const title = page_ui.title("Tracks");
    gtk.gtk_widget_add_css_class(title.widget, "tracks-title");
    self.tracks_meta = title.meta;

    const list_toggle = gtk.gtk_toggle_button_new();
    self.list_toggle = list_toggle;
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, list_toggle), "view-list-symbolic");
    gtk.gtk_widget_set_tooltip_text(list_toggle, "Tracks only");
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, list_toggle), gtk.true_);
    const browse_toggle = gtk.gtk_toggle_button_new();
    self.browse_toggle = browse_toggle;
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, browse_toggle), "view-dual-symbolic");
    gtk.gtk_widget_set_tooltip_text(browse_toggle, "Show artists and albums");
    gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, browse_toggle), gtk.cast(gtk.ToggleButton, list_toggle));
    gtk.gtk_widget_set_visible(panes, gtk.false_);
    _ = gtk.signalConnect(browse_toggle, "toggled", gtk.callback(browseToggled), self);
    const view_switch = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(view_switch, "linked");
    gtk.gtk_widget_add_css_class(view_switch, "view-switch");
    gtk.gtk_widget_set_valign(view_switch, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, view_switch), list_toggle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, view_switch), browse_toggle);
    const sort_label = gtk.gtk_label_new("Sort by");
    gtk.gtk_widget_add_css_class(sort_label, "meta");
    gtk.gtk_widget_set_valign(sort_label, gtk.ALIGN_CENTER);
    title.add(sort_label);
    title.add(buildSortDropdown(self));
    title.add(track_filters.build(self));
    title.add(view_switch);

    return page_ui.withTitle(title, body);
}

/// Below this width the sidebar folds away behind a back button and the
/// browse panes give their room to the list.
const collapse_condition = "max-width: 760sp";
const compact_condition = "max-width: 900sp";
const crowded_condition = "max-width: 1100sp";

fn setBoolean(breakpoint: *adw.Breakpoint, object: *anyopaque, property: [*:0]const u8, value: bool) void {
    var boxed: gtk.GValue = .{};
    _ = gtk.g_value_init(&boxed, gtk.G_TYPE_BOOLEAN);
    gtk.g_value_set_boolean(&boxed, if (value) gtk.true_ else gtk.false_);
    adw.adw_breakpoint_add_setter(breakpoint, object, property, &boxed);
    gtk.g_value_unset(&boxed);
}

fn setInt(breakpoint: *adw.Breakpoint, object: *anyopaque, property: [*:0]const u8, value: c_int) void {
    var boxed: gtk.GValue = .{};
    _ = gtk.g_value_init(&boxed, gtk.G_TYPE_INT);
    gtk.g_value_set_int(&boxed, value);
    adw.adw_breakpoint_add_setter(breakpoint, object, property, &boxed);
    gtk.g_value_unset(&boxed);
}

/// Libadwaita applies only the last breakpoint that matches, so both carry
/// these.
fn tightenPlayerBar(self: *App, breakpoint: *adw.Breakpoint) void {
    if (self.now_playing_box) |box| setInt(breakpoint, box, "width-request", 0);
    if (self.format_slot) |slot| setBoolean(breakpoint, slot, "visible", false);
    if (self.device_label) |label| setBoolean(breakpoint, label, "visible", false);
    if (self.device_icon) |icon| setBoolean(breakpoint, icon, "visible", true);
    if (self.volume_icon) |icon| setBoolean(breakpoint, icon, "visible", false);
    if (self.volume_scale) |scale| setBoolean(breakpoint, scale, "visible", false);
    if (self.volume_menu) |button| setBoolean(breakpoint, button, "visible", true);
}

fn overlayInspectorWhenCrowded(self: *App, window: *gtk.Widget) void {
    const condition = adw.adw_breakpoint_condition_parse(crowded_condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(condition);
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(crowded), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(uncrowded), self);
    adw.adw_application_window_add_breakpoint(gtk.cast(adw.ApplicationWindow, window), breakpoint);
}

fn crowded(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.inspector_crowded = true;
    details.refit(self);
}

fn uncrowded(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.inspector_crowded = false;
    details.refit(self);
}

fn compactWhenNarrow(self: *App, window: *gtk.Widget) void {
    const condition = adw.adw_breakpoint_condition_parse(compact_condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(condition);
    tightenPlayerBar(self, breakpoint);
    if (self.folders.pane) |pane| setBoolean(breakpoint, pane, "visible", false);
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(compacted), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(uncompacted), self);
    adw.adw_application_window_add_breakpoint(gtk.cast(adw.ApplicationWindow, window), breakpoint);
}

fn compacted(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    page_ui.setCompact(self, true);
    details.refit(self);
    narrowTables(self, true);
    albums.setNarrow(self);
    artists.setNarrow(self);
    playlists.setNarrow(self);
    preferences.setNarrow(self);
}

fn uncompacted(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    page_ui.setCompact(self, false);
    details.refit(self);
    narrowTables(self, false);
    albums.setNarrow(self);
    artists.setNarrow(self);
    playlists.setNarrow(self);
    preferences.setNarrow(self);
}

fn adaptWhenNarrow(self: *App, window: *gtk.Widget, split: *gtk.Widget) void {
    const condition = adw.adw_breakpoint_condition_parse(collapse_condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(condition);
    setBoolean(breakpoint, split, "collapsed", true);
    if (self.browse_toggle) |toggle| setBoolean(breakpoint, toggle, "active", false);
    if (self.list_toggle) |toggle| setBoolean(breakpoint, toggle, "active", true);
    tightenPlayerBar(self, breakpoint);
    if (self.loved.stats) |stats| setBoolean(breakpoint, stats, "visible", false);
    if (self.folders.pane) |pane| setBoolean(breakpoint, pane, "visible", false);
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(narrowed), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(widened), self);
    adw.adw_application_window_add_breakpoint(gtk.cast(adw.ApplicationWindow, window), breakpoint);
}

/// Done here rather than with breakpoint setters, which would put back the
/// columns as they were when the window narrowed and undo a choice made since.
fn narrowTables(self: *App, narrow: bool) void {
    for ([_]*track_table.Table{ &self.tracks, &self.loved.tracks, &self.playlists.tracks }) |table| track_table.setNarrow(table, narrow);
}

fn narrowed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.window) |w| gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, w), "narrow");
    page_ui.setCompact(self, true);
    details.setNarrow(self, true);
    narrowTables(self, true);
    albums.setNarrow(self);
    artists.setNarrow(self);
    playlists.setNarrow(self);
    preferences.setNarrow(self);
}

fn widened(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.window) |w| gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, w), "narrow");
    page_ui.setCompact(self, false);
    details.setNarrow(self, false);
    narrowTables(self, false);
    albums.setNarrow(self);
    artists.setNarrow(self);
    playlists.setNarrow(self);
    preferences.setNarrow(self);
    syncSidebarSelection(self);
}

fn windowDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.window = null;
    self.toasts = null;
    if (self.history.pending != 0) _ = gtk.g_source_remove(self.history.pending);
    self.history.pending = 0;
    preferences.shutdown(self);
    lyrics.shutdown(self);
}

pub fn build(self: *App, application: *gtk.Application) *gtk.Widget {
    const window = adw.adw_application_window_new(application);
    self.window = gtk.cast(gtk.Window, window);
    _ = gtk.signalConnect(window, "destroy", gtk.callback(windowDestroyed), self);

    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_BUBBLE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(windowKeyPressed), self);
    gtk.gtk_widget_add_controller(window, keys);
    const history_keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(history_keys, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(history_keys, "key-pressed", gtk.callback(windowHistoryKeyPressed), self);
    gtk.gtk_widget_add_controller(window, history_keys);
    const space_keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(space_keys, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(space_keys, "key-pressed", gtk.callback(windowSpaceKeyPressed), self);
    gtk.gtk_widget_add_controller(window, space_keys);
    addMouseButton(window, mouse_back_button, gtk.callback(backPressed), self);
    addMouseButton(window, mouse_forward_button, gtk.callback(forwardPressed), self);
    gtk.gtk_window_set_title(self.window.?, "Orca");
    gtk.gtk_window_set_default_size(self.window.?, 1240, 800);

    const top_bar = page_ui.build(self);
    const pages = gtk.gtk_stack_new();
    self.pages = gtk.cast(gtk.Stack, pages);
    gtk.gtk_stack_set_transition_type(self.pages.?, gtk.STACK_TRANSITION_CROSSFADE);
    _ = gtk.gtk_stack_add_named(self.pages.?, albums.build(self), Page.albums.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, artists.build(self), Page.artists.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, buildTracksPage(self), Page.tracks.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, genres.build(self), Page.genres.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, folders.build(self), Page.folders.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, loved.build(self), Page.loved.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, health.build(self), Page.health.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, matches.build(self), Page.matches.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, nowplaying.build(self), Page.now_playing.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, queue.build(self), Page.queue.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, playlists.build(self), Page.playlists.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, preferences.build(self), Page.settings.name());

    watchSections(self);
    const inspected = adw.adw_overlay_split_view_new();
    const inspected_view = gtk.cast(adw.OverlaySplitView, inspected);
    adw.adw_overlay_split_view_set_sidebar_position(inspected_view, gtk.PACK_END);
    adw.adw_overlay_split_view_set_pin_sidebar(inspected_view, gtk.true_);
    adw.adw_overlay_split_view_set_enable_show_gesture(inspected_view, gtk.false_);
    gtk.gtk_widget_set_hexpand(pages, gtk.true_);
    adw.adw_overlay_split_view_set_content(inspected_view, pages);
    details.build(self, inspected_view);
    const framed = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, framed), top_bar);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, framed), inspected);
    const content = adw.adw_navigation_page_new(framed, Page.albums.title());
    self.content_page = content;
    const sidebar = adw.adw_navigation_page_new(buildSidebar(self), "Orca");

    const split = adw.adw_navigation_split_view_new();
    self.split_view = gtk.cast(adw.NavigationSplitView, split);
    adw.adw_navigation_split_view_set_sidebar(self.split_view.?, sidebar);
    adw.adw_navigation_split_view_set_content(self.split_view.?, content);
    adw.adw_navigation_split_view_set_min_sidebar_width(self.split_view.?, 216);
    adw.adw_navigation_split_view_set_max_sidebar_width(self.split_view.?, 216);

    const root = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, root), split);
    adw.adw_toolbar_view_add_bottom_bar(gtk.cast(adw.ToolbarView, root), transport.build(self));
    adw.adw_toolbar_view_set_bottom_bar_style(gtk.cast(adw.ToolbarView, root), adw.TOOLBAR_RAISED_BORDER);

    const overlay = adw.adw_toast_overlay_new();
    self.toasts = gtk.cast(adw.ToastOverlay, overlay);
    adw.adw_toast_overlay_set_child(self.toasts.?, root);
    adw.adw_application_window_set_content(gtk.cast(adw.ApplicationWindow, window), overlay);
    overlayInspectorWhenCrowded(self, window);
    compactWhenNarrow(self, window);
    adaptWhenNarrow(self, window, split);
    record(self);
    page_ui.refresh(self);
    syncInspector(self);
    return window;
}
