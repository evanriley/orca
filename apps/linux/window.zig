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
const health = @import("health.zig");
const matches = @import("matches.zig");
const playlists = @import("playlists.zig");
const loved = @import("loved.zig");
const genres = @import("genres.zig");
const folders = @import("folders.zig");
const page_ui = @import("page.zig");
const song_table = @import("song_table.zig");
const song_filters = @import("song_filters.zig");
const preferences = @import("preferences.zig");

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
    song_table.markPlaying(&.{ &self.songs, &self.loved.songs, &self.playlists.songs }, track_id);
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
    self.songs.positions = self.browse.sort != .track_number and self.browse.sort != .album;
    song_table.markSorted(&self.songs, if (self.browse.sort == .id) null else self.browse.sort);
}

pub fn showSort(self: *App) void {
    // Sorting the view or choosing an entry is indistinguishable from a user's
    // click to GTK, and their signals would arrive back as one.
    const previous = self.suppress_browse_signals;
    self.suppress_browse_signals = true;
    defer self.suppress_browse_signals = previous;
    if (self.sort_dropdown) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, sortChoiceIndex(self.browse.sort));
    showSortedColumn(self);
    const view = self.songs.view orelse return;
    var chosen: ?*gtk.ColumnViewColumn = null;
    for (Column.all) |column| {
        if (column.sortKey()) |key| {
            if (key == self.browse.sort) chosen = self.songs.header(column);
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
    const column_sorter = gtk.cast(gtk.ColumnViewSorter, sorter);
    const primary = gtk.gtk_column_view_sorter_get_primary_sort_column(column_sorter);
    self.browse.sort = .id;
    self.browse.direction = .ascending;
    if (primary) |chosen| {
        for (Column.all) |column| {
            if (self.songs.header(column) == chosen) {
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

fn searchChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_browse_signals) return;
    const text = gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry));
    self.query.set(self.allocator, std.mem.span(text));
    // A text match and a browse scope are alternatives to liborca, so a search
    // takes the listing over rather than narrowing what a pane already chose.
    // The Artist pane's filter is untouched: it says which Artists are listed,
    // not which tracks, so it survives a search that clears the selection.
    if (self.query.value.len != 0) browse.clearScope(self);
    self.reload();
}

/// Enter in the search box plays what it found, in the order shown.
fn searchActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var ids = song_table.playableIds(&self.songs, self.allocator);
    defer ids.deinit(self.allocator);
    if (ids.items.len != 0) transport.playIds(self, ids.items, 0);
}

fn addFolderClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.chooseFolder(state(data));
}

/// Returns true only when it actually consumed the key. Reached in the bubble
/// phase, so the focused widget has already declined it — which is what lets a
/// space typed into the search entry stay a space, and Ctrl+arrows keep moving
/// by word there. An application accelerator would be matched before the
/// focused widget and would eat them.
fn windowKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    const held = modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT);
    if (keyval == gtk.KEY_space and held == 0) {
        transport.toggle(self);
        return gtk.true_;
    }
    if (held == gtk.MODIFIER_CONTROL and keyval == gtk.KEY_Right) {
        transport.next(self);
        return gtk.true_;
    }
    if (held == gtk.MODIFIER_CONTROL and keyval == gtk.KEY_Left) {
        transport.previous(self);
        return gtk.true_;
    }
    if (held == gtk.MODIFIER_ALT and keyval == gtk.KEY_Left) {
        back(self);
        return gtk.true_;
    }
    return gtk.false_;
}

const mouse_back_button: c_uint = 8;

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
            .tracks => "Songs",
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
};

pub fn showPage(self: *App, page: Page) void {
    switchTo(self, page, true);
}

fn remember(self: *App, page: Page) void {
    if (self.page_history_len == self.page_history.len) {
        @memmove(self.page_history[0 .. self.page_history_len - 1], self.page_history[1..self.page_history_len]);
        self.page_history_len -= 1;
    }
    self.page_history[self.page_history_len] = page;
    self.page_history_len += 1;
}

fn pageNavigation(self: *App, page: Page) ?*adw.NavigationView {
    return switch (page) {
        .albums => self.albums_navigation,
        .artists => self.artists_navigation,
        .genres => self.genres.navigation,
        .loved => self.loved.navigation,
        .playlists => self.playlists.navigation,
        else => null,
    };
}

fn popPushedPage(self: *App) bool {
    const navigation = pageNavigation(self, self.current_page) orelse return false;
    const at_root = if (adw.adw_navigation_view_get_visible_page_tag(navigation)) |tag|
        std.mem.eql(u8, std.mem.span(tag), std.mem.span(self.current_page.name()))
    else
        false;
    if (at_root) return false;
    return adw.adw_navigation_view_pop(navigation) != 0;
}

pub fn back(self: *App) void {
    if (popPushedPage(self)) return;
    if (self.page_history_len == 0) return;
    self.page_history_len -= 1;
    switchTo(self, self.page_history[self.page_history_len], false);
}

fn backPressed(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_gesture_set_state(gtk.cast(gtk.Gesture, gesture), gtk.EVENT_SEQUENCE_CLAIMED);
    back(state(data));
}

/// `AdwSidebar` numbers items across sections, in the order `buildSidebar`
/// appends them.
const sidebar_pages = [_]Page{ .albums, .artists, .tracks, .genres, .folders, .loved, .playlists, .now_playing, .queue, .health, .matches };

fn sidebarIndex(page: Page) c_uint {
    const position = std.mem.indexOfScalar(Page, &sidebar_pages, page) orelse return gtk.INVALID_LIST_POSITION;
    return @intCast(position);
}

fn sidebarPage(index: c_uint) ?Page {
    return if (index < sidebar_pages.len) sidebar_pages[index] else null;
}

/// Puts the sidebar's highlight back on the page that is showing.
pub fn syncSidebarSelection(self: *App) void {
    const sidebar = self.sidebar orelse return;
    const wanted = sidebarIndex(self.current_page);
    if (adw.adw_sidebar_get_selected(sidebar) != wanted) adw.adw_sidebar_set_selected(sidebar, wanted);
    const settings = self.settings_sidebar orelse return;
    const settings_wanted: c_uint = if (self.current_page == .settings) 0 else gtk.INVALID_LIST_POSITION;
    if (adw.adw_sidebar_get_selected(settings) != settings_wanted) adw.adw_sidebar_set_selected(settings, settings_wanted);
}

fn switchTo(self: *App, page: Page, remember_previous: bool) void {
    if (remember_previous and page != self.current_page) remember(self, self.current_page);
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
}

pub fn showAlbum(self: *App, release_id: i64) void {
    showPage(self, .albums);
    const navigation = self.albums_navigation orelse return;
    _ = adw.adw_navigation_view_pop_to_tag(navigation, "albums");
    albums.openAlbum(self, navigation, release_id);
}

pub fn showArtist(self: *App, artist_id: i64) void {
    showPage(self, .artists);
    const navigation = self.artists_navigation orelse return;
    _ = adw.adw_navigation_view_pop_to_tag(navigation, "artists");
    artists.openArtist(self, navigation, artist_id);
}

pub fn goTo(self: *App, page: Page) void {
    if (pageNavigation(self, page)) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, page.name());
    showPage(self, page);
}

fn sidebarActivated(_: ?*anyopaque, index: c_uint, data: ?*anyopaque) callconv(.c) void {
    goTo(state(data), sidebarPage(index) orelse return);
}

fn sidebarItem(section: *adw.SidebarSection, title: [*:0]const u8, icon: [*:0]const u8) *adw.SidebarItem {
    const item = adw.adw_sidebar_item_new(title);
    adw.adw_sidebar_item_set_icon_name(item, icon);
    adw.adw_sidebar_section_append(section, item);
    return item;
}

fn primaryMenu() *gtk.Widget {
    const library = gtk.g_menu_new();
    gtk.g_menu_append(library, "Add Music Folder…", "app.add-folder");
    gtk.g_menu_append(library, "Rescan Library", "app.rescan");
    gtk.g_menu_append(library, "Settings", "app.preferences");
    const help = gtk.g_menu_new();
    gtk.g_menu_append(help, "Keyboard Shortcuts", "app.shortcuts");
    gtk.g_menu_append(help, "About Orca", "app.about");
    const model = gtk.g_menu_new();
    gtk.g_menu_append_section(model, null, gtk.cast(gtk.GMenuModel, library));
    gtk.g_menu_append_section(model, null, gtk.cast(gtk.GMenuModel, help));
    gtk.g_object_unref(library);
    gtk.g_object_unref(help);
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), "open-menu-symbolic");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, button), gtk.cast(gtk.GMenuModel, model));
    gtk.gtk_menu_button_set_primary(gtk.cast(gtk.MenuButton, button), gtk.true_);
    gtk.gtk_widget_set_tooltip_text(button, "Main Menu");
    gtk.g_object_unref(model);
    return button;
}

fn countSuffix(item: *adw.SidebarItem) *gtk.Label {
    const count = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_widget_add_css_class(count, "sidebar-count");
    adw.adw_sidebar_item_set_suffix(item, count);
    return gtk.cast(gtk.Label, count);
}

fn titledSection(title: [*:0]const u8) *adw.SidebarSection {
    const section = adw.adw_sidebar_section_new();
    adw.adw_sidebar_section_set_title(section, title);
    return section;
}

fn settingsSelected(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    syncSidebarSelection(state(data));
}

fn settingsActivated(_: ?*anyopaque, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.window) |w| _ = gtk.gtk_widget_activate_action_variant(gtk.cast(gtk.Widget, w), "app.preferences", null);
}

fn buildSettingsItem(self: *App) *gtk.Widget {
    const sidebar = adw.adw_sidebar_new();
    gtk.gtk_widget_add_css_class(sidebar, "sidebar-settings");
    self.settings_sidebar = gtk.cast(adw.Sidebar, sidebar);
    _ = gtk.signalConnect(sidebar, "notify::selected", gtk.callback(settingsSelected), self);
    _ = gtk.signalConnect(sidebar, "activated", gtk.callback(settingsActivated), self);
    const section = adw.adw_sidebar_section_new();
    _ = sidebarItem(section, "Settings", "emblem-system-symbolic");
    adw.adw_sidebar_append(gtk.cast(adw.Sidebar, sidebar), section);
    return sidebar;
}

fn buildSidebar(self: *App) *gtk.Widget {
    const sidebar = adw.adw_sidebar_new();
    self.sidebar = gtk.cast(adw.Sidebar, sidebar);
    gtk.gtk_widget_set_vexpand(sidebar, gtk.true_);

    const library = titledSection("Library");
    _ = sidebarItem(library, "Albums", "media-optical-symbolic");
    _ = sidebarItem(library, "Artists", "avatar-default-symbolic");
    _ = sidebarItem(library, "Songs", "audio-x-generic-symbolic");
    _ = sidebarItem(library, "Genres", "applications-multimedia-symbolic");
    _ = sidebarItem(library, "Folders", "folder-symbolic");
    _ = sidebarItem(library, "Loved", feedback.filled_icon);
    adw.adw_sidebar_append(self.sidebar.?, library);

    const collection = titledSection("Collection");
    _ = sidebarItem(collection, "Playlists", "media-playlist-consecutive-symbolic");
    adw.adw_sidebar_append(self.sidebar.?, collection);

    const playback = titledSection("Playback");
    _ = sidebarItem(playback, "Now Playing", "media-playback-start-symbolic");
    self.queue_count = countSuffix(sidebarItem(playback, "Queue", "view-list-symbolic"));
    adw.adw_sidebar_append(self.sidebar.?, playback);

    const tools = titledSection("Library Tools");
    self.health.count = countSuffix(sidebarItem(tools, "Health", "emblem-important-symbolic"));
    self.matches_count = countSuffix(sidebarItem(tools, "Matches", "system-search-symbolic"));
    adw.adw_sidebar_append(self.sidebar.?, tools);
    _ = gtk.signalConnect(sidebar, "activated", gtk.callback(sidebarActivated), self);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), sidebar);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), buildSettingsItem(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), jobs.build(self));

    const header = adw.adw_header_bar_new();
    adw.adw_header_bar_set_show_title(gtk.cast(adw.HeaderBar, header), gtk.false_);
    const wordmark = gtk.gtk_label_new("Orca");
    gtk.gtk_widget_add_css_class(wordmark, "wordmark");
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, header), wordmark);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), primaryMenu());
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

fn browseToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const panes = self.browse_panes orelse return;
    gtk.gtk_widget_set_visible(panes, gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)));
}

pub fn focusSearch(self: *App) void {
    showPage(self, .tracks);
    const entry = self.search_entry orelse return;
    _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, entry));
}

pub fn focusPageSearch(self: *App) void {
    const entry: ?*gtk.Widget = switch (self.current_page) {
        .albums => if (self.album_search_entry) |editable| gtk.cast(gtk.Widget, editable) else null,
        .artists => self.artist_list_search,
        .playlists => self.playlists.overview_search,
        else => null,
    };
    const found = entry orelse return focusSearch(self);
    goTo(self, self.current_page);
    _ = gtk.gtk_widget_grab_focus(found);
}

fn buildTrackList(self: *App) *gtk.Widget {
    const view = song_table.build(&self.songs, self, .{ .multiple = true, .sortable = true, .config = &self.song_columns });
    _ = gtk.signalConnect(
        gtk.gtk_column_view_get_sorter(self.songs.view.?),
        "changed",
        gtk.callback(sortChanged),
        self,
    );

    const scroller = gtk.gtk_scrolled_window_new();
    self.scroller = scroller;
    gtk.gtk_widget_add_css_class(scroller, "songs-tracks");
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
    gtk.gtk_widget_set_tooltip_text(dropdown, "Sort songs");
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

    const search = gtk.gtk_search_entry_new();
    self.search_entry = gtk.cast(gtk.Editable, search);
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, search), "Search songs, artists, albums…");
    gtk.gtk_search_entry_set_search_delay(gtk.cast(gtk.SearchEntry, search), app.search_delay_ms);
    gtk.gtk_widget_set_size_request(search, wide_search_width, -1);
    gtk.gtk_widget_set_hexpand(search, gtk.true_);
    _ = gtk.signalConnect(search, "search-changed", gtk.callback(searchChanged), self);
    _ = gtk.signalConnect(search, "activate", gtk.callback(searchActivated), self);
    const search_field = page_ui.searchField(search, "Ctrl F");
    gtk.gtk_widget_add_css_class(search_field, "songs-search");
    gtk.gtk_widget_set_valign(search_field, gtk.ALIGN_CENTER);
    const header = page_ui.headerWith(search_field);
    header.add(song_filters.build(self));

    const title = page_ui.title("Songs");
    gtk.gtk_widget_add_css_class(title.widget, "songs-title");
    self.tracks_meta = title.meta;

    const list_toggle = gtk.gtk_toggle_button_new();
    self.list_toggle = list_toggle;
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, list_toggle), "view-list-symbolic");
    gtk.gtk_widget_set_tooltip_text(list_toggle, "Songs only");
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
    title.add(view_switch);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header.bar);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), details.besideContent(self, header, page_ui.withTitle(title, body), .{ .selection = self.songs.selection.? }).widget);
    return view;
}

/// Below this width the sidebar folds away behind a back button and the
/// browse panes give their room to the list.
const collapse_condition = "max-width: 760sp";
const compact_condition = "max-width: 900sp";
const crowded_condition = "max-width: 1100sp";
const wide_search_width = 330;
const narrow_search_width = 120;

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
    if (self.adjustments_label) |label| setBoolean(breakpoint, label, "visible", false);
    if (self.device_label) |label| setBoolean(breakpoint, label, "visible", false);
    if (self.device_icon) |icon| setBoolean(breakpoint, icon, "visible", true);
    if (self.volume_icon) |icon| setBoolean(breakpoint, icon, "visible", false);
    if (self.volume_scale) |scale| setBoolean(breakpoint, scale, "visible", false);
    if (self.volume_menu) |button| setBoolean(breakpoint, button, "visible", true);
}

fn shortenSongsSearch(self: *App, breakpoint: *adw.Breakpoint) void {
    if (self.search_entry) |entry| setInt(breakpoint, entry, "width-request", narrow_search_width);
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
    shortenSongsSearch(self, breakpoint);
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
    shortenSongsSearch(self, breakpoint);
    if (self.playlists.overview_search) |entry| setInt(breakpoint, entry, "width-request", 120);
    if (self.loved.stats) |stats| setBoolean(breakpoint, stats, "visible", false);
    if (self.folders.pane) |pane| setBoolean(breakpoint, pane, "visible", false);
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(narrowed), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(widened), self);
    adw.adw_application_window_add_breakpoint(gtk.cast(adw.ApplicationWindow, window), breakpoint);
}

/// Done here rather than with breakpoint setters, which would put back the
/// columns as they were when the window narrowed and undo a choice made since.
fn narrowTables(self: *App, narrow: bool) void {
    for ([_]*song_table.Table{ &self.songs, &self.loved.songs, &self.playlists.songs }) |table| song_table.setNarrow(table, narrow);
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

pub fn build(self: *App, application: *gtk.Application) *gtk.Widget {
    const window = adw.adw_application_window_new(application);
    self.window = gtk.cast(gtk.Window, window);

    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_BUBBLE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(windowKeyPressed), self);
    gtk.gtk_widget_add_controller(window, keys);
    const back_button = gtk.gtk_gesture_click_new();
    gtk.gtk_gesture_single_set_button(gtk.cast(gtk.GestureSingle, back_button), mouse_back_button);
    gtk.gtk_event_controller_set_propagation_phase(back_button, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(back_button, "pressed", gtk.callback(backPressed), self);
    gtk.gtk_widget_add_controller(window, back_button);
    gtk.gtk_window_set_title(self.window.?, "Orca");
    gtk.gtk_window_set_default_size(self.window.?, 1240, 800);

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

    const content = adw.adw_navigation_page_new(pages, Page.albums.title());
    self.content_page = content;
    const sidebar = adw.adw_navigation_page_new(buildSidebar(self), "Orca");

    const split = adw.adw_navigation_split_view_new();
    self.split_view = gtk.cast(adw.NavigationSplitView, split);
    adw.adw_navigation_split_view_set_sidebar(self.split_view.?, sidebar);
    adw.adw_navigation_split_view_set_content(self.split_view.?, content);
    adw.adw_navigation_split_view_set_min_sidebar_width(self.split_view.?, 200);
    adw.adw_navigation_split_view_set_max_sidebar_width(self.split_view.?, 240);

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
    return window;
}
