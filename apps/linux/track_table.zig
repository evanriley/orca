const std = @import("std");
const liborca = @import("liborca");
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
const settings = @import("settings.zig");
const signal_path = @import("signal_path.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;
pub const Column = track_model.Column;
pub const ColumnSet = std.EnumSet(Column);

const loved_title = "Loved";
const duration_title = "Duration";
const chooser_title = "Columns";

const fixed_columns = ColumnSet.initMany(&.{ .number, .title, .artist, .album, .loved, .rating, .duration, .more });
const default_track_columns = ColumnSet.initMany(&.{ .number, .title, .artist, .album, .loved, .date_added, .duration, .format, .more });
const always_shown = ColumnSet.initMany(&.{ .number, .title, .more });
const dropped_when_narrow = ColumnSet.initMany(&.{ .album, .rating, .date_added, .year, .last_played, .plays, .format, .codec, .bit_depth, .sample_rate });

/// What the column chooser offers, in its order.
const optional_columns = [_]Column{ .artist, .album, .loved, .rating, .date_added, .year, .last_played, .plays, .duration, .format, .codec, .bit_depth, .sample_rate };

/// The columns a configurable table shows and the widths they were dragged
/// to; `[view] track_columns` and `track_column_widths` keep them.
pub const Config = struct {
    columns: ColumnSet = default_track_columns,
    widths: [Column.all.len]c_int = @splat(0),
};

pub const Options = struct {
    multiple: bool,
    sortable: bool,
    playlist: bool = false,
    config: ?*Config = null,
    columns: ColumnSet = fixed_columns,
    duration_icon: bool = false,
    relative_dates: bool = false,
};

fn heading(column: Column) [*:0]const u8 {
    return switch (column) {
        .number => "#",
        .title => "Title",
        .artist => "Artist",
        .album => "Album",
        .loved => loved_title,
        .rating => "Rating",
        .date_added => "Date Added",
        .year => "Year",
        .last_played => "Last Played",
        .plays => "Plays",
        .duration => duration_title,
        .format => "Format",
        .codec => "Codec",
        .bit_depth => "Bit Depth",
        .sample_rate => "Sample Rate",
        .more => "",
    };
}

fn defaultWidth(column: Column) c_int {
    return switch (column) {
        .number => 48,
        .title => 220,
        .artist, .album => 160,
        .loved => 44,
        .rating => 116,
        .date_added, .last_played => 110,
        .year, .plays => 64,
        .duration => 80,
        .format => 130,
        .codec, .bit_depth => 80,
        .sample_rate => 100,
        .more => 40,
    };
}

fn narrowWidth(column: Column) ?c_int {
    return switch (column) {
        .title => 120,
        .artist => 90,
        else => null,
    };
}

fn isNumeric(column: Column) bool {
    return switch (column) {
        .number, .duration, .year, .plays, .bit_depth, .sample_rate => true,
        else => false,
    };
}

/// `artist,album,...` as settings keep it. Names it does not know are
/// skipped; the columns that are always shown are always in the result.
pub fn parseColumns(text: []const u8) ColumnSet {
    var result = always_shown;
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
    for (optional_columns) |column| {
        if (!columns.contains(column)) continue;
        writer.print("{s}{s}", .{ if (first) "" else ",", @tagName(column) }) catch return "";
        first = false;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

/// `title:240,artist:180`; a width outside 1 to 2000 is ignored.
pub fn parseWidths(text: []const u8, widths: *[Column.all.len]c_int) void {
    var pairs = std.mem.splitScalar(u8, text, ',');
    while (pairs.next()) |pair| {
        const split = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
        const column = std.meta.stringToEnum(Column, std.mem.trim(u8, pair[0..split], " ")) orelse continue;
        const width = std.fmt.parseInt(c_int, std.mem.trim(u8, pair[split + 1 ..], " "), 10) catch continue;
        if (width > 0 and width <= 2000) widths[@intFromEnum(column)] = width;
    }
}

pub fn formatWidths(buffer: []u8, widths: *const [Column.all.len]c_int) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var first = true;
    for (Column.all) |column| {
        const width = widths[@intFromEnum(column)];
        if (width <= 0) continue;
        writer.print("{s}{s}:{d}", .{ if (first) "" else ",", @tagName(column), width }) catch return "";
        first = false;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

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
    config: ?*Config = null,
    fixed: ColumnSet = fixed_columns,
    duration_icon: bool = false,
    relative_dates: bool = false,
    narrow: bool = false,
    /// Set while the table itself changes column widths, so they are not
    /// saved as though dragged.
    resizing: bool = false,
    /// Numbers the rows by their place in the listing instead of disc.track.
    positions: bool = false,
    sorted: ?Column = null,
    chooser: ?*gtk.GMenuModel = null,
    save_source: c_uint = 0,
    header_source: c_uint = 0,

    pub fn header(self: *const Table, column: Column) ?*gtk.ColumnViewColumn {
        return self.columns[@intFromEnum(column)];
    }

    fn chosen(self: *const Table) ColumnSet {
        const config = self.config orelse return self.fixed;
        return config.columns;
    }

    pub fn deinit(self: *Table) void {
        if (self.save_source != 0) {
            _ = gtk.g_source_remove(self.save_source);
            self.save_source = 0;
            settings.save(self.app);
        }
        if (self.chooser) |model| gtk.g_object_unref(model);
        self.chooser = null;
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
            gtk.gtk_widget_add_css_class(label, "track-number");
            const glyph = gtk.gtk_image_new_from_icon_name("media-playback-start-symbolic");
            gtk.gtk_widget_set_halign(glyph, gtk.ALIGN_END);
            gtk.gtk_widget_add_css_class(glyph, "album-track-playing");
            _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), label, "number");
            _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), glyph, "playing");
            break :number stack;
        },
        .title => title: {
            const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
            const label = textLabel(false);
            gtk.gtk_widget_add_css_class(label, "track-title");
            const badge = gtk.gtk_label_new("E");
            gtk.gtk_widget_add_css_class(badge, "explicit-badge");
            gtk.gtk_widget_set_valign(badge, gtk.ALIGN_CENTER);
            gtk.gtk_widget_set_tooltip_text(badge, "Explicit");
            gtk.gtk_box_append(gtk.cast(gtk.Box, box), label);
            gtk.gtk_box_append(gtk.cast(gtk.Box, box), badge);
            break :title box;
        },
        .duration => duration: {
            const label = textLabel(true);
            gtk.gtk_widget_add_css_class(label, "track-duration");
            break :duration label;
        },
        .format => format: {
            const label = textLabel(false);
            gtk.gtk_widget_add_css_class(label, "track-format");
            break :format label;
        },
        .artist, .album, .date_added, .year, .last_played, .plays, .codec, .bit_depth, .sample_rate => textLabel(isNumeric(cell.column)),
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
            const button = gtk.gtk_button_new_from_icon_name("view-more-horizontal-symbolic");
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

fn dateText(buffer: []u8, unix_seconds: ?i64) [:0]const u8 {
    const seconds = unix_seconds orelse return "";
    const moment = gtk.g_date_time_new_from_unix_local(seconds) orelse return "";
    defer gtk.g_date_time_unref(moment);
    const text = gtk.g_date_time_format(moment, "%Y-%m-%d") orelse return "";
    defer gtk.g_free(text);
    return strings.format(buffer, "{s}", .{std.mem.span(text)});
}

/// `FLAC · 44.1 kHz`, or only the codec when the rate is unknown.
fn formatText(buffer: []u8, values: *const track_model.Fields) [:0]const u8 {
    if (values.codec.len == 0) return "";
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeCodecName(&writer, values.codec) catch return "";
    if (values.sample_rate) |rate| {
        writer.writeAll(" · ") catch return "";
        signal_path.writeRate(&writer, rate) catch return "";
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn codecText(buffer: []u8, codec: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeCodecName(&writer, codec) catch return "";
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn rateText(buffer: []u8, hertz: ?u32) [:0]const u8 {
    const rate = hertz orelse return "";
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeRate(&writer, rate) catch return "";
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn momentText(buffer: []u8, unix_seconds: ?i64) [:0]const u8 {
    const seconds = unix_seconds orelse return "";
    const moment = gtk.g_date_time_new_from_unix_local(seconds) orelse return "";
    defer gtk.g_date_time_unref(moment);
    const text = gtk.g_date_time_format(moment, "%-d %B %Y, %R") orelse return "";
    defer gtk.g_free(text);
    return strings.format(buffer, "{s}", .{std.mem.span(text)});
}

fn setText(widget: *gtk.Widget, text: [:0]const u8) void {
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, widget), text.ptr);
}

fn bindCell(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *TrackObject = @ptrCast(@alignCast(object));
    const child = gtk.gtk_list_item_get_child(list_item) orelse return;
    const cell = cellData(data);
    const playing = isPlaying(row);
    const values = row.fields();
    var buffer: [64]u8 = undefined;
    switch (cell.column) {
        .number => {
            const stack = gtk.cast(gtk.Stack, child);
            gtk.gtk_stack_set_visible_child_name(stack, if (playing) "playing" else "number");
            const label = gtk.gtk_stack_get_child_by_name(stack, "number") orelse return;
            const text = if (cell.table.playlist or cell.table.positions)
                strings.format(&buffer, "{d}", .{gtk.gtk_list_item_get_position(list_item) + 1})
            else
                row.numberText(&buffer);
            setText(label, text);
        },
        .title => {
            const label = gtk.gtk_widget_get_first_child(child) orelse return;
            setText(label, row.title());
            const badge = gtk.gtk_widget_get_next_sibling(label) orelse return;
            gtk.gtk_widget_set_visible(badge, if (values.explicit) gtk.true_ else gtk.false_);
        },
        .artist => setText(child, row.artist()),
        .album => setText(child, row.album()),
        .duration => setText(child, row.durationText(&buffer)),
        .date_added => setText(child, dateText(&buffer, values.added_at)),
        .last_played => if (cell.table.relative_dates) {
            setText(child, if (values.last_played_at) |seconds| details.recentDayText(&buffer, seconds) else "");
            var tooltip_buffer: [64]u8 = undefined;
            const tooltip = momentText(&tooltip_buffer, values.last_played_at);
            gtk.gtk_widget_set_tooltip_text(child, if (tooltip.len != 0) tooltip.ptr else null);
        } else setText(child, dateText(&buffer, values.last_played_at)),
        .year => setText(child, if (values.year) |year| strings.format(&buffer, "{d}", .{year}) else ""),
        .plays => setText(child, if (values.play_count != 0) strings.format(&buffer, "{d}", .{values.play_count}) else ""),
        .format => setText(child, formatText(&buffer, values)),
        .codec => setText(child, codecText(&buffer, values.codec)),
        .bit_depth => setText(child, if (values.bit_depth) |bits| strings.format(&buffer, "{d}-bit", .{bits}) else ""),
        .sample_rate => setText(child, rateText(&buffer, values.sample_rate)),
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

pub fn refreshRelease(table: *Table, release_id: i64) void {
    const store = table.store orelse return;
    const self = table.app;
    const library = self.library orelse return;
    const kept = keepSelection(table);
    defer restoreSelection(table, kept);
    const model = gtk.cast(gtk.ListModel, store);
    const count = gtk.g_list_model_get_n_items(model);
    var index: c_uint = 0;
    while (index < count) : (index += 1) {
        const item = gtk.g_list_model_get_item(model, index) orelse continue;
        defer gtk.g_object_unref(item);
        const row: *TrackObject = @ptrCast(@alignCast(item));
        if (!row.inLibrary() or !std.meta.eql(row.releaseId(), release_id)) continue;
        const summary = (self.runtime.libraryTrackSummary(library, row.id()) catch null) orelse continue;
        defer summary.deinit(self.allocator);
        const fresh = track_model.new(summary) orelse continue;
        var replacement: [1]?*anyopaque = .{fresh};
        gtk.g_list_store_splice(store, index, 1, &replacement, 1);
        gtk.g_object_unref(fresh);
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

fn labelIs(label: *gtk.Widget, text: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(gtk.gtk_label_get_text(gtk.cast(gtk.Label, label))), std.mem.span(text));
}

fn headerRow(table: *Table) ?*gtk.Widget {
    const view = gtk.cast(gtk.Widget, table.view orelse return null);
    var part = gtk.gtk_widget_get_first_child(view);
    while (part) |child| : (part = gtk.gtk_widget_get_next_sibling(child)) {
        if (hasCssName(child, "header")) return child;
    }
    return null;
}

/// Swaps the Loved title for a heart, the Duration title for a clock where
/// the table asks for one and the Columns title for the chooser's button,
/// and marks the title of the column the rows are sorted by.
fn decorateHeader(table: *Table) void {
    const row = headerRow(table) orelse return;
    var title = gtk.gtk_widget_get_first_child(row);
    while (title) |button| : (title = gtk.gtk_widget_get_next_sibling(button)) {
        const label = findLabel(button) orelse continue;
        const sorted = if (table.sorted) |column| labelIs(label, heading(column)) else false;
        if (sorted)
            gtk.gtk_widget_add_css_class(button, "sorted")
        else
            gtk.gtk_widget_remove_css_class(button, "sorted");
        if (gtk.gtk_widget_has_css_class(button, "heart-header") != 0) continue;
        if (gtk.gtk_widget_has_css_class(button, "clock-header") != 0) continue;
        if (gtk.gtk_widget_has_css_class(button, "column-chooser") != 0) continue;
        const box = gtk.gtk_widget_get_parent(label) orelse continue;
        if (labelIs(label, loved_title)) {
            gtk.gtk_widget_add_css_class(button, "heart-header");
            gtk.gtk_widget_set_tooltip_text(button, loved_title);
            gtk.gtk_widget_set_visible(label, gtk.false_);
            gtk.gtk_box_prepend(gtk.cast(gtk.Box, box), gtk.gtk_image_new_from_icon_name(feedback.filled_icon));
        } else if (table.duration_icon and labelIs(label, duration_title)) {
            gtk.gtk_widget_add_css_class(button, "clock-header");
            gtk.gtk_widget_set_tooltip_text(button, duration_title);
            gtk.gtk_widget_set_visible(label, gtk.false_);
            const clock = gtk.gtk_image_new_from_icon_name("preferences-system-time-symbolic");
            gtk.gtk_widget_set_hexpand(clock, gtk.true_);
            gtk.gtk_widget_set_halign(clock, gtk.ALIGN_END);
            gtk.gtk_box_prepend(gtk.cast(gtk.Box, box), clock);
        } else if (table.config != null and labelIs(label, chooser_title)) {
            gtk.gtk_widget_add_css_class(button, "column-chooser");
            gtk.gtk_widget_set_tooltip_text(button, "Choose Columns");
            gtk.gtk_widget_set_visible(label, gtk.false_);
            gtk.gtk_box_prepend(gtk.cast(gtk.Box, box), gtk.gtk_image_new_from_icon_name("view-more-horizontal-symbolic"));
            const click = gtk.gtk_gesture_click_new();
            _ = gtk.signalConnect(click, "pressed", gtk.callback(chooserClicked), table);
            gtk.gtk_widget_add_controller(button, click);
        }
    }
}

fn headerRebuilt(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const table = tableData(data);
    table.header_source = 0;
    decorateHeader(table);
    return gtk.SOURCE_REMOVE;
}

fn columnsChanged(_: ?*anyopaque, _: c_uint, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const table = tableData(data);
    if (table.header_source == 0) table.header_source = gtk.g_idle_add(headerRebuilt, table);
}

fn viewDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const table = tableData(data);
    if (table.header_source != 0) _ = gtk.g_source_remove(table.header_source);
    table.header_source = 0;
    table.view = null;
}

/// Highlights the title of the column the rows are sorted by, if it is shown.
pub fn markSorted(table: *Table, sort: ?liborca.TrackSort) void {
    table.sorted = null;
    if (sort) |key| {
        for (Column.all) |column| {
            if (column.sortKey() == key and table.header(column) != null) table.sorted = column;
        }
    }
    decorateHeader(table);
}

fn columnWidth(table: *const Table, column: Column) c_int {
    if (table.narrow) if (narrowWidth(column)) |width| return width;
    if (column == .loved or column == .more) return defaultWidth(column);
    const saved = if (table.config) |config| config.widths[@intFromEnum(column)] else 0;
    return if (saved > 0) saved else defaultWidth(column);
}

fn applyVisibility(table: *Table) void {
    const shown = table.chosen();
    table.resizing = true;
    defer table.resizing = false;
    for (Column.all) |column| {
        const header = table.header(column) orelse continue;
        const visible = shown.contains(column) and !(table.narrow and dropped_when_narrow.contains(column));
        gtk.gtk_column_view_column_set_visible(header, if (visible) gtk.true_ else gtk.false_);
        if (narrowWidth(column) != null) gtk.gtk_column_view_column_set_fixed_width(header, columnWidth(table, column));
    }
}

/// Drops the columns a narrow window has no room for and narrows Title and
/// Artist, without forgetting which columns were chosen or their widths.
pub fn setNarrow(table: *Table, narrow: bool) void {
    table.narrow = narrow;
    applyVisibility(table);
}

fn chooserClicked(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const table = tableData(data);
    const model = table.chooser orelse return;
    const widget = menu.gestureWidget(gesture);
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popupModel(widget, model, x, y);
}

fn choiceActivated(action: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cell = cellData(data);
    const table = cell.table;
    const config = table.config orelse return;
    config.columns.toggle(cell.column);
    const shown = config.columns.contains(cell.column);
    gtk.g_simple_action_set_state(gtk.cast(gtk.GSimpleAction, action), gtk.g_variant_new_boolean(if (shown) gtk.true_ else gtk.false_));
    applyVisibility(table);
    markSorted(table, if (table.sorted) |column| column.sortKey() else null);
    settings.save(table.app);
}

fn buildChooser(table: *Table, view: *gtk.Widget) void {
    const config = table.config orelse return;
    const group = gtk.g_simple_action_group_new();
    defer gtk.g_object_unref(group);
    const items = gtk.g_menu_new();
    for (optional_columns) |column| {
        const shown = config.columns.contains(column);
        const action = gtk.g_simple_action_new_stateful(@tagName(column), null, gtk.g_variant_new_boolean(if (shown) gtk.true_ else gtk.false_)) orelse continue;
        _ = gtk.signalConnect(action, "activate", gtk.callback(choiceActivated), &table.cells[@intFromEnum(column)]);
        gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
        gtk.g_object_unref(action);
        var name: [48]u8 = undefined;
        gtk.g_menu_append(items, heading(column), strings.format(&name, "columns.{s}", .{@tagName(column)}).ptr);
    }
    gtk.gtk_widget_insert_action_group(view, "columns", gtk.cast(gtk.GActionGroup, group));
    table.chooser = gtk.cast(gtk.GMenuModel, items);
}

fn saveLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const table = tableData(data);
    table.save_source = 0;
    settings.save(table.app);
    return gtk.SOURCE_REMOVE;
}

fn widthChanged(header: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cell = cellData(data);
    const table = cell.table;
    const config = table.config orelse return;
    if (table.resizing or table.narrow) return;
    config.widths[@intFromEnum(cell.column)] = gtk.gtk_column_view_column_get_fixed_width(gtk.cast(gtk.ColumnViewColumn, header));
    if (table.save_source == 0) table.save_source = gtk.g_timeout_add(500, saveLater, table);
}

fn makeColumn(table: *Table, column: Column, sortable: bool) *gtk.ColumnViewColumn {
    const cell = &table.cells[@intFromEnum(column)];
    cell.* = .{ .table = table, .column = column };
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupCell), cell);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindCell), cell);
    const title = if (column == .more and table.config != null) chooser_title else heading(column);
    const result = gtk.gtk_column_view_column_new(title, factory);
    const fixed = column == .loved or column == .more;
    gtk.gtk_column_view_column_set_resizable(result, if (fixed) gtk.false_ else gtk.true_);
    const expand = column == .title or column == .artist or column == .album;
    gtk.gtk_column_view_column_set_expand(result, if (expand) gtk.true_ else gtk.false_);
    gtk.gtk_column_view_column_set_fixed_width(result, columnWidth(table, column));
    if (sortable and column.sortKey() != null) {
        const sorter = track_model.headerSorter();
        gtk.gtk_column_view_column_set_sorter(result, sorter);
        gtk.g_object_unref(sorter);
    }
    if (table.chooser) |model| gtk.gtk_column_view_column_set_header_menu(result, model);
    if (table.config != null and !fixed)
        _ = gtk.signalConnect(result, "notify::fixed-width", gtk.callback(widthChanged), cell);
    return result;
}

pub fn build(table: *Table, self: *App, options: Options) *gtk.Widget {
    table.app = self;
    table.playlist = options.playlist;
    table.config = options.config;
    table.fixed = options.columns;
    table.duration_icon = options.duration_icon;
    table.relative_dates = options.relative_dates;
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
    gtk.gtk_column_view_set_tab_behavior(table.view.?, gtk.LIST_TAB_ITEM);
    _ = gtk.signalConnect(view, "activate", gtk.callback(rowActivated), table);
    _ = gtk.signalConnect(table.selection.?, "selection-changed", gtk.callback(details.selectionChanged), self);
    buildChooser(table, view);

    for (Column.all) |column| {
        if (table.config == null and !table.fixed.contains(column)) continue;
        const header = makeColumn(table, column, options.sortable);
        gtk.gtk_column_view_append_column(table.view.?, header);
        table.columns[@intFromEnum(column)] = header;
        gtk.g_object_unref(header);
    }
    applyVisibility(table);
    decorateHeader(table);
    _ = gtk.signalConnect(gtk.gtk_column_view_get_columns(table.view.?), "items-changed", gtk.callback(columnsChanged), table);
    _ = gtk.signalConnect(view, "destroy", gtk.callback(viewDestroyed), table);
    return view;
}
