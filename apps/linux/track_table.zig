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
const duration_title = "Time";
const more_icon = "orca-more-symbolic";
const playing_icon = "orca-play-symbolic";
const row_star_pixels: c_int = 11;
const chooser_max_height: c_int = 480;

const fixed_columns = ColumnSet.initMany(&.{ .number, .title, .artist, .album, .loved, .rating, .duration, .more });
const default_track_columns = ColumnSet.initMany(&.{ .number, .title, .artist, .album, .loved, .rating, .date_added, .duration, .format, .more });
const large_track_columns = ColumnSet.initMany(&.{ .number, .title, .artist, .album, .codec, .rate_depth, .duration, .more });
const large_choices = ColumnSet.initMany(&.{ .title, .artist, .album, .codec, .rate_depth, .duration, .album_artist, .year, .genre, .bitrate, .plays, .rating, .loudness, .date_added, .path });
const always_shown = ColumnSet.initMany(&.{ .number, .title, .more });
const dropped_when_narrow = ColumnSet.initMany(&.{ .album, .rating, .date_added, .year, .last_played, .plays, .format, .codec, .rate_depth, .album_artist, .genre, .bitrate, .loudness, .path });

const column_count = Column.all.len;
const small_order: [column_count]Column = Column.all[0..column_count].*;
const large_order = [column_count]Column{
    .number,       .title, .artist, .album,       .codec,  .rate_depth, .duration,
    .album_artist, .year,  .genre,  .bitrate,     .plays,  .rating,     .loudness,
    .date_added,   .path,  .loved,  .last_played, .format, .more,
};

/// The Tracks page keeps one set of columns for a library of ordinary size
/// and another for a large one, each with its own defaults.
pub const View = enum { small, large };

/// The columns a configurable table shows, their order and the widths they
/// were dragged to; `[view] track_columns` and `track_column_widths` keep
/// them, with a `_large` suffix for the large view. `order` always starts with
/// the number and ends with the more button.
pub const Config = struct {
    view: View = .small,
    columns: ColumnSet = default_track_columns,
    order: [column_count]Column = small_order,
    widths: [column_count]c_int = @splat(0),

    pub fn initial(view: View) Config {
        return switch (view) {
            .small => .{},
            .large => .{ .view = .large, .columns = large_track_columns, .order = large_order },
        };
    }
};

pub const Options = struct {
    multiple: bool,
    sortable: bool,
    /// Rows come from a `PagedModel` the caller fills, not from `store`.
    paged: bool = false,
    playlist: bool = false,
    config: ?*Config = null,
    columns: ColumnSet = fixed_columns,
    duration_icon: bool = false,
    relative_dates: bool = false,
    title_heart: bool = false,
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
        .rate_depth => "Rate / Depth",
        .album_artist => "Album Artist",
        .genre => "Genre",
        .bitrate => "Bitrate",
        .loudness => "Loudness",
        .path => "File Path",
        .more => "",
    };
}

fn choiceLabel(column: Column) [*:0]const u8 {
    return switch (column) {
        .date_added => "Date added",
        .last_played => "Last played",
        .rate_depth => "Rate / depth",
        .album_artist => "Album artist",
        .loudness => "Loudness (LUFS)",
        .path => "File path",
        else => heading(column),
    };
}

fn defaultWidth(column: Column, view: View) c_int {
    return switch (column) {
        .number => if (view == .large) 76 else 52,
        .title => 220,
        .artist, .album, .album_artist => 160,
        .loved => 32,
        .rating => 116,
        .date_added, .last_played => 110,
        .year, .plays => 64,
        .duration => 80,
        .format => 130,
        .codec, .bitrate => 80,
        .rate_depth => 130,
        .genre => 120,
        .loudness => 90,
        .path => 280,
        .more => 36,
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
        .number, .duration, .year, .plays, .bitrate, .loudness => true,
        else => false,
    };
}

fn choosable(column: Column) bool {
    return column != .number and column != .more;
}

fn columnNamed(name: []const u8) ?Column {
    if (std.mem.eql(u8, name, "bit_depth") or std.mem.eql(u8, name, "sample_rate")) return .rate_depth;
    return std.meta.stringToEnum(Column, name);
}

/// `title,artist,-year,...` as settings keep it: every column in its order, a
/// hidden one marked with `-`. A list of only the shown columns, as earlier
/// versions wrote, also reads. Names it does not know are skipped, columns it
/// does not name keep `config`'s order after the ones it does and are
/// hidden, and the columns that are always shown are always shown.
pub fn parseColumns(text: []const u8, config: *Config) void {
    var named: [column_count]Column = undefined;
    var count: usize = 0;
    var placed = ColumnSet.initMany(&.{ .number, .more });
    var shown = always_shown;
    var names = std.mem.splitScalar(u8, text, ',');
    while (names.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " ");
        const hidden = std.mem.startsWith(u8, trimmed, "-");
        const column = columnNamed(if (hidden) trimmed[1..] else trimmed) orelse continue;
        if (placed.contains(column)) continue;
        placed.insert(column);
        named[count] = column;
        count += 1;
        if (!hidden) shown.insert(column);
    }
    var order: [column_count]Column = undefined;
    var length: usize = 0;
    order[0] = .number;
    length = 1;
    if (!placed.contains(.title)) {
        order[length] = .title;
        length += 1;
        placed.insert(.title);
    }
    for (named[0..count]) |column| {
        order[length] = column;
        length += 1;
    }
    for (config.order) |column| {
        if (placed.contains(column)) continue;
        order[length] = column;
        length += 1;
    }
    order[length] = .more;
    length += 1;
    std.debug.assert(length == column_count);
    config.order = order;
    config.columns = shown;
}

pub fn formatColumns(buffer: []u8, config: *const Config) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var first = true;
    for (config.order) |column| {
        if (!choosable(column)) continue;
        const hidden = !config.columns.contains(column);
        writer.print("{s}{s}{s}", .{ if (first) "" else ",", if (hidden) "-" else "", @tagName(column) }) catch return "";
        first = false;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

/// Moves `from` to where `to` is, shifting the columns between them.
fn moveColumn(config: *Config, from: Column, to: Column) bool {
    const source = std.mem.indexOfScalar(Column, &config.order, from) orelse return false;
    const destination = std.mem.indexOfScalar(Column, &config.order, to) orelse return false;
    if (source == destination or !choosable(from) or !choosable(to)) return false;
    if (source < destination) {
        std.mem.copyForwards(Column, config.order[source..destination], config.order[source + 1 .. destination + 1]);
    } else {
        std.mem.copyBackwards(Column, config.order[destination + 1 .. source + 1], config.order[destination..source]);
    }
    config.order[destination] = from;
    return true;
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
    paged: ?*track_model.PagedModel = null,
    selection: ?*gtk.SelectionModel = null,
    view: ?*gtk.ColumnView = null,
    playlist: bool = false,
    columns: [Column.all.len]?*gtk.ColumnViewColumn = @splat(null),
    cells: [Column.all.len]Cell = undefined,
    config: ?*Config = null,
    fixed: ColumnSet = fixed_columns,
    duration_icon: bool = false,
    relative_dates: bool = false,
    title_heart: bool = false,
    narrow: bool = false,
    /// Set while the table itself changes column widths, so they are not
    /// saved as though dragged.
    resizing: bool = false,
    /// Numbers the rows by their place in the listing instead of disc.track.
    positions: bool = false,
    sorted: ?Column = null,
    chooser: ?*gtk.GMenuModel = null,
    chooser_actions: ?*gtk.GActionGroup = null,
    /// The column chooser's list while its popover is shown.
    chooser_list: ?*gtk.ListBox = null,
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
        if (self.chooser_actions) |group| gtk.g_object_unref(group);
        self.chooser_actions = null;
    }

    pub fn listModel(self: *const Table) ?*gtk.ListModel {
        if (self.paged) |paged| return gtk.cast(gtk.ListModel, paged);
        return gtk.cast(gtk.ListModel, self.store orelse return null);
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
    const row: *TrackObject = @ptrCast(@alignCast(object));
    return if (track_model.isPlaceholder(row)) null else row;
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
    if (track_model.isPlaceholder(row)) return;
    if (!row.hasFile()) {
        self.toast("That track has no playable file");
        return;
    }
    if (table == &self.tracks) return playFrom(table, position);
    transport.playIds(self, &.{row.id()}, 0);
}

/// Plays the listing from the activated row through as many of the rows
/// after it as a queue holds. The rows are the engine's query from that
/// row's place in the listing, so a row far below the loaded pages plays
/// what follows it, not what happens to be cached.
fn playFrom(table: *Table, position: c_uint) void {
    var ids = queryPlayableIds(table, position) orelse return;
    defer ids.deinit(table.app.allocator);
    if (ids.items.len == 0) return table.app.toast("That track has no playable file");
    transport.playIds(table.app, ids.items, 0);
}

fn queryPlayableIds(table: *Table, position: c_uint) ?std.ArrayList(i64) {
    const self = table.app;
    const library = self.library orelse return null;
    var request = self.trackRequest(position);
    request.limit = liborca.playback_queue_capacity;
    const ids = self.runtime.libraryTrackQueryPlayableIds(library, self.allocator, self.query.value, request) catch {
        self.toast("Unable to query the library");
        return null;
    };
    return .fromOwnedSlice(ids);
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
    if (track_model.isPlaceholder(clicked)) return false;
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
    if (table.playlist)
        menu.popup(table.app, widget, x, y)
    else
        menu.popupRowActions(table.app, widget, x, y);
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
            const label = textLabel(false);
            gtk.gtk_widget_add_css_class(label, "numeric");
            gtk.gtk_widget_add_css_class(label, "track-number");
            const glyph = gtk.gtk_image_new_from_icon_name(playing_icon);
            gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, glyph), 12);
            gtk.gtk_widget_set_halign(glyph, gtk.ALIGN_START);
            gtk.gtk_widget_add_css_class(glyph, "album-track-playing");
            gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, glyph), gtk.ACCESSIBLE_PROPERTY_LABEL, "Now playing", @as(c_int, -1));
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
            if (cell.table.title_heart) {
                const heart = feedback.newRowButton(gtk.callback(heartClicked), cell);
                gtk.gtk_widget_add_css_class(heart, "title-heart");
                gtk.g_object_set_data(heart, "orca-list-item", item);
                gtk.gtk_box_append(gtk.cast(gtk.Box, box), heart);
            }
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
        .artist, .album, .date_added, .year, .last_played, .plays, .codec, .rate_depth, .album_artist, .genre, .bitrate, .loudness, .path => secondary: {
            const label = textLabel(isNumeric(cell.column));
            gtk.gtk_widget_add_css_class(label, "track-secondary");
            switch (cell.column) {
                .codec, .rate_depth, .bitrate, .loudness => gtk.gtk_widget_add_css_class(label, "track-tech"),
                else => {},
            }
            break :secondary label;
        },
        .loved => heart: {
            const button = feedback.newRowButton(gtk.callback(heartClicked), cell);
            gtk.gtk_widget_set_halign(button, gtk.ALIGN_CENTER);
            gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
            break :heart button;
        },
        .rating => stars: {
            const stars = ratings.newRowStars(gtk.callback(starClicked), cell);
            ratings.setStarSize(stars, row_star_pixels);
            gtk.gtk_widget_set_halign(stars, gtk.ALIGN_START);
            break :stars stars;
        },
        .more => more: {
            const button = gtk.gtk_button_new_from_icon_name(more_icon);
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

/// `96 kHz · 24-bit`, or whichever half is known.
fn rateDepthText(buffer: []u8, values: *const track_model.Fields) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (values.sample_rate) |rate| signal_path.writeRate(&writer, rate) catch return "";
    if (values.bit_depth) |bits| {
        if (values.sample_rate != null) writer.writeAll(" · ") catch return "";
        writer.print("{d}-bit", .{bits}) catch return "";
    }
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
            const text = if (cell.table.paged != null and cell.table.positions)
                strings.format(&buffer, "{f}", .{strings.grouped(gtk.gtk_list_item_get_position(list_item) + 1)})
            else if (cell.table.playlist or cell.table.positions)
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
            if (gtk.gtk_widget_get_next_sibling(badge)) |heart| {
                feedback.showRowButton(heart, row.feedback());
                gtk.gtk_widget_set_visible(heart, if (row.inLibrary()) gtk.true_ else gtk.false_);
            }
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
        .rate_depth => setText(child, rateDepthText(&buffer, values)),
        .album_artist => setText(child, values.album_artist),
        .genre => setText(child, values.genre),
        .bitrate => setText(child, if (values.bitrate_kbps) |rate| strings.format(&buffer, "{d} kbps", .{rate}) else ""),
        .loudness => setText(child, if (values.loudness) |lufs| strings.format(&buffer, "{d:.1} LUFS", .{lufs}) else ""),
        .path => {
            setText(child, values.path);
            gtk.gtk_widget_set_tooltip_text(child, if (values.path.len != 0) values.path.ptr else null);
        },
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

/// Offers each row to `replace` and puts the row it returns in its place,
/// keeping the selection. A paged table offers only the rows it has cached:
/// the others are fetched fresh when they are next shown.
fn replaceRows(
    table: *Table,
    context: anytype,
    comptime replace: fn (@TypeOf(context), *TrackObject) ?*TrackObject,
) void {
    const kept = keepSelection(table);
    var replaced = false;
    if (table.paged) |paged| {
        replaced = paged.update(context, replace);
    } else if (table.store) |store| {
        const model = gtk.cast(gtk.ListModel, store);
        const count = gtk.g_list_model_get_n_items(model);
        var index: c_uint = 0;
        while (index < count) : (index += 1) {
            const item = gtk.g_list_model_get_item(model, index) orelse continue;
            defer gtk.g_object_unref(item);
            const fresh = replace(context, @ptrCast(@alignCast(item))) orelse continue;
            var replacement: [1]?*anyopaque = .{fresh};
            gtk.g_list_store_splice(store, index, 1, &replacement, 1);
            gtk.g_object_unref(fresh);
            replaced = true;
        }
    }
    if (replaced) return restoreSelection(table, kept);
    if (kept) |selected| gtk.gtk_bitset_unref(selected);
}

const PlayingChange = struct { previous: ?i64, current: ?i64 };

fn playingRow(change: PlayingChange, row: *TrackObject) ?*TrackObject {
    if (!row.inLibrary()) return null;
    const was = change.previous != null and change.previous.? == row.id();
    const is = change.current != null and change.current.? == row.id();
    if (!was and !is) return null;
    return track_model.clone(row);
}

/// Moves the playing mark, replacing only the rows that gain or lose it.
pub fn markPlaying(tables: []const *Table, track_id: ?i64) void {
    const previous = playing_id;
    playing_id = track_id;
    if (std.meta.eql(previous, track_id)) return;
    for (tables) |table| replaceRows(table, PlayingChange{ .previous = previous, .current = track_id }, playingRow);
}

const ReleaseChange = struct { app: *App, library: liborca.LibraryHandle, release_id: i64 };

fn releaseRow(change: ReleaseChange, row: *TrackObject) ?*TrackObject {
    if (!row.inLibrary() or !std.meta.eql(row.releaseId(), change.release_id)) return null;
    const self = change.app;
    const summary = (self.runtime.libraryTrackSummary(change.library, row.id()) catch null) orelse return null;
    defer summary.deinit(self.allocator);
    return track_model.new(summary);
}

pub fn refreshRelease(table: *Table, release_id: i64) void {
    const self = table.app;
    const library = self.library orelse return;
    replaceRows(table, ReleaseChange{ .app = self, .library = library, .release_id = release_id }, releaseRow);
}

const FeedbackChange = struct { changed: *const feedback.Recordings, change: track_model.Change };

fn feedbackRow(context: FeedbackChange, row: *TrackObject) ?*TrackObject {
    const recording = row.recordingId() orelse return null;
    if (!context.changed.contains(recording)) return null;
    var probe = row.fields().*;
    if (!context.change.apply(&probe)) return null;
    const copy = track_model.clone(row) orelse return null;
    _ = context.change.apply(copy.fields());
    return copy;
}

pub fn repaint(table: *Table, changed: *const feedback.Recordings, change: track_model.Change) void {
    replaceRows(table, FeedbackChange{ .changed = changed, .change = change }, feedbackRow);
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
    const model = table.listModel() orelse return;
    const everything = gtk.gtk_bitset_new_range(0, gtk.g_list_model_get_n_items(model));
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
    if (table.paged != null) return queryPlayableIds(table, 0) orelse .empty;
    var ids: std.ArrayList(i64) = .empty;
    const model = table.listModel() orelse return ids;
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

/// Swaps the Loved title for a heart and the Time title for a clock where the
/// table asks for one, aligns the Time title with its column, and marks the
/// title of the column the rows are sorted by.
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
        const box = gtk.gtk_widget_get_parent(label) orelse continue;
        if (labelIs(label, loved_title)) {
            gtk.gtk_widget_add_css_class(button, "heart-header");
            gtk.gtk_widget_set_tooltip_text(button, loved_title);
            gtk.gtk_widget_set_visible(label, gtk.false_);
            const heart = gtk.gtk_image_new_from_icon_name(feedback.outline_icon);
            gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, heart), 14);
            gtk.gtk_box_prepend(gtk.cast(gtk.Box, box), heart);
        } else if (table.duration_icon and labelIs(label, duration_title)) {
            gtk.gtk_widget_add_css_class(button, "clock-header");
            gtk.gtk_widget_set_tooltip_text(button, "Duration");
            gtk.gtk_widget_set_visible(label, gtk.false_);
            const clock = gtk.gtk_image_new_from_icon_name("preferences-system-time-symbolic");
            gtk.gtk_widget_set_hexpand(clock, gtk.true_);
            gtk.gtk_widget_set_halign(clock, gtk.ALIGN_END);
            gtk.gtk_box_prepend(gtk.cast(gtk.Box, box), clock);
        } else if (labelIs(label, duration_title)) {
            gtk.gtk_widget_set_hexpand(label, gtk.true_);
            gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 1.0);
        }
    }
}

fn headerRebuilt(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const table = tableData(data);
    table.header_source = 0;
    if (takeHeaderOrder(table)) {
        refillChooser(table);
        settings.save(table.app);
    }
    decorateHeader(table);
    return gtk.SOURCE_REMOVE;
}

fn columnOf(table: *const Table, header: *gtk.ColumnViewColumn) ?Column {
    for (Column.all) |column| {
        if (table.header(column) == header) return column;
    }
    return null;
}

/// Keeps the order columns were dragged to in the header, with the number
/// first and the more button last whatever was dragged past them.
fn takeHeaderOrder(table: *Table) bool {
    const config = table.config orelse return false;
    const view = table.view orelse return false;
    const list = gtk.gtk_column_view_get_columns(view);
    var order: [column_count]Column = undefined;
    order[0] = .number;
    var length: usize = 1;
    var index: c_uint = 0;
    while (index < gtk.g_list_model_get_n_items(list)) : (index += 1) {
        const item = gtk.g_list_model_get_item(list, index) orelse continue;
        defer gtk.g_object_unref(item);
        const column = columnOf(table, @ptrCast(@alignCast(item))) orelse continue;
        if (!choosable(column) or length >= column_count - 1) continue;
        order[length] = column;
        length += 1;
    }
    if (length != column_count - 1) return false;
    order[length] = .more;
    if (std.mem.eql(Column, &order, &config.order)) return false;
    config.order = order;
    applyOrder(table);
    return true;
}

/// Puts the header's columns in `config`'s order.
fn applyOrder(table: *Table) void {
    const config = table.config orelse return;
    const view = table.view orelse return;
    const list = gtk.gtk_column_view_get_columns(view);
    var position: c_uint = 0;
    for (config.order) |column| {
        const header = table.header(column) orelse continue;
        const item = gtk.g_list_model_get_item(list, position);
        const placed = item != null and @as(?*gtk.ColumnViewColumn, @ptrCast(@alignCast(item))) == header;
        if (item) |object| gtk.g_object_unref(object);
        if (!placed) gtk.gtk_column_view_insert_column(view, position, header);
        position += 1;
    }
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
    const view: View = if (table.config) |config| config.view else .small;
    if (table.narrow) if (narrowWidth(column)) |width| return width;
    if (column == .loved or column == .more) return defaultWidth(column, view);
    const saved = if (table.config) |config| config.widths[@intFromEnum(column)] else 0;
    return if (saved > 0) saved else defaultWidth(column, view);
}

fn applyVisibility(table: *Table) void {
    const shown = table.chosen();
    table.resizing = true;
    defer table.resizing = false;
    for (Column.all) |column| {
        const header = table.header(column) orelse continue;
        const visible = shown.contains(column) and !(table.narrow and dropped_when_narrow.contains(column));
        gtk.gtk_column_view_column_set_visible(header, if (visible) gtk.true_ else gtk.false_);
        if (narrowWidth(column) != null or table.config != null) gtk.gtk_column_view_column_set_fixed_width(header, columnWidth(table, column));
    }
}

/// Switches the table to another view's columns, order and widths.
pub fn useConfig(table: *Table, config: *Config) void {
    if (table.config == config) return;
    table.config = config;
    applyOrder(table);
    applyVisibility(table);
    syncActions(table);
    refillChooser(table);
    markSorted(table, if (table.sorted) |column| column.sortKey() else null);
}

/// Drops the columns a narrow window has no room for and narrows Title and
/// Artist, without forgetting which columns were chosen or their widths.
pub fn setNarrow(table: *Table, narrow: bool) void {
    table.narrow = narrow;
    applyVisibility(table);
}

/// The Columns button: a popover listing every column the table can show in
/// its order, each with a check to show it and a grip to drag it elsewhere,
/// then a way back to the view's defaults. `extra` goes below the list.
pub fn newColumnsButton(table: *Table, icon_only: bool, extra: ?*gtk.Widget) *gtk.Widget {
    const button = gtk.gtk_menu_button_new();
    if (icon_only) {
        gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), "orca-columns-symbolic");
        gtk.gtk_widget_add_css_class(button, "columns-corner");
    } else {
        const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_image_new_from_icon_name("orca-columns-symbolic"));
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new("Columns"));
        gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), content);
        gtk.gtk_widget_add_css_class(button, "btn-menu");
    }
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, button), gtk.false_);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), chooserPopover(table, extra));
    gtk.gtk_widget_set_tooltip_text(button, "Choose columns");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

fn chooserPopover(table: *Table, extra: ?*gtk.Widget) *gtk.Widget {
    const popover = gtk.gtk_popover_new();
    gtk.gtk_widget_add_css_class(popover, "column-chooser");
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    const title = gtk.gtk_label_new("Columns");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_add_css_class(title, "chooser-title");
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), title);
    const list = gtk.gtk_list_box_new();
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "chooser-list");
    const scroller = gtk.gtk_scrolled_window_new();
    const window = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(window, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(window, gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(window, chooser_max_height);
    gtk.gtk_scrolled_window_set_child(window, list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), scroller);
    if (extra) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, content), widget);
    const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(footer, "chooser-footer");
    const reset = gtk.gtk_button_new_with_label("Reset to default");
    gtk.gtk_widget_add_css_class(reset, "flat");
    gtk.gtk_widget_add_css_class(reset, "chooser-reset");
    _ = gtk.signalConnect(reset, "clicked", gtk.callback(resetClicked), table);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), reset);
    const note = gtk.gtk_label_new("Saved per view");
    gtk.gtk_widget_set_hexpand(note, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, note), 1.0);
    gtk.gtk_widget_add_css_class(note, "chooser-note");
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), note);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), footer);
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), content);
    gtk.g_object_set_data(popover, "orca-chooser-list", list);
    _ = gtk.signalConnect(popover, "show", gtk.callback(chooserShown), table);
    _ = gtk.signalConnect(popover, "closed", gtk.callback(chooserClosed), table);
    return popover;
}

fn chooserShown(popover: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const table = tableData(data);
    const list = gtk.g_object_get_data(gtk.cast(gtk.Widget, popover.?), "orca-chooser-list") orelse return;
    table.chooser_list = gtk.cast(gtk.ListBox, list);
    refillChooser(table);
}

fn chooserClosed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    tableData(data).chooser_list = null;
}

fn refillChooser(table: *Table) void {
    const list = table.chooser_list orelse return;
    const config = table.config orelse return;
    gtk.gtk_list_box_remove_all(list);
    for (config.order) |column| {
        if (!choosable(column)) continue;
        if (config.view == .large and !large_choices.contains(column) and !config.columns.contains(column)) continue;
        gtk.gtk_list_box_append(list, chooserRow(table, column));
    }
}

fn chooserRow(table: *Table, column: Column) *gtk.Widget {
    const config = table.config.?;
    const cell = &table.cells[@intFromEnum(column)];
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, row), gtk.false_);
    gtk.gtk_widget_add_css_class(row, "chooser-row");
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const grip = gtk.gtk_image_new_from_icon_name("orca-grip-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, grip), 14);
    gtk.gtk_widget_add_css_class(grip, "chooser-grip");
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), grip);
    const check = gtk.gtk_check_button_new_with_label(choiceLabel(column));
    gtk.gtk_widget_set_hexpand(check, gtk.true_);
    gtk.gtk_check_button_set_active(gtk.cast(gtk.CheckButton, check), if (config.columns.contains(column)) gtk.true_ else gtk.false_);
    if (always_shown.contains(column)) {
        gtk.gtk_widget_set_sensitive(check, gtk.false_);
    } else {
        _ = gtk.signalConnect(check, "toggled", gtk.callback(checkToggled), cell);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), check);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), line);
    gtk.g_object_set_data(row, "orca-column-cell", cell);

    const source = gtk.gtk_drag_source_new();
    gtk.gtk_drag_source_set_actions(source, gtk.ACTION_MOVE);
    _ = gtk.signalConnect(source, "prepare", gtk.callback(chooserDragPrepare), cell);
    _ = gtk.signalConnect(source, "drag-begin", gtk.callback(chooserDragBegin), cell);
    gtk.gtk_widget_add_controller(row, source);
    const drop = gtk.gtk_drop_target_new(gtk.G_TYPE_UINT, gtk.ACTION_MOVE);
    _ = gtk.signalConnect(drop, "drop", gtk.callback(chooserDropped), cell);
    gtk.gtk_widget_add_controller(row, drop);
    return row;
}

fn checkToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cell = cellData(data);
    const shown = gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, button.?)) != 0;
    setShown(cell.table, cell.column, shown, false);
}

fn chooserDragPrepare(_: ?*anyopaque, _: f64, _: f64, data: ?*anyopaque) callconv(.c) ?*anyopaque {
    var value: gtk.GValue = .{};
    _ = gtk.g_value_init(&value, gtk.G_TYPE_UINT);
    defer gtk.g_value_unset(&value);
    gtk.g_value_set_uint(&value, @intFromEnum(cellData(data).column));
    return gtk.gdk_content_provider_new_for_value(&value);
}

fn chooserDragBegin(source: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const row = menu.gestureWidget(source);
    const paintable = gtk.gtk_widget_paintable_new(row);
    defer gtk.g_object_unref(paintable);
    gtk.gtk_drag_source_set_icon(gtk.cast(gtk.EventController, source.?), paintable, 12, 14);
}

fn chooserDropped(_: ?*anyopaque, value: *const gtk.GValue, _: f64, _: f64, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const cell = cellData(data);
    const table = cell.table;
    const config = table.config orelse return gtk.false_;
    const tag = gtk.g_value_get_uint(value);
    if (tag >= column_count) return gtk.false_;
    const from: Column = @enumFromInt(@as(std.meta.Tag(Column), @intCast(tag)));
    if (!moveColumn(config, from, cell.column)) return gtk.false_;
    applyOrder(table);
    refillChooser(table);
    settings.save(table.app);
    return gtk.true_;
}

fn resetClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const table = tableData(data);
    const config = table.config orelse return;
    config.* = Config.initial(config.view);
    applyOrder(table);
    applyVisibility(table);
    syncActions(table);
    refillChooser(table);
    markSorted(table, if (table.sorted) |column| column.sortKey() else null);
    settings.save(table.app);
}

/// Shows or hides a chosen column everywhere it is offered: the header, the
/// header's menu and the chooser.
fn setShown(table: *Table, column: Column, shown: bool, from_menu: bool) void {
    const config = table.config orelse return;
    if (always_shown.contains(column) or config.columns.contains(column) == shown) return;
    config.columns.setPresent(column, shown);
    syncActions(table);
    applyVisibility(table);
    markSorted(table, if (table.sorted) |sorted| sorted.sortKey() else null);
    if (from_menu) refillChooser(table);
    settings.save(table.app);
}

fn syncActions(table: *Table) void {
    const config = table.config orelse return;
    const group = table.chooser_actions orelse return;
    for (Column.all) |column| {
        if (!choosable(column) or always_shown.contains(column)) continue;
        const action = gtk.g_action_map_lookup_action(gtk.cast(gtk.GActionMap, group), @tagName(column)) orelse continue;
        const shown = config.columns.contains(column);
        gtk.g_simple_action_set_state(gtk.cast(gtk.GSimpleAction, action), gtk.g_variant_new_boolean(if (shown) gtk.true_ else gtk.false_));
    }
}

fn choiceActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cell = cellData(data);
    const config = cell.table.config orelse return;
    setShown(cell.table, cell.column, !config.columns.contains(cell.column), true);
}

/// The header's menu: a check per column the table can hide.
fn buildChooser(table: *Table, view: *gtk.Widget) void {
    const config = table.config orelse return;
    const group = gtk.g_simple_action_group_new();
    const items = gtk.g_menu_new();
    for (large_order) |column| {
        if (!choosable(column) or always_shown.contains(column)) continue;
        const shown = config.columns.contains(column);
        const action = gtk.g_simple_action_new_stateful(@tagName(column), null, gtk.g_variant_new_boolean(if (shown) gtk.true_ else gtk.false_)) orelse continue;
        _ = gtk.signalConnect(action, "activate", gtk.callback(choiceActivated), &table.cells[@intFromEnum(column)]);
        gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
        gtk.g_object_unref(action);
        var name: [48]u8 = undefined;
        gtk.g_menu_append(items, choiceLabel(column), strings.format(&name, "columns.{s}", .{@tagName(column)}).ptr);
    }
    gtk.gtk_widget_insert_action_group(view, "columns", gtk.cast(gtk.GActionGroup, group));
    table.chooser = gtk.cast(gtk.GMenuModel, items);
    table.chooser_actions = gtk.cast(gtk.GActionGroup, group);
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
    const result = gtk.gtk_column_view_column_new(heading(column), factory);
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
    table.title_heart = options.title_heart;
    const model = if (options.paged) paged: {
        const paged = track_model.newPagedModel().?;
        table.paged = paged;
        break :paged gtk.cast(gtk.ListModel, gtk.g_object_ref(paged));
    } else store: {
        const store = gtk.g_list_store_new(track_model.getType()).?;
        table.store = store;
        break :store gtk.cast(gtk.ListModel, gtk.g_object_ref(store));
    };
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
    applyOrder(table);
    applyVisibility(table);
    decorateHeader(table);
    _ = gtk.signalConnect(gtk.gtk_column_view_get_columns(table.view.?), "items-changed", gtk.callback(columnsChanged), table);
    _ = gtk.signalConnect(view, "destroy", gtk.callback(viewDestroyed), table);
    return view;
}
