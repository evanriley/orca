//! The main window: a sidebar of pages beside the page itself, the player bar
//! along the bottom, and toasts over both.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const scan = @import("scan.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const browse = @import("browse.zig");
const queue = @import("queue.zig");
const albums = @import("albums.zig");
const nowplaying = @import("nowplaying.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;
const Column = track_model.Column;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn columnData(column: Column) ?*anyopaque {
    return @ptrFromInt(@intFromEnum(column));
}

fn columnOf(data: ?*anyopaque) Column {
    return @enumFromInt(@as(std.meta.Tag(Column), @intCast(@intFromPtr(data))));
}

// ----------------------------------------------------------------- scrolling

fn scrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.page_exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) -
        (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page) self.loadNextPage();
}

// ---------------------------------------------------------------- activation

fn rowActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selection = self.selection orelse return;
    const model = gtk.cast(gtk.ListModel, selection);
    const chosen = gtk.gtk_selection_model_get_selection(selection);

    // Activation is not selection. Activating a multi-row selection plays that
    // selection as a queue, from its first row.
    //
    // It used to start at the activated row, which sounds reasonable and is
    // wrong for the way a selection is actually made. Selecting track 1 and
    // shift-clicking track 11 leaves the cursor on 11, so GTK reports 11 as
    // the activated position and pressing Enter began at the last track and
    // reported the end of the queue on the next skip. The row that happens to
    // hold the cursor is not the row the user means; the top of what they
    // highlighted is.
    if (gtk.gtk_bitset_get_size(chosen) > 1 and gtk.gtk_bitset_contains(chosen, position) != 0) {
        defer gtk.gtk_bitset_unref(chosen);
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(self.allocator);
        var iter: gtk.BitsetIter = .{};
        var index: c_uint = 0;
        var valid = gtk.gtk_bitset_iter_init_first(&iter, chosen, &index);
        // A bitset iterates ascending, so this is the order the rows are shown
        // in, which is the order the user highlighted them in.
        while (valid != 0) : (valid = gtk.gtk_bitset_iter_next(&iter, &index)) {
            const item = gtk.g_list_model_get_item(model, index) orelse continue;
            const row: *TrackObject = @ptrCast(@alignCast(item));
            if (row.hasFile()) ids.append(self.allocator, row.id()) catch {};
            gtk.g_object_unref(item);
        }
        if (ids.items.len != 0)
            transport.playIds(self, ids.items, 0)
        else
            self.toast("None of the selected tracks has a playable file");
        return;
    }
    gtk.gtk_bitset_unref(chosen);

    const item = gtk.g_list_model_get_item(model, position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *TrackObject = @ptrCast(@alignCast(item));
    if (!row.hasFile()) {
        self.toast("That track has no playable file");
        return;
    }
    const id = row.id();
    transport.playIds(self, &.{id}, 0);
}

// ------------------------------------------------------------------- columns

fn setupCell(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const label = gtk.gtk_label_new(null);
    const column = columnOf(data);
    gtk.gtk_label_set_xalign(
        gtk.cast(gtk.Label, label),
        if (column == .duration or column == .number) 1.0 else 0.0,
    );
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), label);
}

fn bindCell(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *TrackObject = @ptrCast(@alignCast(object));
    const child = gtk.gtk_list_item_get_child(list_item) orelse return;
    const label = gtk.cast(gtk.Label, child);
    var buffer: [32]u8 = undefined;
    const text: [:0]const u8 = switch (columnOf(data)) {
        .number => row.numberText(&buffer),
        .title => row.title(),
        .artist => row.artist(),
        .album => row.album(),
        .duration => row.durationText(&buffer),
    };
    gtk.gtk_label_set_text(label, text.ptr);
    // A Track whose file is missing is shown, not hidden — the library still
    // knows about it — but it is visibly not playable.
    if (row.hasFile())
        gtk.gtk_widget_remove_css_class(child, "dim-label")
    else
        gtk.gtk_widget_add_css_class(child, "dim-label");
    if (playing_id != null and playing_id.? == row.id())
        gtk.gtk_widget_add_css_class(child, "playing")
    else
        gtk.gtk_widget_remove_css_class(child, "playing");
}

/// The Track the list marks as playing. Presentation only: the engine's
/// audible entry is read on the tick and handed to `markPlaying`.
var playing_id: ?i64 = null;

/// Moves the playing mark, replacing only the rows that gain or lose it.
pub fn markPlaying(self: *App, track_id: ?i64) void {
    const previous = playing_id;
    playing_id = track_id;
    const store = self.tracks orelse return;
    const model = gtk.cast(gtk.ListModel, store);
    const count = gtk.g_list_model_get_n_items(model);
    var index: c_uint = 0;
    while (index < count) : (index += 1) {
        const item = gtk.g_list_model_get_item(model, index) orelse continue;
        defer gtk.g_object_unref(item);
        const row: *TrackObject = @ptrCast(@alignCast(item));
        const was = previous != null and previous.? == row.id();
        const is = track_id != null and track_id.? == row.id();
        if (!was and !is) continue;
        const copy = track_model.clone(row) orelse continue;
        var replacement: [1]?*anyopaque = .{copy};
        gtk.g_list_store_splice(store, index, 1, &replacement, 1);
        gtk.g_object_unref(copy);
    }
}

fn makeColumn(
    title: [*:0]const u8,
    column: Column,
    width: c_int,
    expand: bool,
) *gtk.ColumnViewColumn {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupCell), columnData(column));
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindCell), columnData(column));
    const result = gtk.gtk_column_view_column_new(title, factory);
    gtk.gtk_column_view_column_set_resizable(result, gtk.true_);
    gtk.gtk_column_view_column_set_expand(result, if (expand) gtk.true_ else gtk.false_);
    if (width > 0) gtk.gtk_column_view_column_set_fixed_width(result, width);
    const sorter = track_model.headerSorter();
    gtk.gtk_column_view_column_set_sorter(result, sorter);
    gtk.g_object_unref(sorter);
    return result;
}

/// A header click, turned into a new engine query.
///
/// The whole result is re-ordered and the listing restarts at its first page,
/// because the alternative — reordering the rows already loaded — sorts one
/// screenful of a listing that is 22,060 rows long and calls it sorted.
fn sortChanged(sorter: ?*anyopaque, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_browse_signals) return;
    const column_sorter = gtk.cast(gtk.ColumnViewSorter, sorter);
    const primary = gtk.gtk_column_view_sorter_get_primary_sort_column(column_sorter);
    self.browse.sort = .id;
    self.browse.direction = .ascending;
    if (primary) |chosen| {
        for (Column.all, self.sort_columns) |column, header| {
            if (header == chosen) self.browse.sort = column.sortKey();
        }
        self.browse.direction =
            if (gtk.gtk_column_view_sorter_get_primary_sort_order(column_sorter) ==
            gtk.SORT_DESCENDING) .descending else .ascending;
    }
    self.reload();
}

// -------------------------------------------------------------------- chrome

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
    const store = self.tracks orelse return;
    const model = gtk.cast(gtk.ListModel, store);
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(self.allocator);
    var index: c_uint = 0;
    while (index < gtk.g_list_model_get_n_items(model)) : (index += 1) {
        const item = gtk.g_list_model_get_item(model, index) orelse continue;
        const row: *TrackObject = @ptrCast(@alignCast(item));
        if (row.hasFile()) ids.append(self.allocator, row.id()) catch {};
        gtk.g_object_unref(item);
    }
    if (ids.items.len != 0) transport.playIds(self, ids.items, 0);
}

fn addFolderClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    scan.chooseFolder(state(data));
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
    return gtk.false_;
}

// --------------------------------------------------------------- navigation

/// In sidebar order: `AdwSidebar` numbers items across sections.
pub const Page = enum(c_uint) {
    albums,
    tracks,
    now_playing,
    queue,

    fn name(self: Page) [*:0]const u8 {
        return switch (self) {
            .albums => "albums",
            .tracks => "tracks",
            .now_playing => "now-playing",
            .queue => "queue",
        };
    }

    fn title(self: Page) [*:0]const u8 {
        return switch (self) {
            .albums => "Albums",
            .tracks => "Tracks",
            .now_playing => "Now Playing",
            .queue => "Queue",
        };
    }
};

pub fn showPage(self: *App, page: Page) void {
    if (self.pages) |pages| gtk.gtk_stack_set_visible_child_name(pages, page.name());
    if (self.content_page) |content| adw.adw_navigation_page_set_title(content, page.title());
    if (self.sidebar) |sidebar| {
        if (adw.adw_sidebar_get_selected(sidebar) != @intFromEnum(page))
            adw.adw_sidebar_set_selected(sidebar, @intFromEnum(page));
    }
    if (self.split_view) |split| adw.adw_navigation_split_view_set_show_content(split, gtk.true_);
    self.queue_visible = page == .queue;
    if (self.queue_visible) {
        queue.invalidate(self);
        queue.tick(self);
    }
}

fn sidebarActivated(_: ?*anyopaque, index: c_uint, data: ?*anyopaque) callconv(.c) void {
    if (index > @intFromEnum(Page.queue)) return;
    const page: Page = @enumFromInt(index);
    if (page == .albums) if (state(data).albums_navigation) |navigation| {
        _ = adw.adw_navigation_view_pop_to_tag(navigation, "albums");
    };
    showPage(state(data), @enumFromInt(index));
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
    const help = gtk.g_menu_new();
    gtk.g_menu_append(help, "Keyboard Shortcuts", "app.shortcuts");
    gtk.g_menu_append(help, "About Orca", "app.about");
    const menu = gtk.g_menu_new();
    gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, library));
    gtk.g_menu_append_section(menu, null, gtk.cast(gtk.GMenuModel, help));
    gtk.g_object_unref(library);
    gtk.g_object_unref(help);
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), "open-menu-symbolic");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, button), gtk.cast(gtk.GMenuModel, menu));
    gtk.gtk_menu_button_set_primary(gtk.cast(gtk.MenuButton, button), gtk.true_);
    gtk.gtk_widget_set_tooltip_text(button, "Main Menu");
    gtk.g_object_unref(menu);
    return button;
}

fn buildSidebar(self: *App) *gtk.Widget {
    const sidebar = adw.adw_sidebar_new();
    self.sidebar = gtk.cast(adw.Sidebar, sidebar);
    gtk.gtk_widget_set_vexpand(sidebar, gtk.true_);
    const section = adw.adw_sidebar_section_new();
    _ = sidebarItem(section, "Albums", "media-optical-symbolic");
    _ = sidebarItem(section, "Tracks", "audio-x-generic-symbolic");
    adw.adw_sidebar_append(self.sidebar.?, section);
    const playback = adw.adw_sidebar_section_new();
    adw.adw_sidebar_section_set_title(playback, "Playback");
    _ = sidebarItem(playback, "Now Playing", "media-playback-start-symbolic");
    const queue_item = sidebarItem(playback, "Queue", "view-list-symbolic");
    const count = gtk.gtk_label_new("");
    self.queue_count = gtk.cast(gtk.Label, count);
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_widget_add_css_class(count, "dim-label");
    adw.adw_sidebar_item_set_suffix(queue_item, count);
    adw.adw_sidebar_append(self.sidebar.?, playback);
    _ = gtk.signalConnect(sidebar, "activated", gtk.callback(sidebarActivated), self);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), sidebar);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), scan.build(self));

    const header = adw.adw_header_bar_new();
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), adw.adw_window_title_new("Orca", ""));
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), primaryMenu());
    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

// -------------------------------------------------------------- tracks page

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

fn buildTrackList(self: *App) *gtk.Widget {
    // The model chain: an owned page store, multi-selectable so a run of tracks
    // can be activated as a queue. Deliberately *not* wrapped in a
    // `GtkSortListModel` — the rows in the store are one page of an order the
    // engine already decided, and a sort model would reshuffle that page.
    self.tracks = gtk.g_list_store_new(track_model.getType());
    self.selection = gtk.gtk_multi_selection_new(
        gtk.cast(gtk.ListModel, gtk.g_object_ref(self.tracks)),
    );
    const view = gtk.gtk_column_view_new(self.selection);
    self.column_view = gtk.cast(gtk.ColumnView, view);
    gtk.gtk_widget_add_css_class(view, "track-list");
    gtk.gtk_column_view_set_show_column_separators(self.column_view.?, gtk.false_);
    gtk.gtk_column_view_set_reorderable(self.column_view.?, gtk.true_);
    _ = gtk.signalConnect(view, "activate", gtk.callback(rowActivated), self);
    _ = gtk.signalConnect(
        gtk.gtk_column_view_get_sorter(self.column_view.?),
        "changed",
        gtk.callback(sortChanged),
        self,
    );

    const columns: [Column.all.len]*gtk.ColumnViewColumn = .{
        makeColumn("#", .number, 64, false),
        makeColumn("Title", .title, 320, true),
        makeColumn("Artist", .artist, 220, true),
        makeColumn("Album", .album, 220, true),
        makeColumn("Length", .duration, 80, false),
    };
    for (columns, 0..) |column, index| {
        gtk.gtk_column_view_append_column(self.column_view.?, column);
        self.sort_columns[index] = column;
        gtk.g_object_unref(column);
    }

    const scroller = gtk.gtk_scrolled_window_new();
    self.scroller = scroller;
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

    const header = adw.adw_header_bar_new();
    const title = adw.adw_window_title_new("Tracks", "");
    self.tracks_title = gtk.cast(adw.WindowTitle, title);
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), title);

    const browse_toggle = gtk.gtk_toggle_button_new();
    self.browse_toggle = browse_toggle;
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, browse_toggle), "view-dual-symbolic");
    gtk.gtk_widget_set_tooltip_text(browse_toggle, "Show artists and albums");
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, browse_toggle), gtk.true_);
    _ = gtk.signalConnect(browse_toggle, "toggled", gtk.callback(browseToggled), self);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, header), browse_toggle);

    const search = gtk.gtk_search_entry_new();
    self.search_entry = gtk.cast(gtk.Editable, search);
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, search), "Search tracks");
    gtk.gtk_widget_set_size_request(search, 260, -1);
    _ = gtk.signalConnect(search, "search-changed", gtk.callback(searchChanged), self);
    _ = gtk.signalConnect(search, "activate", gtk.callback(searchActivated), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), search);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

// ------------------------------------------------------------------- window

/// Below this width the sidebar folds away behind a back button, the browse
/// panes give their room to the list, and the player bar tightens.
const collapse_condition = "max-width: 760sp";

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

fn adaptWhenNarrow(self: *App, window: *gtk.Widget, split: *gtk.Widget) void {
    const condition = adw.adw_breakpoint_condition_parse(collapse_condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(condition);
    setBoolean(breakpoint, split, "collapsed", true);
    if (self.browse_toggle) |toggle| setBoolean(breakpoint, toggle, "active", false);
    if (self.now_playing_box) |box| setInt(breakpoint, box, "width-request", 0);
    if (self.seek_scale) |scale| setInt(breakpoint, scale, "width-request", 120);
    if (self.search_entry) |entry| setInt(breakpoint, entry, "width-request", 120);
    adw.adw_application_window_add_breakpoint(gtk.cast(adw.ApplicationWindow, window), breakpoint);
}

pub fn build(self: *App, application: *gtk.Application) *gtk.Widget {
    const window = adw.adw_application_window_new(application);
    self.window = gtk.cast(gtk.Window, window);

    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_BUBBLE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(windowKeyPressed), self);
    gtk.gtk_widget_add_controller(window, keys);
    gtk.gtk_window_set_title(self.window.?, "Orca");
    gtk.gtk_window_set_default_size(self.window.?, 1240, 800);

    const pages = gtk.gtk_stack_new();
    self.pages = gtk.cast(gtk.Stack, pages);
    gtk.gtk_stack_set_transition_type(self.pages.?, gtk.STACK_TRANSITION_CROSSFADE);
    _ = gtk.gtk_stack_add_named(self.pages.?, albums.build(self), Page.albums.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, buildTracksPage(self), Page.tracks.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, nowplaying.build(self), Page.now_playing.name());
    _ = gtk.gtk_stack_add_named(self.pages.?, queue.build(self), Page.queue.name());

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
    adaptWhenNarrow(self, window, split);
    return window;
}
