const std = @import("std");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const details = @import("details.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const ratings = @import("ratings.zig");
const strings = @import("strings.zig");
const playlists = @import("playlists.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;
pub const Column = track_model.Column;

const loved_title = "Loved";

pub const Options = struct {
    multiple: bool,
    sortable: bool,
    playlist: bool = false,
};

const Cell = struct {
    table: *Table,
    column: Column,
};

pub const Table = struct {
    app: *App = undefined,
    store: ?*gtk.ListStore = null,
    selection: ?*gtk.SelectionModel = null,
    view: ?*gtk.ColumnView = null,
    playlist: bool = false,
    columns: [Column.all.len]?*gtk.ColumnViewColumn = @splat(null),
    cells: [Column.all.len]Cell = undefined,

    pub fn header(self: *const Table, column: Column) ?*gtk.ColumnViewColumn {
        return self.columns[@intFromEnum(column)];
    }
};

fn tableData(data: ?*anyopaque) *Table {
    return @ptrCast(@alignCast(data.?));
}

fn cellData(data: ?*anyopaque) *Cell {
    return @ptrCast(@alignCast(data.?));
}

fn rowOf(widget: *gtk.Widget) ?*TrackObject {
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    return @ptrCast(@alignCast(object));
}

fn target(row: *TrackObject) feedback.Target {
    return .{ .track_id = row.id(), .recording_id = row.recordingId(), .feedback = row.feedback() };
}

fn rowActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const table = tableData(data);
    const self = table.app;
    if (table.playlist) return playlists.playFrom(self, position);
    const selection = table.selection orelse return;
    const model = gtk.cast(gtk.ListModel, selection);
    const chosen = gtk.gtk_selection_model_get_selection(selection);

    // Activation is not selection. Activating a multi-row selection plays that
    // selection as a queue, from its first row: shift-click leaves GTK's
    // activated position on the last row selected.
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
            self.toast("None of the selected songs has a playable file");
        return;
    }
    gtk.gtk_bitset_unref(chosen);

    const item = gtk.g_list_model_get_item(model, position) orelse return;
    defer gtk.g_object_unref(item);
    const row: *TrackObject = @ptrCast(@alignCast(item));
    if (!row.hasFile()) {
        self.toast("That song has no playable file");
        return;
    }
    const id = row.id();
    transport.playIds(self, &.{id}, 0);
}

fn heartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = rowOf(gtk.cast(gtk.Widget, button.?)) orelse return;
    feedback.toggle(cellData(data).table.app, target(row));
}

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const stars = ratings.starsOf(button) orelse return;
    const row = rowOf(stars) orelse return;
    ratings.change(cellData(data).table.app, &.{target(row)}, ratings.chosen(button));
}

fn prepareMenu(table: *Table, widget: *gtk.Widget) bool {
    const self = table.app;
    const selection = table.selection orelse return false;
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return false;
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return false;
    const clicked: *TrackObject = @ptrCast(@alignCast(object));
    const position = gtk.gtk_list_item_get_position(list_item);
    if (gtk.gtk_selection_model_is_selected(selection, position) == 0)
        _ = gtk.gtk_selection_model_select_item(selection, position, gtk.true_);

    if (table.playlist) {
        self.context.reset(.playlist);
        self.context.playlist_id = self.playlists.open_id orelse return false;
        self.context.playlist_position = position;
        self.context.playlist_length = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, selection));
        if (clicked.inLibrary() and clicked.hasFile()) {
            self.context.addTrack(self.allocator, clicked.id(), clicked.recordingId(), clicked.feedback()) catch return false;
            self.context.release_id = clicked.releaseId();
            self.context.artist_id = clicked.artistId();
        }
        return true;
    }
    self.context.reset(.tracks);
    self.context.release_id = clicked.releaseId();
    self.context.artist_id = clicked.artistId();
    const chosen = gtk.gtk_selection_model_get_selection(selection);
    defer gtk.gtk_bitset_unref(chosen);
    const model = gtk.cast(gtk.ListModel, selection);
    var iter: gtk.BitsetIter = .{};
    var index: c_uint = 0;
    var valid = gtk.gtk_bitset_iter_init_first(&iter, chosen, &index);
    while (valid != 0) : (valid = gtk.gtk_bitset_iter_next(&iter, &index)) {
        const row_item = gtk.g_list_model_get_item(model, index) orelse continue;
        defer gtk.g_object_unref(row_item);
        const row: *TrackObject = @ptrCast(@alignCast(row_item));
        if (row.hasFile()) self.context.addTrack(self.allocator, row.id(), row.recordingId(), row.feedback()) catch {};
    }
    if (self.context.tracks.items.len > 1) {
        self.context.release_id = null;
        self.context.artist_id = null;
    }
    return true;
}

fn cellMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const table = cellData(data).table;
    const widget = menu.gestureWidget(gesture);
    if (prepareMenu(table, widget)) menu.popup(table.app, widget, x, y);
}

fn moreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const table = cellData(data).table;
    const widget = gtk.cast(gtk.Widget, button.?);
    if (!prepareMenu(table, widget)) return;
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popup(table.app, widget, x, y);
}

fn textLabel(numeric: bool) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), if (numeric) 1.0 else 0.0);
    if (numeric) gtk.gtk_widget_add_css_class(label, "numeric");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    return label;
}

fn setupCell(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cell = cellData(data);
    const child = switch (cell.column) {
        .number => number: {
            const stack = gtk.gtk_stack_new();
            const label = textLabel(true);
            gtk.gtk_widget_add_css_class(label, "song-number");
            const glyph = gtk.gtk_image_new_from_icon_name("media-playback-start-symbolic");
            gtk.gtk_widget_set_halign(glyph, gtk.ALIGN_END);
            gtk.gtk_widget_add_css_class(glyph, "album-track-playing");
            _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), label, "number");
            _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), glyph, "playing");
            break :number stack;
        },
        .title => title: {
            const label = textLabel(false);
            gtk.gtk_widget_add_css_class(label, "song-title");
            break :title label;
        },
        .artist, .album => textLabel(false),
        .duration => duration: {
            const label = textLabel(true);
            gtk.gtk_widget_add_css_class(label, "song-duration");
            break :duration label;
        },
        .loved => heart: {
            const button = feedback.newRowButton(gtk.callback(heartClicked), cell);
            gtk.gtk_widget_set_halign(button, gtk.ALIGN_CENTER);
            gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
            break :heart button;
        },
        .rating => stars: {
            const stars = ratings.newRowStars(gtk.callback(starClicked), cell);
            gtk.gtk_widget_set_halign(stars, gtk.ALIGN_START);
            break :stars stars;
        },
        .more => more: {
            const button = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
            gtk.gtk_widget_add_css_class(button, "flat");
            gtk.gtk_widget_add_css_class(button, "row-more");
            gtk.gtk_widget_set_halign(button, gtk.ALIGN_CENTER);
            gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
            gtk.gtk_widget_set_tooltip_text(button, "More");
            _ = gtk.signalConnect(button, "clicked", gtk.callback(moreClicked), cell);
            break :more button;
        },
    };
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), child);
    gtk.g_object_set_data(child, "orca-list-item", item);
    menu.onSecondaryClick(child, cellMenu, cell);
}

fn bindCell(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *TrackObject = @ptrCast(@alignCast(object));
    const child = gtk.gtk_list_item_get_child(list_item) orelse return;
    const cell = cellData(data);
    const playing = isPlaying(row);
    var buffer: [32]u8 = undefined;
    switch (cell.column) {
        .number => {
            const stack = gtk.cast(gtk.Stack, child);
            gtk.gtk_stack_set_visible_child_name(stack, if (playing) "playing" else "number");
            const label = gtk.gtk_stack_get_child_by_name(stack, "number") orelse return;
            const text = if (cell.table.playlist)
                strings.format(&buffer, "{d}", .{gtk.gtk_list_item_get_position(list_item) + 1})
            else
                row.numberText(&buffer);
            gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), text.ptr);
        },
        .title => gtk.gtk_label_set_text(gtk.cast(gtk.Label, child), row.title().ptr),
        .artist => gtk.gtk_label_set_text(gtk.cast(gtk.Label, child), row.artist().ptr),
        .album => gtk.gtk_label_set_text(gtk.cast(gtk.Label, child), row.album().ptr),
        .duration => gtk.gtk_label_set_text(gtk.cast(gtk.Label, child), row.durationText(&buffer).ptr),
        .loved => {
            feedback.showRowButton(child, row.feedback());
            gtk.gtk_widget_set_visible(child, if (row.inLibrary()) gtk.true_ else gtk.false_);
        },
        .rating => {
            ratings.show(child, row.rating());
            gtk.gtk_widget_set_visible(child, if (row.inLibrary()) gtk.true_ else gtk.false_);
        },
        .more => {},
    }
    // A Track whose file is missing is shown, not hidden — the library still
    // knows about it — but it is visibly not playable.
    if (row.hasFile())
        gtk.gtk_widget_remove_css_class(child, "dim-label")
    else
        gtk.gtk_widget_add_css_class(child, "dim-label");
    const row_widget = rowWidget(child) orelse return;
    if (playing)
        gtk.gtk_widget_add_css_class(row_widget, "playing")
    else
        gtk.gtk_widget_remove_css_class(row_widget, "playing");
}

fn hasCssName(widget: *gtk.Widget, name: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(gtk.gtk_widget_get_css_name(widget)), name);
}

fn rowWidget(child: *gtk.Widget) ?*gtk.Widget {
    const cell = gtk.gtk_widget_get_parent(child) orelse return null;
    if (!hasCssName(cell, "cell")) return null;
    const row = gtk.gtk_widget_get_parent(cell) orelse return null;
    if (!hasCssName(row, "row")) return null;
    return row;
}

var playing_id: ?i64 = null;

fn isPlaying(row: *TrackObject) bool {
    return row.inLibrary() and playing_id != null and playing_id.? == row.id();
}

/// Moves the playing mark, replacing only the rows that gain or lose it.
pub fn markPlaying(tables: []const *Table, track_id: ?i64) void {
    const previous = playing_id;
    playing_id = track_id;
    if (std.meta.eql(previous, track_id)) return;
    for (tables) |table| {
        const store = table.store orelse continue;
        const kept = keepSelection(table);
        defer restoreSelection(table, kept);
        const model = gtk.cast(gtk.ListModel, store);
        const count = gtk.g_list_model_get_n_items(model);
        var index: c_uint = 0;
        while (index < count) : (index += 1) {
            const item = gtk.g_list_model_get_item(model, index) orelse continue;
            defer gtk.g_object_unref(item);
            const row: *TrackObject = @ptrCast(@alignCast(item));
            if (!row.inLibrary()) continue;
            const was = previous != null and previous.? == row.id();
            const is = track_id != null and track_id.? == row.id();
            if (!was and !is) continue;
            const copy = track_model.clone(row) orelse continue;
            var replacement: [1]?*anyopaque = .{copy};
            gtk.g_list_store_splice(store, index, 1, &replacement, 1);
            gtk.g_object_unref(copy);
        }
    }
}

pub fn repaint(table: *Table, changed: *const feedback.Recordings, change: track_model.Change) void {
    const store = table.store orelse return;
    const kept = keepSelection(table);
    if (feedback.replaceRows(store, changed, change)) return restoreSelection(table, kept);
    if (kept) |selected| gtk.gtk_bitset_unref(selected);
}

fn keepSelection(table: *Table) ?*gtk.Bitset {
    const selection = table.selection orelse return null;
    const live = gtk.gtk_selection_model_get_selection(selection);
    defer gtk.gtk_bitset_unref(live);
    return gtk.gtk_bitset_copy(live);
}

fn restoreSelection(table: *Table, kept: ?*gtk.Bitset) void {
    const selected = kept orelse return;
    defer gtk.gtk_bitset_unref(selected);
    const selection = table.selection orelse return;
    const store = table.store orelse return;
    const everything = gtk.gtk_bitset_new_range(0, gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)));
    defer gtk.gtk_bitset_unref(everything);
    _ = gtk.gtk_selection_model_set_selection(selection, selected, everything);
}

pub fn firstSelected(selection: *gtk.SelectionModel) ?i64 {
    const chosen = gtk.gtk_selection_model_get_selection(selection);
    defer gtk.gtk_bitset_unref(chosen);
    var iter: gtk.BitsetIter = .{};
    var index: c_uint = 0;
    if (gtk.gtk_bitset_iter_init_first(&iter, chosen, &index) == 0) return null;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, selection), index) orelse return null;
    defer gtk.g_object_unref(item);
    const row: *TrackObject = @ptrCast(@alignCast(item));
    if (!row.inLibrary()) return null;
    return row.id();
}

pub fn playableIds(table: *Table, allocator: std.mem.Allocator) std.ArrayList(i64) {
    var ids: std.ArrayList(i64) = .empty;
    const store = table.store orelse return ids;
    const model = gtk.cast(gtk.ListModel, store);
    var index: c_uint = 0;
    while (index < gtk.g_list_model_get_n_items(model)) : (index += 1) {
        const item = gtk.g_list_model_get_item(model, index) orelse continue;
        const row: *TrackObject = @ptrCast(@alignCast(item));
        if (row.hasFile()) ids.append(allocator, row.id()) catch {};
        gtk.g_object_unref(item);
    }
    return ids;
}

fn findLabel(widget: *gtk.Widget) ?*gtk.Widget {
    var child = gtk.gtk_widget_get_first_child(widget);
    while (child) |current| : (child = gtk.gtk_widget_get_next_sibling(current)) {
        if (hasCssName(current, "label")) return current;
        if (findLabel(current)) |found| return found;
    }
    return null;
}

fn showHeartHeader(table: *Table) void {
    const view = gtk.cast(gtk.Widget, table.view orelse return);
    var part = gtk.gtk_widget_get_first_child(view);
    while (part) |header| : (part = gtk.gtk_widget_get_next_sibling(header)) {
        if (!hasCssName(header, "header")) continue;
        var title = gtk.gtk_widget_get_first_child(header);
        while (title) |button| : (title = gtk.gtk_widget_get_next_sibling(button)) {
            if (gtk.gtk_widget_has_css_class(button, "heart-header") != 0) continue;
            const label = findLabel(button) orelse continue;
            if (!std.mem.eql(u8, std.mem.span(gtk.gtk_label_get_text(gtk.cast(gtk.Label, label))), loved_title)) continue;
            const box = gtk.gtk_widget_get_parent(label) orelse continue;
            gtk.gtk_widget_add_css_class(button, "heart-header");
            gtk.gtk_widget_set_tooltip_text(button, loved_title);
            gtk.gtk_widget_set_visible(label, gtk.false_);
            gtk.gtk_box_prepend(gtk.cast(gtk.Box, box), gtk.gtk_image_new_from_icon_name(feedback.filled_icon));
        }
    }
}

fn headerRebuilt(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    showHeartHeader(tableData(data));
    return gtk.false_;
}

fn columnsChanged(_: ?*anyopaque, _: c_uint, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    _ = gtk.g_idle_add(headerRebuilt, data);
}

fn makeColumn(table: *Table, title: [*:0]const u8, column: Column, width: c_int, expand: bool, sortable: bool) *gtk.ColumnViewColumn {
    const cell = &table.cells[@intFromEnum(column)];
    cell.* = .{ .table = table, .column = column };
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupCell), cell);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindCell), cell);
    const result = gtk.gtk_column_view_column_new(title, factory);
    const fixed = column == .loved or column == .more;
    gtk.gtk_column_view_column_set_resizable(result, if (fixed) gtk.false_ else gtk.true_);
    gtk.gtk_column_view_column_set_expand(result, if (expand) gtk.true_ else gtk.false_);
    if (width > 0) gtk.gtk_column_view_column_set_fixed_width(result, width);
    if (sortable and column.sortKey() != null) {
        const sorter = track_model.headerSorter();
        gtk.gtk_column_view_column_set_sorter(result, sorter);
        gtk.g_object_unref(sorter);
    }
    return result;
}

pub fn build(table: *Table, self: *App, options: Options) *gtk.Widget {
    table.app = self;
    table.playlist = options.playlist;
    const store = gtk.g_list_store_new(track_model.getType()).?;
    table.store = store;
    const model = gtk.cast(gtk.ListModel, gtk.g_object_ref(store));
    table.selection = if (options.multiple) gtk.gtk_multi_selection_new(model) else single: {
        const single = gtk.gtk_single_selection_new(model);
        gtk.gtk_single_selection_set_autoselect(single, gtk.false_);
        gtk.gtk_single_selection_set_can_unselect(single, gtk.true_);
        break :single gtk.cast(gtk.SelectionModel, single);
    };
    const view = gtk.gtk_column_view_new(table.selection);
    table.view = gtk.cast(gtk.ColumnView, view);
    gtk.gtk_widget_add_css_class(view, "track-list");
    gtk.gtk_column_view_set_show_column_separators(table.view.?, gtk.false_);
    gtk.gtk_column_view_set_reorderable(table.view.?, gtk.true_);
    _ = gtk.signalConnect(view, "activate", gtk.callback(rowActivated), table);
    _ = gtk.signalConnect(table.selection.?, "selection-changed", gtk.callback(details.selectionChanged), self);

    const columns: [Column.all.len]*gtk.ColumnViewColumn = .{
        makeColumn(table, "#", .number, 56, false, options.sortable),
        makeColumn(table, "Title", .title, 220, true, options.sortable),
        makeColumn(table, "Artist", .artist, 160, true, options.sortable),
        makeColumn(table, "Album", .album, 160, true, options.sortable),
        makeColumn(table, loved_title, .loved, 44, false, options.sortable),
        makeColumn(table, "Rating", .rating, 104, false, options.sortable),
        makeColumn(table, "Duration", .duration, 80, false, options.sortable),
        makeColumn(table, "", .more, 40, false, options.sortable),
    };
    for (columns, 0..) |column, index| {
        gtk.gtk_column_view_append_column(table.view.?, column);
        table.columns[index] = column;
        gtk.g_object_unref(column);
    }
    showHeartHeader(table);
    _ = gtk.signalConnect(gtk.gtk_column_view_get_columns(table.view.?), "items-changed", gtk.callback(columnsChanged), table);
    return view;
}
