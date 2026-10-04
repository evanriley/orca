const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const playlists = @import("playlists.zig");
const window = @import("window.zig");

const App = app.App;

const preview_delay_ms = 250;
const preview_rows = 7;
const editor_key = "orca-smart-editor";

const Type = enum { text, integer, date, boolean, playlist };

const Field = struct {
    name: []const u8,
    label: [*:0]const u8,
    type: Type,
    scale: i64 = 1,
    yes: [*:0]const u8 = "Yes",
    no: [*:0]const u8 = "No",
};

const fields = [_]Field{
    .{ .name = "title", .label = "Title", .type = .text },
    .{ .name = "artist", .label = "Artist", .type = .text },
    .{ .name = "album", .label = "Album", .type = .text },
    .{ .name = "album_artist", .label = "Album Artist", .type = .text },
    .{ .name = "genre", .label = "Genre", .type = .text },
    .{ .name = "codec", .label = "Codec", .type = .text },
    .{ .name = "release_type", .label = "Release Type", .type = .text },
    .{ .name = "year", .label = "Year", .type = .integer },
    .{ .name = "play_count", .label = "Plays", .type = .integer },
    .{ .name = "rating", .label = "Rating (1–100)", .type = .integer },
    .{ .name = "duration_ms", .label = "Duration (seconds)", .type = .integer, .scale = 1000 },
    .{ .name = "sample_rate", .label = "Sample Rate (Hz)", .type = .integer },
    .{ .name = "bit_depth", .label = "Bit Depth", .type = .integer },
    .{ .name = "added_at", .label = "Date Added", .type = .date },
    .{ .name = "last_played_at", .label = "Last Played", .type = .date },
    .{ .name = "loved", .label = "Loved", .type = .boolean, .yes = "Loved", .no = "Not loved" },
    .{ .name = "lossless", .label = "Lossless", .type = .boolean, .yes = "Lossless", .no = "Lossy" },
    .{ .name = "explicit", .label = "Explicit", .type = .boolean, .yes = "Explicit", .no = "Not explicit" },
    .{ .name = "has_artwork", .label = "Artwork", .type = .boolean, .yes = "Has artwork", .no = "No artwork" },
    .{ .name = "in_playlist", .label = "Playlist", .type = .playlist },
};

const Operator = struct {
    name: []const u8,
    label: [*:0]const u8,
};

const text_operators = [_]Operator{
    .{ .name = "contains", .label = "contains" },
    .{ .name = "is", .label = "is" },
    .{ .name = "is_not", .label = "is not" },
    .{ .name = "starts_with", .label = "starts with" },
    .{ .name = "is_set", .label = "is set" },
    .{ .name = "is_not_set", .label = "is not set" },
};

const integer_operators = [_]Operator{
    .{ .name = "is", .label = "is" },
    .{ .name = "is_not", .label = "is not" },
    .{ .name = "gt", .label = "is greater than" },
    .{ .name = "gte", .label = "is at least" },
    .{ .name = "lt", .label = "is less than" },
    .{ .name = "lte", .label = "is at most" },
    .{ .name = "between", .label = "is between" },
    .{ .name = "is_set", .label = "is set" },
    .{ .name = "is_not_set", .label = "is not set" },
};

const date_operators = [_]Operator{
    .{ .name = "in_last_days", .label = "is in the last" },
    .{ .name = "not_in_last_days", .label = "is not in the last" },
    .{ .name = "gt", .label = "is after" },
    .{ .name = "gte", .label = "is on or after" },
    .{ .name = "lt", .label = "is before" },
    .{ .name = "lte", .label = "is on or before" },
    .{ .name = "between", .label = "is between" },
    .{ .name = "is_set", .label = "is set" },
    .{ .name = "is_not_set", .label = "is not set" },
};

const boolean_operators = [_]Operator{
    .{ .name = "is", .label = "is" },
    .{ .name = "is_not", .label = "is not" },
};

fn operatorsOf(field_type: Type) []const Operator {
    return switch (field_type) {
        .text => &text_operators,
        .integer => &integer_operators,
        .date => &date_operators,
        .boolean, .playlist => &boolean_operators,
    };
}

const DayUnit = struct {
    label: [*:0]const u8,
    days: i64,
};

const day_units = [_]DayUnit{
    .{ .label = "days", .days = 1 },
    .{ .label = "weeks", .days = 7 },
    .{ .label = "months", .days = 30 },
    .{ .label = "years", .days = 365 },
};

const Sort = struct {
    name: ?[]const u8,
    descending: bool = false,
    label: [*:0]const u8,
};

const sorts = [_]Sort{
    .{ .name = null, .label = "library order" },
    .{ .name = "random", .label = "random" },
    .{ .name = "date_added", .descending = true, .label = "most recently added" },
    .{ .name = "date_added", .label = "least recently added" },
    .{ .name = "rating", .descending = true, .label = "highest rated" },
    .{ .name = "rating", .label = "lowest rated" },
    .{ .name = "play_count", .descending = true, .label = "most played" },
    .{ .name = "play_count", .label = "least played" },
    .{ .name = "last_played", .descending = true, .label = "most recently played" },
    .{ .name = "last_played", .label = "least recently played" },
    .{ .name = "loved", .label = "most recently loved" },
    .{ .name = "year", .descending = true, .label = "newest" },
    .{ .name = "year", .label = "oldest" },
    .{ .name = "duration", .descending = true, .label = "longest" },
    .{ .name = "duration", .label = "shortest" },
    .{ .name = "title", .label = "title" },
    .{ .name = "artist", .label = "artist" },
    .{ .name = "album", .label = "album" },
    .{ .name = "track_number", .label = "track number" },
};

const sort_aliases = [_]struct { alias: []const u8, name: []const u8 }{
    .{ .alias = "added_at", .name = "date_added" },
    .{ .alias = "last_played_at", .name = "last_played" },
    .{ .alias = "duration_ms", .name = "duration" },
};

const limit_units = [_]?[*:0]const u8{ "tracks", "hours", null };

const Value = enum { none, one, two, days, boolean, playlist };

fn valueOf(field_type: Type, operator: []const u8) Value {
    if (std.mem.eql(u8, operator, "is_set") or std.mem.eql(u8, operator, "is_not_set")) return .none;
    if (field_type == .boolean) return .boolean;
    if (field_type == .playlist) return .playlist;
    if (std.mem.eql(u8, operator, "between")) return .two;
    if (std.mem.endsWith(u8, operator, "in_last_days")) return .days;
    return .one;
}

const Editor = struct {
    self: *App,
    playlist_id: ?i64,
    page: *adw.NavigationPage,
    name: *gtk.Widget,
    root: *gtk.Widget,
    sort: *gtk.DropDown,
    sort_labels: *gtk.StringList,
    limit: *gtk.Widget,
    limit_unit: *gtk.DropDown,
    count: *gtk.Label,
    summary: *gtk.Label,
    sample: *gtk.Widget,
    more: *gtk.Label,
    playlist_ids: []i64,
    playlist_names: *gtk.StringList,
    loaded_sort: ?[]u8 = null,
    loaded_sort_index: c_uint = 0,
    timer: c_uint = 0,
};

fn editorOf(data: ?*anyopaque) *Editor {
    return @ptrCast(@alignCast(data.?));
}

fn part(widget: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    return gtk.cast(gtk.Widget, gtk.g_object_get_data(widget, key) orelse return null);
}

fn depthOf(group: *gtk.Widget) usize {
    return @intFromPtr(gtk.g_object_get_data(group, "orca-depth"));
}

fn isGroup(widget: *gtk.Widget) bool {
    return gtk.g_object_get_data(widget, "orca-depth") != null;
}

fn text(widget: *gtk.Widget) []const u8 {
    return std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, widget)));
}

fn setText(widget: *gtk.Widget, value: []const u8) void {
    var buffer: [300]u8 = undefined;
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, widget), strings.terminated(&buffer, value).ptr);
}

fn selected(widget: *gtk.Widget) c_uint {
    return gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, widget));
}

fn select(widget: *gtk.Widget, index: usize) void {
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, widget), @intCast(index));
}

fn fieldOf(row: *gtk.Widget) Field {
    const index = selected(part(row, "orca-field").?);
    return fields[if (index < fields.len) index else 0];
}

fn operatorOf(row: *gtk.Widget) Operator {
    const operators = operatorsOf(fieldOf(row).type);
    const index = selected(part(row, "orca-operator").?);
    return operators[if (index < operators.len) index else 0];
}

fn dayUnitOf(row: *gtk.Widget) DayUnit {
    const index = selected(part(row, "orca-day-unit").?);
    return day_units[if (index < day_units.len) index else 0];
}

fn changed(editor: *Editor) void {
    if (editor.timer != 0) _ = gtk.g_source_remove(editor.timer);
    editor.timer = gtk.g_timeout_add(preview_delay_ms, previewLater, editor);
}

fn previewLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const editor = editorOf(data);
    editor.timer = 0;
    showPreview(editor);
    return gtk.SOURCE_REMOVE;
}

fn rulesError(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.InvalidSmartPlaylistRules => "These rules are not valid",
        error.UnknownRuleField => "A rule tests a field Orca does not know",
        error.UnknownRuleOperator => "A rule uses a comparison Orca does not know",
        error.RuleOperatorMismatch => "A comparison does not fit its field",
        error.InvalidRuleValue => "A rule's value is missing or out of range",
        error.InvalidRulePlaylist => "A rule names a playlist that is not one of your own",
        error.RuleNestingTooDeep => "Groups nest at most four deep",
        error.TooManyRules => "At most 32 rules in all, and 32 in a group",
        error.PlaylistNameTaken => "A playlist with that name already exists",
        error.InvalidPlaylistName => "A smart playlist needs a name",
        error.UnknownPlaylist => "That playlist no longer exists",
        else => "Could not read these rules",
    };
}

fn clearSample(editor: *Editor) void {
    const box = gtk.cast(gtk.Box, editor.sample);
    while (gtk.gtk_widget_get_first_child(editor.sample)) |child| gtk.gtk_box_remove(box, child);
}

fn showError(editor: *Editor, message: [:0]const u8) void {
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, editor.count), gtk.false_);
    gtk.gtk_label_set_text(editor.summary, message.ptr);
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, editor.summary), "error");
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, editor.more), gtk.false_);
    clearSample(editor);
}

fn label(words: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(words);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    return widget;
}

fn newSampleRow(track: liborca.TrackSummary) *gtk.Widget {
    var buffer: [600]u8 = undefined;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "smart-preview-row");
    const words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    const title = label(strings.terminated(&buffer, track.title).ptr, "smart-preview-title");
    const byline = label(strings.format(&buffer, "{s} · {s}", .{ track.artist, track.album }).ptr, "smart-preview-byline");
    for ([_]*gtk.Widget{ title, byline }) |line| {
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, line), gtk.ELLIPSIZE_END);
        gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, line), 1);
        gtk.gtk_box_append(gtk.cast(gtk.Box, words), line);
    }
    const length = label(if (track.duration_ms) |ms| strings.formatMs(&buffer, @intCast(@max(ms, 0))).ptr else "", "smart-preview-length");
    gtk.gtk_widget_add_css_class(length, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), words);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), length);
    return row;
}

fn showPreview(editor: *Editor) void {
    const self = editor.self;
    const library = self.library orelse return;
    const json = rulesJson(editor) catch return showError(editor, "Out of memory");
    defer self.allocator.free(json);
    const preview = self.runtime.librarySmartPlaylistPreview(library, self.allocator, json, preview_rows) catch |err|
        return showError(editor, rulesError(err));
    defer preview.deinit(self.allocator);

    var buffer: [96]u8 = undefined;
    gtk.gtk_label_set_text(editor.count, strings.format(&buffer, "{f}", .{strings.grouped(preview.count)}).ptr);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, editor.count), gtk.true_);
    var length_buffer: [32]u8 = undefined;
    const length = strings.totalDuration(&length_buffer, @intCast(@min(preview.duration_ms, std.math.maxInt(i64))));
    gtk.gtk_label_set_text(editor.summary, strings.format(&buffer, "matching {s} · {s}", .{ if (preview.count == 1) "track" else "tracks", length }).ptr);
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, editor.summary), "error");

    clearSample(editor);
    for (preview.sample) |track| gtk.gtk_box_append(gtk.cast(gtk.Box, editor.sample), newSampleRow(track));
    const rest = preview.count -| preview.sample.len;
    gtk.gtk_label_set_text(editor.more, strings.format(&buffer, "and {f} more", .{strings.grouped(rest)}).ptr);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, editor.more), @intFromBool(rest > 0));
}

fn writeNumber(writer: *std.Io.Writer, typed: []const u8, scale: i64) !void {
    const trimmed = std.mem.trim(u8, typed, " \t");
    const number = std.fmt.parseInt(i64, trimmed, 10) catch return std.json.Stringify.encodeJsonString(typed, .{}, writer);
    const scaled = std.math.mul(i64, number, scale) catch return std.json.Stringify.encodeJsonString(typed, .{}, writer);
    try writer.print("{d}", .{scaled});
}

fn parseDate(typed: []const u8) ?i64 {
    var pieces = std.mem.splitScalar(u8, std.mem.trim(u8, typed, " \t"), '-');
    var parts: [3]c_int = undefined;
    for (&parts) |*piece| piece.* = std.fmt.parseInt(c_int, pieces.next() orelse return null, 10) catch return null;
    if (pieces.next() != null) return null;
    const moment = gtk.g_date_time_new_local(parts[0], parts[1], parts[2], 0, 0, 0) orelse return null;
    defer gtk.g_date_time_unref(moment);
    return gtk.g_date_time_to_unix(moment);
}

fn writeDate(writer: *std.Io.Writer, typed: []const u8) !void {
    const seconds = parseDate(typed) orelse return std.json.Stringify.encodeJsonString(typed, .{}, writer);
    try writer.print("{d}", .{seconds});
}

fn writeValue(writer: *std.Io.Writer, field: Field, typed: []const u8) !void {
    switch (field.type) {
        .text, .boolean => try std.json.Stringify.encodeJsonString(typed, .{}, writer),
        .integer, .playlist => try writeNumber(writer, typed, field.scale),
        .date => try writeDate(writer, typed),
    }
}

fn writeRule(writer: *std.Io.Writer, editor: *Editor, row: *gtk.Widget) !void {
    const field = fieldOf(row);
    const operator = operatorOf(row);
    try writer.writeAll("{\"field\":");
    try std.json.Stringify.encodeJsonString(field.name, .{}, writer);
    try writer.writeAll(",\"op\":");
    try std.json.Stringify.encodeJsonString(operator.name, .{}, writer);
    switch (valueOf(field.type, operator.name)) {
        .none => {},
        .one => {
            try writer.writeAll(",\"value\":");
            try writeValue(writer, field, text(part(row, "orca-first").?));
        },
        .two => {
            try writer.writeAll(",\"value\":[");
            try writeValue(writer, field, text(part(row, "orca-from").?));
            try writer.writeByte(',');
            try writeValue(writer, field, text(part(row, "orca-to").?));
            try writer.writeByte(']');
        },
        .days => {
            try writer.writeAll(",\"value\":");
            try writeNumber(writer, text(part(row, "orca-days").?), dayUnitOf(row).days);
        },
        .boolean => try writer.writeAll(if (selected(part(row, "orca-boolean").?) == 0) ",\"value\":true" else ",\"value\":false"),
        .playlist => {
            const index = selected(part(row, "orca-playlist").?);
            if (index < editor.playlist_ids.len)
                try writer.print(",\"value\":{d}", .{editor.playlist_ids[index]})
            else
                try writer.writeAll(",\"value\":null");
        },
    }
    try writer.writeByte('}');
}

fn writeGroup(writer: *std.Io.Writer, editor: *Editor, group: *gtk.Widget) !void {
    try writer.writeAll(if (selected(part(group, "orca-match").?) == 0) "\"match\":\"all\",\"rules\":[" else "\"match\":\"any\",\"rules\":[");
    var child = gtk.gtk_widget_get_first_child(part(group, "orca-items").?);
    var first = true;
    while (child) |item| : (child = gtk.gtk_widget_get_next_sibling(item)) {
        if (!first) try writer.writeByte(',');
        first = false;
        if (isGroup(item)) {
            try writer.writeByte('{');
            try writeGroup(writer, editor, item);
            try writer.writeByte('}');
        } else try writeRule(writer, editor, item);
    }
    try writer.writeByte(']');
}

fn writeSort(writer: *std.Io.Writer, editor: *Editor) !void {
    const index = gtk.gtk_drop_down_get_selected(editor.sort);
    if (editor.loaded_sort) |original| if (index == editor.loaded_sort_index) {
        try writer.writeAll(",\"sort\":");
        return writer.writeAll(original);
    };
    if (index >= sorts.len) return;
    const name = sorts[index].name orelse return;
    try writer.writeAll(",\"sort\":{\"field\":");
    try std.json.Stringify.encodeJsonString(name, .{}, writer);
    if (sorts[index].descending) try writer.writeAll(",\"descending\":true");
    try writer.writeByte('}');
}

fn writeRules(writer: *std.Io.Writer, editor: *Editor) !void {
    try writer.writeAll("{\"v\":1,");
    try writeGroup(writer, editor, editor.root);
    try writeSort(writer, editor);
    const limit = std.mem.trim(u8, text(editor.limit), " \t");
    if (limit.len != 0) {
        try writer.writeAll(if (gtk.gtk_drop_down_get_selected(editor.limit_unit) == 1) ",\"limit_hours\":" else ",\"limit\":");
        try writeNumber(writer, limit, 1);
    }
    try writer.writeByte('}');
}

fn rulesJson(editor: *Editor) ![]u8 {
    var json: std.Io.Writer.Allocating = .init(editor.self.allocator);
    defer json.deinit();
    writeRules(&json.writer, editor) catch return error.OutOfMemory;
    return json.toOwnedSlice();
}

fn somethingChanged(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    changed(editorOf(data));
}

fn selectionChanged(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    changed(editorOf(data));
}

fn showValue(row: *gtk.Widget) void {
    const field = fieldOf(row);
    const value = valueOf(field.type, operatorOf(row).name);
    const placeholder: [*:0]const u8 = switch (field.type) {
        .date => "YYYY-MM-DD",
        .integer => "Number",
        .text, .boolean, .playlist => "Text",
    };
    for ([_][*:0]const u8{ "orca-first", "orca-from", "orca-to" }) |key|
        gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, part(row, key).?), placeholder);
    if (value == .boolean) {
        const answers: *gtk.StringList = @ptrCast(@alignCast(gtk.g_object_get_data(row, "orca-answers").?));
        const choice = selected(part(row, "orca-boolean").?);
        const labels = [_]?[*:0]const u8{ field.yes, field.no, null };
        gtk.gtk_string_list_splice(answers, 0, gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, answers)), &labels);
        select(part(row, "orca-boolean").?, if (choice < 2) choice else 0);
    }
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, part(row, "orca-value").?), @tagName(value));
}

fn showOperators(row: *gtk.Widget, keep: []const u8) void {
    const operators = operatorsOf(fieldOf(row).type);
    const model: *gtk.StringList = @ptrCast(@alignCast(gtk.g_object_get_data(row, "orca-operators").?));
    var labels: [integer_operators.len + 1]?[*:0]const u8 = undefined;
    for (operators, 0..) |operator, index| labels[index] = operator.label;
    labels[operators.len] = null;
    const shown = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, model));
    gtk.gtk_string_list_splice(model, 0, shown, &labels);
    var choice: usize = 0;
    for (operators, 0..) |operator, index| {
        if (std.mem.eql(u8, operator.name, keep)) choice = index;
    }
    select(part(row, "orca-operator").?, choice);
}

fn fieldChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = part(gtk.cast(gtk.Widget, drop_down.?), "orca-row") orelse return;
    const kept = gtk.g_object_get_data(row, "orca-kept-operator");
    showOperators(row, if (kept) |name| std.mem.span(@as([*:0]const u8, @ptrCast(name))) else "");
    showValue(row);
    changed(editorOf(data));
}

fn operatorChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = part(gtk.cast(gtk.Widget, drop_down.?), "orca-row") orelse return;
    showValue(row);
    changed(editorOf(data));
}

fn removeClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const target = part(gtk.cast(gtk.Widget, button.?), "orca-target") orelse return;
    const items = gtk.gtk_widget_get_parent(target) orelse return;
    gtk.gtk_box_remove(gtk.cast(gtk.Box, items), target);
    changed(editorOf(data));
}

fn addBelowClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const row = part(gtk.cast(gtk.Widget, button.?), "orca-target") orelse return;
    const items = gtk.gtk_widget_get_parent(row) orelse return;
    gtk.gtk_box_insert_child_after(gtk.cast(gtk.Box, items), newRule(editor, false), row);
    changed(editor);
}

fn entry(editor: *Editor) *gtk.Widget {
    const widget = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(widget, "smart-control");
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, widget), 4);
    _ = gtk.signalConnect(widget, "changed", gtk.callback(somethingChanged), editor);
    return widget;
}

fn dropDown(model: *gtk.ListModel, tooltip: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_drop_down_new(model, null);
    gtk.gtk_widget_add_css_class(widget, "smart-control");
    gtk.gtk_widget_set_tooltip_text(widget, tooltip);
    return widget;
}

fn dropDownOf(labels: []const ?[*:0]const u8, tooltip: [*:0]const u8) *gtk.Widget {
    return dropDown(gtk.cast(gtk.ListModel, gtk.gtk_string_list_new(labels.ptr)), tooltip);
}

fn caption(words: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(words);
    gtk.gtk_widget_add_css_class(widget, "smart-caption");
    return widget;
}

fn iconButton(editor: *Editor, target: *gtk.Widget, icon: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "smart-icon-button");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.g_object_set_data(button, "orca-target", target);
    _ = gtk.signalConnect(button, "clicked", handler, editor);
    return button;
}

fn newValue(editor: *Editor, row: *gtk.Widget) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    gtk.gtk_stack_set_hhomogeneous(gtk.cast(gtk.Stack, stack), gtk.false_);
    gtk.gtk_widget_set_hexpand(stack, gtk.true_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0), "none");

    const first = entry(editor);
    gtk.gtk_widget_set_hexpand(first, gtk.true_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), first, "one");

    const range = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const from = entry(editor);
    const to = entry(editor);
    gtk.gtk_widget_set_hexpand(from, gtk.true_);
    gtk.gtk_widget_set_hexpand(to, gtk.true_);
    for ([_]*gtk.Widget{ from, caption("and"), to }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, range), child);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), range, "two");

    const days_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const days = entry(editor);
    gtk.gtk_widget_set_hexpand(days, gtk.true_);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, days), "30");
    const unit_labels = comptime labels: {
        var all: [day_units.len + 1]?[*:0]const u8 = undefined;
        for (day_units, 0..) |unit, index| all[index] = unit.label;
        all[day_units.len] = null;
        break :labels all;
    };
    const day_unit = dropDownOf(&unit_labels, "Unit");
    _ = gtk.signalConnect(day_unit, "notify::selected", gtk.callback(selectionChanged), editor);
    gtk.gtk_box_append(gtk.cast(gtk.Box, days_box), days);
    gtk.gtk_box_append(gtk.cast(gtk.Box, days_box), day_unit);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), days_box, "days");

    const answers = gtk.gtk_string_list_new(null);
    const boolean = dropDown(gtk.cast(gtk.ListModel, answers), "Value");
    gtk.gtk_widget_set_hexpand(boolean, gtk.true_);
    _ = gtk.signalConnect(boolean, "notify::selected", gtk.callback(selectionChanged), editor);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), boolean, "boolean");

    const playlist = dropDown(gtk.cast(gtk.ListModel, gtk.g_object_ref(editor.playlist_names)), "Playlist");
    gtk.gtk_widget_set_hexpand(playlist, gtk.true_);
    _ = gtk.signalConnect(playlist, "notify::selected", gtk.callback(selectionChanged), editor);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), playlist, "playlist");

    gtk.g_object_set_data(row, "orca-value", stack);
    gtk.g_object_set_data(row, "orca-first", first);
    gtk.g_object_set_data(row, "orca-from", from);
    gtk.g_object_set_data(row, "orca-to", to);
    gtk.g_object_set_data(row, "orca-days", days);
    gtk.g_object_set_data(row, "orca-day-unit", day_unit);
    gtk.g_object_set_data(row, "orca-boolean", boolean);
    gtk.g_object_set_data(row, "orca-answers", answers);
    gtk.g_object_set_data(row, "orca-playlist", playlist);
    return stack;
}

fn newRule(editor: *Editor, nested: bool) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(row, "smart-rule");

    const field_labels = comptime labels: {
        var all: [fields.len + 1]?[*:0]const u8 = undefined;
        for (fields, 0..) |field, index| all[index] = field.label;
        all[fields.len] = null;
        break :labels all;
    };
    const field = dropDownOf(&field_labels, "Field");
    gtk.gtk_widget_set_size_request(field, if (nested) 156 else 180, -1);
    const operators = gtk.gtk_string_list_new(null);
    const operator = dropDown(gtk.cast(gtk.ListModel, operators), "Comparison");
    gtk.gtk_widget_set_size_request(operator, if (nested) 130 else 150, -1);
    gtk.g_object_set_data(row, "orca-field", field);
    gtk.g_object_set_data(row, "orca-operator", operator);
    gtk.g_object_set_data(row, "orca-operators", operators);
    gtk.g_object_set_data(field, "orca-row", row);
    gtk.g_object_set_data(operator, "orca-row", row);
    const value = newValue(editor, row);
    showOperators(row, "");
    showValue(row);
    _ = gtk.signalConnect(field, "notify::selected", gtk.callback(fieldChanged), editor);
    _ = gtk.signalConnect(operator, "notify::selected", gtk.callback(operatorChanged), editor);

    for ([_]*gtk.Widget{
        field,
        operator,
        value,
        iconButton(editor, row, "orca-minus-symbolic", "Remove rule", gtk.callback(removeClicked)),
    }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, row), child);
    if (!nested) gtk.gtk_box_append(gtk.cast(gtk.Box, row), iconButton(editor, row, "orca-plus-symbolic", "Add rule below", gtk.callback(addBelowClicked)));
    return row;
}

fn addRuleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    gtk.gtk_box_append(gtk.cast(gtk.Box, part(editor.root, "orca-items").?), newRule(editor, false));
    changed(editor);
}

fn addGroupClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const nested = newGroup(editor, 2);
    select(part(nested, "orca-match").?, 1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, part(nested, "orca-items").?), newRule(editor, true));
    gtk.gtk_box_append(gtk.cast(gtk.Box, part(editor.root, "orca-items").?), nested);
    changed(editor);
}

fn addButton(editor: *Editor, words: [*:0]const u8, handler: gtk.GCallback) *gtk.Widget {
    const button = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "btn-secondary");
    gtk.gtk_widget_add_css_class(button, "smart-add");
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const icon = gtk.gtk_image_new_from_icon_name("orca-plus-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 15);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(words));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    _ = gtk.signalConnect(button, "clicked", handler, editor);
    return button;
}

fn newGroup(editor: *Editor, depth: usize) *gtk.Widget {
    const group = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, if (depth == 1) 12 else 10);
    gtk.gtk_widget_add_css_class(group, if (depth == 1) "smart-card" else "smart-group");
    gtk.g_object_set_data(group, "orca-depth", @ptrFromInt(depth));

    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(heading, "smart-match");
    const choices = [_]?[*:0]const u8{ "all", "any", null };
    const match = dropDownOf(&choices, "Whether every rule must match, or any one");
    _ = gtk.signalConnect(match, "notify::selected", gtk.callback(selectionChanged), editor);
    gtk.g_object_set_data(group, "orca-match", match);
    const tail = caption(if (depth == 1) "of the following rules" else "of");
    gtk.gtk_widget_set_hexpand(tail, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, tail), 0);
    for ([_]*gtk.Widget{ caption("Match"), match, tail }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, heading), child);
    if (depth > 1) gtk.gtk_box_append(gtk.cast(gtk.Box, heading), iconButton(editor, group, "orca-minus-symbolic", "Remove group", gtk.callback(removeClicked)));

    const items = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, if (depth == 1) 12 else 10);
    gtk.g_object_set_data(group, "orca-items", items);
    gtk.gtk_box_append(gtk.cast(gtk.Box, group), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, group), items);

    if (depth == 1) {
        const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_add_css_class(footer, "smart-add-row");
        gtk.gtk_box_append(gtk.cast(gtk.Box, footer), addButton(editor, "Add Rule", gtk.callback(addRuleClicked)));
        gtk.gtk_box_append(gtk.cast(gtk.Box, footer), addButton(editor, "Add Group", gtk.callback(addGroupClicked)));
        gtk.gtk_box_append(gtk.cast(gtk.Box, group), footer);
    }
    return group;
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |found| found,
        else => null,
    };
}

fn integerOf(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |found| found,
        else => null,
    };
}

fn showNumber(widget: *gtk.Widget, value: std.json.Value, field: Field) void {
    var buffer: [64]u8 = undefined;
    const number = integerOf(value) orelse return;
    if (field.type == .date) {
        const moment = gtk.g_date_time_new_from_unix_local(number) orelse return;
        defer gtk.g_date_time_unref(moment);
        const day = gtk.g_date_time_format(moment, "%F") orelse return;
        defer gtk.g_free(day);
        return gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, widget), day);
    }
    setText(widget, std.fmt.bufPrint(&buffer, "{d}", .{@divTrunc(number, field.scale)}) catch return);
}

fn showDays(row: *gtk.Widget, value: std.json.Value) void {
    const days = integerOf(value) orelse return;
    var unit_index: usize = 0;
    for (day_units, 0..) |unit, index| {
        if (days != 0 and @rem(days, unit.days) == 0) unit_index = index;
    }
    select(part(row, "orca-day-unit").?, unit_index);
    var buffer: [32]u8 = undefined;
    setText(part(row, "orca-days").?, std.fmt.bufPrint(&buffer, "{d}", .{@divTrunc(days, day_units[unit_index].days)}) catch return);
}

fn loadRule(editor: *Editor, object: std.json.ObjectMap, nested: bool) *gtk.Widget {
    const row = newRule(editor, nested);
    const field_name = stringOf(object.get("field")) orelse "";
    const operator_name = stringOf(object.get("op")) orelse "";
    var buffer: [32]u8 = undefined;
    const kept = strings.terminated(&buffer, operator_name);
    gtk.g_object_set_data(row, "orca-kept-operator", @constCast(kept.ptr));
    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, field_name)) select(part(row, "orca-field").?, index);
    }
    showOperators(row, operator_name);
    gtk.g_object_set_data(row, "orca-kept-operator", null);
    showValue(row);
    const field = fieldOf(row);
    const value = object.get("value") orelse return row;
    switch (valueOf(field.type, operatorOf(row).name)) {
        .none => {},
        .one => switch (value) {
            .string => |found| setText(part(row, "orca-first").?, found),
            else => showNumber(part(row, "orca-first").?, value, field),
        },
        .two => switch (value) {
            .array => |pair| if (pair.items.len == 2) {
                showNumber(part(row, "orca-from").?, pair.items[0], field);
                showNumber(part(row, "orca-to").?, pair.items[1], field);
            },
            else => {},
        },
        .days => showDays(row, value),
        .boolean => switch (value) {
            .bool => |yes| select(part(row, "orca-boolean").?, if (yes) 0 else 1),
            else => {},
        },
        .playlist => if (integerOf(value)) |id| {
            for (editor.playlist_ids, 0..) |candidate, index| {
                if (candidate == id) select(part(row, "orca-playlist").?, index);
            }
        },
    }
    return row;
}

fn loadGroup(editor: *Editor, group: *gtk.Widget, object: std.json.ObjectMap) void {
    if (stringOf(object.get("match"))) |match|
        select(part(group, "orca-match").?, if (std.mem.eql(u8, match, "any")) 1 else 0);
    const items = switch (object.get("rules") orelse return) {
        .array => |array| array.items,
        else => return,
    };
    const box = gtk.cast(gtk.Box, part(group, "orca-items").?);
    for (items) |item| {
        const child = switch (item) {
            .object => |found| found,
            else => continue,
        };
        if (child.get("rules") != null) {
            const nested = newGroup(editor, depthOf(group) + 1);
            loadGroup(editor, nested, child);
            gtk.gtk_box_append(box, nested);
        } else gtk.gtk_box_append(box, loadRule(editor, child, depthOf(group) > 1));
    }
}

fn sortIndex(order: std.json.ObjectMap) ?usize {
    if (order.get("playlist") != null) return null;
    var name = stringOf(order.get("field")) orelse return null;
    for (sort_aliases) |alias| if (std.mem.eql(u8, alias.alias, name)) {
        name = alias.name;
    };
    const descending = if (order.get("descending")) |value| switch (value) {
        .bool => |yes| yes,
        else => return null,
    } else false;
    for (sorts, 0..) |sort, index| {
        if (sort.name != null and std.mem.eql(u8, sort.name.?, name) and sort.descending == descending) return index;
    }
    return null;
}

fn storedSortLabel(buffer: []u8, sort: std.json.Value) [:0]const u8 {
    const order = switch (sort) {
        .object => |found| found,
        else => return "saved order",
    };
    const name = stringOf(order.get("field")) orelse return "saved order";
    const descending = if (order.get("descending")) |value| value == .bool and value.bool else false;
    if (std.mem.eql(u8, name, "playlist_position"))
        return if (descending) "playlist order, reversed" else "playlist order";
    var spaced: [64]u8 = undefined;
    const shown = spaced[0..@min(name.len, spaced.len)];
    for (shown, name[0..shown.len]) |*out, byte| out.* = if (byte == '_') ' ' else byte;
    return strings.format(buffer, "{s}{s}", .{ shown, if (descending) ", reversed" else "" });
}

fn loadSort(editor: *Editor, sort: std.json.Value) void {
    const allocator = editor.self.allocator;
    editor.loaded_sort = std.json.Stringify.valueAlloc(allocator, sort, .{}) catch return;
    const index = switch (sort) {
        .object => |order| sortIndex(order),
        else => null,
    } orelse custom: {
        var buffer: [96]u8 = undefined;
        gtk.gtk_string_list_append(editor.sort_labels, storedSortLabel(&buffer, sort).ptr);
        break :custom sorts.len;
    };
    editor.loaded_sort_index = @intCast(index);
    gtk.gtk_drop_down_set_selected(editor.sort, @intCast(index));
}

fn loadRules(editor: *Editor, json: []const u8) void {
    const self = editor.self;
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |found| found,
        else => return,
    };
    loadGroup(editor, editor.root, root);
    if (root.get("sort")) |sort| loadSort(editor, sort);
    const integer: Field = .{ .name = "", .label = "", .type = .integer };
    if (root.get("limit")) |limit| showNumber(editor.limit, limit, integer);
    if (root.get("limit_hours")) |hours| {
        gtk.gtk_drop_down_set_selected(editor.limit_unit, 1);
        showNumber(editor.limit, hours, integer);
    }
}

fn save(editor: *Editor) void {
    const self = editor.self;
    const library = self.library orelse return showError(editor, "No library is open");
    const json = rulesJson(editor) catch return showError(editor, "Out of memory");
    defer self.allocator.free(json);
    const name = std.mem.trim(u8, text(editor.name), " \t");
    const created = editor.playlist_id == null;
    const playlist_id = if (editor.playlist_id) |id| id: {
        self.runtime.librarySetSmartPlaylistRules(library, id, json) catch |err| return showError(editor, rulesError(err));
        const summary = self.runtime.libraryPlaylist(library, id) catch |err| return showError(editor, rulesError(err));
        defer summary.deinit(self.runtime.allocator);
        if (!std.mem.eql(u8, summary.name, name))
            self.runtime.libraryRenamePlaylist(library, id, name) catch |err| return showError(editor, rulesError(err));
        break :id id;
    } else self.runtime.libraryCreateSmartPlaylist(library, name, json) catch |err| return showError(editor, rulesError(err));
    window.popSection(self);
    playlists.rulesSaved(self, playlist_id, created);
}

fn editorOfPage(page: *adw.NavigationPage) ?*Editor {
    return @ptrCast(@alignCast(gtk.g_object_get_data(page, editor_key) orelse return null));
}

pub fn pushedOf(page: *adw.NavigationPage) ?window.Pushed {
    const editor = editorOfPage(page) orelse return null;
    return .{ .smart_rules = editor.playlist_id };
}

fn shownEditor(self: *App) ?*Editor {
    const page = window.pushedPage(self, self.current_page) orelse return null;
    return editorOfPage(page);
}

pub fn isShown(self: *App) bool {
    return shownEditor(self) != null;
}

pub fn saveShown(self: *App) void {
    save(shownEditor(self) orelse return);
}

pub fn cancelShown(self: *App) void {
    if (shownEditor(self) != null) window.popSection(self);
}

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const allocator = editor.self.allocator;
    gtk.g_object_set_data(editor.page, editor_key, null);
    if (editor.timer != 0) _ = gtk.g_source_remove(editor.timer);
    gtk.g_object_unref(editor.playlist_names);
    if (editor.loaded_sort) |sort| allocator.free(sort);
    allocator.free(editor.playlist_ids);
    allocator.destroy(editor);
}

pub fn present(self: *App, playlist_id: ?i64) void {
    open(self, playlist_id, null, null);
}

/// Opens the editor on a new smart playlist named `name` with `rules_json`.
pub fn presentRules(self: *App, name: []const u8, rules_json: []const u8) void {
    open(self, null, name, rules_json);
}

fn newHeading(name: *gtk.Widget) *gtk.Widget {
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    const tile = gtk.gtk_image_new_from_icon_name("orca-sparkle-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, tile), 28);
    gtk.gtk_widget_add_css_class(tile, "smart-editor-tile");
    gtk.gtk_widget_set_size_request(tile, 64, 64);
    gtk.gtk_widget_set_valign(tile, gtk.ALIGN_CENTER);
    const words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), label("Smart playlist", "smart-overline"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), tile);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), words);
    return heading;
}

fn newOptions(editor: *Editor) *gtk.Widget {
    const card = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(card, "smart-options");

    const limit_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(limit_row, "smart-option");
    const limit_label = label("Limit to", "smart-option-title");
    gtk.gtk_widget_set_hexpand(limit_label, gtk.true_);
    gtk.gtk_widget_set_size_request(editor.limit, 64, -1);
    for ([_]*gtk.Widget{
        limit_label,
        editor.limit,
        gtk.cast(gtk.Widget, editor.limit_unit),
        caption("selected by"),
        gtk.cast(gtk.Widget, editor.sort),
    }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, limit_row), child);

    const live_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(live_row, "smart-option");
    gtk.gtk_widget_add_css_class(live_row, "smart-option-divided");
    const live_words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_set_hexpand(live_words, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, live_words), label("Live updating", "smart-option-title"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, live_words), label("Re-evaluates as your library and listening change", "smart-option-detail"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, live_row), live_words);
    gtk.gtk_box_append(gtk.cast(gtk.Box, live_row), label("Smart playlists always reflect your library", "smart-option-detail"));

    gtk.gtk_box_append(gtk.cast(gtk.Box, card), limit_row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), live_row);
    return card;
}

fn newPreview(editor: *Editor) *gtk.Widget {
    const card = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(card, "smart-preview");
    gtk.gtk_widget_set_size_request(card, 380, -1);
    gtk.gtk_widget_set_hexpand(card, gtk.false_);
    gtk.gtk_widget_set_valign(card, gtk.ALIGN_START);

    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const title = label("Live preview", "smart-preview-heading");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), label("Updated as you edit", "smart-option-detail"));

    const totals = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(gtk.cast(gtk.Widget, editor.summary), gtk.ALIGN_BASELINE_FILL);
    gtk.gtk_widget_set_valign(gtk.cast(gtk.Widget, editor.count), gtk.ALIGN_BASELINE_FILL);
    gtk.gtk_box_append(gtk.cast(gtk.Box, totals), gtk.cast(gtk.Widget, editor.count));
    gtk.gtk_box_append(gtk.cast(gtk.Box, totals), gtk.cast(gtk.Widget, editor.summary));

    for ([_]*gtk.Widget{ heading, totals, editor.sample, gtk.cast(gtk.Widget, editor.more) }) |child|
        gtk.gtk_box_append(gtk.cast(gtk.Box, card), child);
    return card;
}

fn open(self: *App, playlist_id: ?i64, new_name: ?[]const u8, new_rules: ?[]const u8) void {
    const library = self.library orelse return self.toast("No library is open");
    const navigation = self.playlists.navigation orelse return;
    const known = playlists.choices(self);
    const playlist_ids = self.allocator.alloc(i64, known.len) catch return self.toast("Out of memory");
    const playlist_names = gtk.gtk_string_list_new(null);
    for (known, playlist_ids) |choice, *id| {
        id.* = choice.id;
        gtk.gtk_string_list_append(playlist_names, choice.name.ptr);
    }
    const editor = self.allocator.create(Editor) catch {
        self.allocator.free(playlist_ids);
        gtk.g_object_unref(playlist_names);
        return self.toast("Out of memory");
    };

    const name = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(name, "smart-name");
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, name), "Smart Playlist");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    const sort_labels = comptime labels: {
        var all: [sorts.len + 1]?[*:0]const u8 = undefined;
        for (sorts, 0..) |sort, index| all[index] = sort.label;
        all[sorts.len] = null;
        break :labels all;
    };
    const sort_model = gtk.gtk_string_list_new(&sort_labels);
    const sort = dropDown(gtk.cast(gtk.ListModel, sort_model), "Selected by");
    gtk.gtk_widget_set_size_request(sort, 168, -1);
    const limit_unit = dropDownOf(&limit_units, "Limit unit");
    const limit = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(limit, "smart-control");
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, limit), "All");
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, limit), 3);
    gtk.gtk_editable_set_max_width_chars(gtk.cast(gtk.Editable, limit), 3);
    const count = label("", "smart-preview-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    const summary = label("", "smart-preview-summary");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, summary), gtk.true_);
    gtk.gtk_widget_set_hexpand(summary, gtk.true_);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, summary), 1);
    const sample = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(sample, "smart-preview-list");
    const more = label("", "smart-option-detail");
    editor.* = .{
        .self = self,
        .playlist_id = playlist_id,
        .page = undefined,
        .name = name,
        .root = undefined,
        .sort = gtk.cast(gtk.DropDown, sort),
        .sort_labels = sort_model,
        .limit = limit,
        .limit_unit = gtk.cast(gtk.DropDown, limit_unit),
        .count = gtk.cast(gtk.Label, count),
        .summary = gtk.cast(gtk.Label, summary),
        .sample = sample,
        .more = gtk.cast(gtk.Label, more),
        .playlist_ids = playlist_ids,
        .playlist_names = playlist_names,
    };
    editor.root = newGroup(editor, 1);

    if (playlist_id) |id| {
        if (self.runtime.libraryPlaylist(library, id)) |playlist| {
            defer playlist.deinit(self.runtime.allocator);
            setText(name, playlist.name);
        } else |_| {}
        if (self.runtime.librarySmartPlaylistRules(library, id) catch null) |json| {
            defer self.runtime.allocator.free(json);
            loadRules(editor, json);
        }
    } else if (new_rules) |json| {
        setText(name, new_name orelse "");
        loadRules(editor, json);
    } else gtk.gtk_box_append(gtk.cast(gtk.Box, part(editor.root, "orca-items").?), newRule(editor, false));
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(selectionChanged), editor);
    _ = gtk.signalConnect(limit_unit, "notify::selected", gtk.callback(selectionChanged), editor);
    _ = gtk.signalConnect(limit, "changed", gtk.callback(somethingChanged), editor);

    const editing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 22);
    gtk.gtk_widget_set_hexpand(editing, gtk.true_);
    for ([_]*gtk.Widget{ newHeading(name), editor.root, newOptions(editor) }) |child|
        gtk.gtk_box_append(gtk.cast(gtk.Box, editing), child);

    const columns = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(columns, "smart-columns");
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), editing);
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), newPreview(editor));

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_AUTOMATIC, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), columns);

    gtk.gtk_widget_add_css_class(scroller, "smart-editor");
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(destroyed), editor);
    showPreview(editor);

    const title: [*:0]const u8 = if (playlist_id == null) "New Smart Playlist" else "Edit Smart Playlist";
    const page = adw.adw_navigation_page_new(scroller, title);
    editor.page = page;
    gtk.g_object_set_data(page, editor_key, editor);
    window.showPage(self, .playlists);
    popEditor(self, navigation);
    adw.adw_navigation_view_push(navigation, page);
    if (self.window) |root| gtk.gtk_window_set_focus(root, null);
    gtk.gtk_editable_set_position(gtk.cast(gtk.Editable, name), -1);
}

fn popEditor(self: *App, navigation: *adw.NavigationView) void {
    var at = adw.adw_navigation_view_get_visible_page(navigation);
    while (at) |shown_page| : (at = adw.adw_navigation_view_get_previous_page(navigation, shown_page)) {
        if (editorOfPage(shown_page) == null) continue;
        const previous = adw.adw_navigation_view_get_previous_page(navigation, shown_page) orelse return;
        return window.popToPage(self, navigation, previous);
    }
}
