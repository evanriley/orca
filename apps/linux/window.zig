//! The main window: header bar, the virtualized track list, the status row and
//! the queue popover.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const scan = @import("scan.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const browse = @import("browse.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;
const Column = track_model.Column;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn columnData(column: Column) ?*anyopaque {
    return @ptrFromInt(@backingInt(column));
}

fn columnOf(data: ?*anyopaque) Column {
    return @fromBackingInt(@intCast(@intFromPtr(data)));
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
            self.setStatus("None of the selected tracks has a playable file");
        return;
    }
    gtk.gtk_bitset_unref(chosen);

    const item = gtk.g_list_model_get_item(model, position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *TrackObject = @ptrCast(@alignCast(item));
    if (!row.hasFile()) {
        self.setStatus("That track has no playable file");
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

fn addFolderClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    scan.chooseFolder(state(data));
}

fn setupQueueRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), label);
}

fn bindQueueRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const child = gtk.gtk_list_item_get_child(list_item) orelse return;
    gtk.gtk_label_set_text(
        gtk.cast(gtk.Label, child),
        gtk.gtk_string_object_get_string(gtk.cast(gtk.StringObject, object)),
    );
}

/// Returns true only when it actually consumed the key. Reached in the bubble
/// phase, so the focused widget has already declined it — which is what lets a
/// space typed into the search entry stay a space. A bare `space` application
/// accelerator would be matched before the focused widget and would eat it.
fn windowKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    if (keyval != gtk.KEY_space) return gtk.false_;
    const blocking = gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT;
    if (modifiers & blocking != 0) return gtk.false_;
    transport.toggle(state(data));
    return gtk.true_;
}

pub fn build(self: *App, application: *gtk.Application) *gtk.Widget {
    const window = gtk.gtk_application_window_new(application);
    self.window = gtk.cast(gtk.Window, window);

    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_BUBBLE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(windowKeyPressed), self);
    gtk.gtk_widget_add_controller(window, keys);
    gtk.gtk_window_set_title(self.window.?, "Orca");
    gtk.gtk_window_set_default_size(self.window.?, 1100, 720);

    const header = gtk.gtk_header_bar_new();
    const add_folder = gtk.gtk_button_new_with_label("Add Music Folder…");
    gtk.gtk_widget_set_tooltip_text(
        add_folder,
        "Register a folder as a library root and scan it",
    );
    _ = gtk.signalConnect(add_folder, "clicked", gtk.callback(addFolderClicked), self);
    gtk.gtk_header_bar_pack_start(gtk.cast(gtk.HeaderBar, header), add_folder);

    const search = gtk.gtk_search_entry_new();
    self.search_entry = gtk.cast(gtk.Editable, search);
    gtk.gtk_widget_set_size_request(search, 320, -1);
    gtk.gtk_widget_set_tooltip_text(search, "Search the library");
    _ = gtk.signalConnect(search, "search-changed", gtk.callback(searchChanged), self);
    gtk.gtk_header_bar_set_title_widget(gtk.cast(gtk.HeaderBar, header), search);

    // Queue pane: a popover over the Player's queue page.
    self.queue_rows = gtk.gtk_string_list_new(null);
    const queue_button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, queue_button), "view-list-symbolic");
    gtk.gtk_widget_set_tooltip_text(queue_button, "Play queue");
    const queue_factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(queue_factory, "setup", gtk.callback(setupQueueRow), null);
    _ = gtk.signalConnect(queue_factory, "bind", gtk.callback(bindQueueRow), null);
    const queue_list = gtk.gtk_list_view_new(
        gtk.gtk_no_selection_new(gtk.cast(
            gtk.ListModel,
            gtk.g_object_ref(self.queue_rows),
        )),
        queue_factory,
    );
    const queue_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_size_request(queue_scroller, 340, 360);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, queue_scroller), queue_list);
    self.queue_popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, self.queue_popover.?), queue_scroller);
    _ = gtk.signalConnect(self.queue_popover, "show", gtk.callback(queueShown), self);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, queue_button), self.queue_popover);
    gtk.gtk_header_bar_pack_end(gtk.cast(gtk.HeaderBar, header), queue_button);

    // Output device.
    self.device_names = gtk.gtk_string_list_new(null);
    const drop_down = gtk.gtk_drop_down_new(
        gtk.cast(gtk.ListModel, gtk.g_object_ref(self.device_names)),
        null,
    );
    self.device_drop_down = gtk.cast(gtk.DropDown, drop_down);
    gtk.gtk_widget_set_tooltip_text(drop_down, "Output device");
    gtk.gtk_header_bar_pack_end(gtk.cast(gtk.HeaderBar, header), drop_down);
    gtk.gtk_window_set_titlebar(self.window.?, header);

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
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(scrolled),
        self,
    );

    // Browser beside listing: the panes scope what the track list asks liborca
    // for, and the divider is the user's to move.
    const split = gtk.gtk_paned_new(gtk.ORIENTATION_HORIZONTAL);
    gtk.gtk_paned_set_start_child(gtk.cast(gtk.Paned, split), browse.build(self));
    gtk.gtk_paned_set_end_child(gtk.cast(gtk.Paned, split), scroller);
    gtk.gtk_paned_set_position(gtk.cast(gtk.Paned, split), 300);
    gtk.gtk_paned_set_resize_start_child(gtk.cast(gtk.Paned, split), gtk.false_);
    gtk.gtk_paned_set_shrink_start_child(gtk.cast(gtk.Paned, split), gtk.false_);
    gtk.gtk_paned_set_shrink_end_child(gtk.cast(gtk.Paned, split), gtk.false_);
    gtk.gtk_widget_set_vexpand(split, gtk.true_);

    const layout = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, layout), split);
    gtk.gtk_box_append(gtk.cast(gtk.Box, layout), scan.build(self));

    const status_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_margin_start(status_row, 12);
    gtk.gtk_widget_set_margin_end(status_row, 12);
    gtk.gtk_widget_set_margin_top(status_row, 4);
    gtk.gtk_widget_set_margin_bottom(status_row, 4);
    const status_label = gtk.gtk_label_new("");
    self.status_label = gtk.cast(gtk.Label, status_label);
    gtk.gtk_label_set_xalign(self.status_label.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.status_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_hexpand(status_label, gtk.true_);
    gtk.gtk_widget_add_css_class(status_label, "dim-label");
    const count_label = gtk.gtk_label_new("");
    self.count_label = gtk.cast(gtk.Label, count_label);
    gtk.gtk_widget_add_css_class(count_label, "dim-label");
    gtk.gtk_box_append(gtk.cast(gtk.Box, status_row), status_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, status_row), count_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, layout), status_row);

    gtk.gtk_box_append(
        gtk.cast(gtk.Box, layout),
        gtk.gtk_separator_new(gtk.ORIENTATION_HORIZONTAL),
    );
    gtk.gtk_box_append(gtk.cast(gtk.Box, layout), transport.build(self));
    gtk.gtk_window_set_child(self.window.?, layout);
    return window;
}

// ---------------------------------------------------------------- queue pane

fn queueShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const rows = self.queue_rows orelse return;
    gtk.gtk_string_list_splice(
        rows,
        0,
        gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, rows)),
        null,
    );
    const status = self.runtime.playerStatus(self.player) catch {
        gtk.gtk_string_list_append(rows, "The queue is empty");
        return;
    };
    // The engine resolves the queue's rows. This used to search the loaded
    // track model for each entry and print "Track 14732" when it missed --
    // metadata resolution in the frontend, and a linear scan of every loaded
    // row per queue entry, which on a fully scrolled library was over a
    // million iterations with a ref/unref each.
    var page = self.runtime.playerQueueTracks(
        self.player,
        self.allocator,
        0,
        app.page_size,
    ) catch {
        gtk.gtk_string_list_append(rows, "The queue is empty");
        return;
    };
    defer page.deinit();
    if (page.items.len == 0) {
        gtk.gtk_string_list_append(rows, "The queue is empty");
        return;
    }
    var buffer: [640]u8 = undefined;
    for (page.items, 0..) |entry, index| {
        const position: u32 = @intCast(index);
        const marker: []const u8 = if (position == status.queue_index) "▶ " else "";
        const line = if (entry.artist.len == 0)
            strings.printZ(&buffer, "{s}{d}. {s}", .{
                marker,
                position + 1,
                entry.title,
            }) catch continue
        else
            strings.printZ(&buffer, "{s}{d}. {s} — {s}", .{
                marker,
                position + 1,
                entry.title,
                entry.artist,
            }) catch continue;
        gtk.gtk_string_list_append(rows, line.ptr);
    }
}
