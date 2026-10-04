const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const playlists = @import("playlists.zig");

const App = app.App;

const count_delay_ms = 250;
const max_depth = 4;
const indent: c_int = 20;

const Type = enum { text, integer, date, boolean };

const Field = struct {
    name: []const u8,
    label: [*:0]const u8,
    type: Type,
    scale: i64 = 1,
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
    .{ .name = "play_count", .label = "Play Count", .type = .integer },
    .{ .name = "rating", .label = "Rating (1–100)", .type = .integer },
    .{ .name = "duration_ms", .label = "Duration (seconds)", .type = .integer, .scale = 1000 },
    .{ .name = "sample_rate", .label = "Sample Rate (Hz)", .type = .integer },
    .{ .name = "bit_depth", .label = "Bit Depth", .type = .integer },
    .{ .name = "added_at", .label = "Date Added", .type = .date },
    .{ .name = "last_played_at", .label = "Last Played", .type = .date },
    .{ .name = "loved", .label = "Loved", .type = .boolean },
    .{ .name = "lossless", .label = "Lossless", .type = .boolean },
    .{ .name = "explicit", .label = "Explicit", .type = .boolean },
    .{ .name = "has_artwork", .label = "Has Artwork", .type = .boolean },
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
        .boolean => &boolean_operators,
    };
}

const Sort = struct {
    name: ?[]const u8,
    label: [*:0]const u8,
};

const sorts = [_]Sort{
    .{ .name = null, .label = "Default order" },
    .{ .name = "artist", .label = "Artist" },
    .{ .name = "album", .label = "Album" },
    .{ .name = "title", .label = "Title" },
    .{ .name = "track_number", .label = "Track Number" },
    .{ .name = "duration", .label = "Duration" },
    .{ .name = "date_added", .label = "Date Added" },
    .{ .name = "rating", .label = "Rating" },
    .{ .name = "loved", .label = "Loved" },
    .{ .name = "play_count", .label = "Play Count" },
    .{ .name = "last_played", .label = "Last Played" },
    .{ .name = "year", .label = "Year" },
    .{ .name = "id", .label = "Library Order" },
};

const sort_aliases = [_]struct { alias: []const u8, name: []const u8 }{
    .{ .alias = "added_at", .name = "date_added" },
    .{ .alias = "last_played_at", .name = "last_played" },
    .{ .alias = "duration_ms", .name = "duration" },
};

const Value = enum { none, one, two, days, boolean };

fn valueOf(field_type: Type, operator: []const u8) Value {
    if (std.mem.eql(u8, operator, "is_set") or std.mem.eql(u8, operator, "is_not_set")) return .none;
    if (field_type == .boolean) return .boolean;
    if (std.mem.eql(u8, operator, "between")) return .two;
    if (std.mem.endsWith(u8, operator, "in_last_days")) return .days;
    return .one;
}

const Editor = struct {
    self: *App,
    playlist_id: ?i64,
    dialog: *adw.Dialog,
    name: *gtk.Widget,
    root: *gtk.Widget,
    sort: *gtk.DropDown,
    descending: *gtk.CheckButton,
    limit: *gtk.Widget,
    count: *gtk.Label,
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

fn fieldOf(row: *gtk.Widget) Field {
    const index = selected(part(row, "orca-field").?);
    return fields[if (index < fields.len) index else 0];
}

fn operatorOf(row: *gtk.Widget) Operator {
    const operators = operatorsOf(fieldOf(row).type);
    const index = selected(part(row, "orca-operator").?);
    return operators[if (index < operators.len) index else 0];
}

fn changed(editor: *Editor) void {
    if (editor.timer != 0) _ = gtk.g_source_remove(editor.timer);
    editor.timer = gtk.g_timeout_add(count_delay_ms, countLater, editor);
}

fn countLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const editor = editorOf(data);
    editor.timer = 0;
    showCount(editor);
    return gtk.SOURCE_REMOVE;
}

fn rulesError(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.InvalidSmartPlaylistRules => "These rules are not valid",
        error.UnknownRuleField => "A rule tests a field Orca does not know",
        error.UnknownRuleOperator => "A rule uses a comparison Orca does not know",
        error.RuleOperatorMismatch => "A comparison does not fit its field",
        error.InvalidRuleValue => "A rule's value is missing or out of range",
        error.RuleNestingTooDeep => "Groups nest at most four deep",
        error.TooManyRules => "At most 32 rules in all, and 32 in a group",
        error.PlaylistNameTaken => "A playlist with that name already exists",
        error.InvalidPlaylistName => "A smart playlist needs a name",
        error.UnknownPlaylist => "That playlist no longer exists",
        else => "Could not read these rules",
    };
}

fn showError(editor: *Editor, message: [:0]const u8) void {
    gtk.gtk_label_set_text(editor.count, message.ptr);
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, editor.count), "error");
}

fn showCount(editor: *Editor) void {
    const self = editor.self;
    const library = self.library orelse return;
    const json = rulesJson(editor) catch return showError(editor, "Out of memory");
    defer self.allocator.free(json);
    const matched = self.runtime.librarySmartPlaylistCount(library, json) catch |err| return showError(editor, rulesError(err));
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, editor.count), "error");
    var buffer: [64]u8 = undefined;
    gtk.gtk_label_set_text(editor.count, strings.printZ(&buffer, "{d} {s} match", .{ matched, if (matched == 1) "track" else "tracks" }) catch "");
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
        .integer => try writeNumber(writer, typed, field.scale),
        .date => try writeDate(writer, typed),
    }
}

fn writeRule(writer: *std.Io.Writer, row: *gtk.Widget) !void {
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
            try writeNumber(writer, text(part(row, "orca-days").?), 1);
        },
        .boolean => try writer.writeAll(if (selected(part(row, "orca-boolean").?) == 0) ",\"value\":true" else ",\"value\":false"),
    }
    try writer.writeByte('}');
}

fn writeGroup(writer: *std.Io.Writer, group: *gtk.Widget) !void {
    try writer.writeAll(if (selected(part(group, "orca-match").?) == 0) "\"match\":\"all\",\"rules\":[" else "\"match\":\"any\",\"rules\":[");
    var child = gtk.gtk_widget_get_first_child(part(group, "orca-items").?);
    var first = true;
    while (child) |item| : (child = gtk.gtk_widget_get_next_sibling(item)) {
        if (!first) try writer.writeByte(',');
        first = false;
        if (isGroup(item)) {
            try writer.writeByte('{');
            try writeGroup(writer, item);
            try writer.writeByte('}');
        } else try writeRule(writer, item);
    }
    try writer.writeByte(']');
}

fn writeRules(writer: *std.Io.Writer, editor: *Editor) !void {
    try writer.writeAll("{\"v\":1,");
    try writeGroup(writer, editor.root);
    const sort = gtk.gtk_drop_down_get_selected(editor.sort);
    if (sort < sorts.len) if (sorts[sort].name) |name| {
        try writer.writeAll(",\"sort\":{\"field\":");
        try std.json.Stringify.encodeJsonString(name, .{}, writer);
        try writer.writeAll(if (gtk.gtk_check_button_get_active(editor.descending) != 0) ",\"descending\":true}" else ",\"descending\":false}");
    };
    const limit = std.mem.trim(u8, text(editor.limit), " \t");
    if (limit.len != 0) {
        try writer.writeAll(",\"limit\":");
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
        .text, .boolean => "Text",
    };
    for ([_][*:0]const u8{ "orca-first", "orca-from", "orca-to" }) |key|
        gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, part(row, key).?), placeholder);
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
    var choice: c_uint = 0;
    for (operators, 0..) |operator, index| {
        if (std.mem.eql(u8, operator.name, keep)) choice = @intCast(index);
    }
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, part(row, "orca-operator").?), choice);
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

fn entry(editor: *Editor, width: c_int) *gtk.Widget {
    const widget = gtk.gtk_entry_new();
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, widget), width);
    _ = gtk.signalConnect(widget, "changed", gtk.callback(somethingChanged), editor);
    return widget;
}

fn caption(words: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(words);
    gtk.gtk_widget_add_css_class(widget, "dim-label");
    return widget;
}

fn removeButton(editor: *Editor, target: *gtk.Widget, tooltip: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name("list-remove-symbolic");
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "circular");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.g_object_set_data(button, "orca-target", target);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(removeClicked), editor);
    return button;
}

fn newValue(editor: *Editor, row: *gtk.Widget) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    gtk.gtk_stack_set_hhomogeneous(gtk.cast(gtk.Stack, stack), gtk.false_);
    gtk.gtk_widget_set_hexpand(stack, gtk.true_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0), "none");

    const first = entry(editor, 12);
    gtk.gtk_widget_set_hexpand(first, gtk.true_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), first, "one");

    const range = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const from = entry(editor, 8);
    const to = entry(editor, 8);
    for ([_]*gtk.Widget{ from, caption("and"), to }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, range), child);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), range, "two");

    const days_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const days = entry(editor, 5);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, days), "30");
    gtk.gtk_box_append(gtk.cast(gtk.Box, days_box), days);
    gtk.gtk_box_append(gtk.cast(gtk.Box, days_box), caption("days"));
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), days_box, "days");

    const answers = [_]?[*:0]const u8{ "Yes", "No", null };
    const boolean = gtk.gtk_drop_down_new_from_strings(&answers);
    gtk.gtk_widget_set_halign(boolean, gtk.ALIGN_START);
    _ = gtk.signalConnect(boolean, "notify::selected", gtk.callback(selectionChanged), editor);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), boolean, "boolean");

    gtk.g_object_set_data(row, "orca-value", stack);
    gtk.g_object_set_data(row, "orca-first", first);
    gtk.g_object_set_data(row, "orca-from", from);
    gtk.g_object_set_data(row, "orca-to", to);
    gtk.g_object_set_data(row, "orca-days", days);
    gtk.g_object_set_data(row, "orca-boolean", boolean);
    return stack;
}

fn newRule(editor: *Editor) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(row, "smart-rule");
    const controls = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, controls), 6);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, controls), 6);
    gtk.gtk_widget_set_hexpand(controls, gtk.true_);

    var field_labels: [fields.len + 1]?[*:0]const u8 = undefined;
    for (fields, 0..) |field, index| field_labels[index] = field.label;
    field_labels[fields.len] = null;
    const field = gtk.gtk_drop_down_new_from_strings(&field_labels);
    gtk.gtk_widget_set_tooltip_text(field, "Field");
    const operators = gtk.gtk_string_list_new(null);
    const operator = gtk.gtk_drop_down_new(gtk.cast(gtk.ListModel, operators), null);
    gtk.gtk_widget_set_tooltip_text(operator, "Comparison");
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

    for ([_]*gtk.Widget{ field, operator, value }) |child| adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, controls), child);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), controls);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), removeButton(editor, row, "Remove Rule"));
    return row;
}

fn addRuleClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const group = part(gtk.cast(gtk.Widget, button.?), "orca-target") orelse return;
    gtk.gtk_box_append(gtk.cast(gtk.Box, part(group, "orca-items").?), newRule(editor));
    changed(editor);
}

fn addGroupClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const group = part(gtk.cast(gtk.Widget, button.?), "orca-target") orelse return;
    const nested = newGroup(editor, depthOf(group) + 1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, part(nested, "orca-items").?), newRule(editor));
    gtk.gtk_box_append(gtk.cast(gtk.Box, part(group, "orca-items").?), nested);
    changed(editor);
}

fn addButton(editor: *Editor, group: *gtk.Widget, words: [*:0]const u8, handler: gtk.GCallback) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(words);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "smart-add");
    gtk.g_object_set_data(button, "orca-target", group);
    _ = gtk.signalConnect(button, "clicked", handler, editor);
    return button;
}

fn newGroup(editor: *Editor, depth: usize) *gtk.Widget {
    const group = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_add_css_class(group, if (depth == 1) "smart-root" else "smart-group");
    gtk.g_object_set_data(group, "orca-depth", @ptrFromInt(depth));
    if (depth > 1) gtk.gtk_widget_set_margin_start(group, indent);

    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const choices = [_]?[*:0]const u8{ "all", "any", null };
    const match = gtk.gtk_drop_down_new_from_strings(&choices);
    gtk.gtk_widget_set_tooltip_text(match, "Whether every rule must match, or any one");
    _ = gtk.signalConnect(match, "notify::selected", gtk.callback(selectionChanged), editor);
    gtk.g_object_set_data(group, "orca-match", match);
    const lead = caption(if (depth == 1) "Match" else "Tracks that match");
    const tail = caption(if (depth == 1) "of the following rules" else "of these rules");
    gtk.gtk_widget_set_hexpand(tail, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, tail), 0);
    for ([_]*gtk.Widget{ lead, match, tail }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, heading), child);
    if (depth > 1) gtk.gtk_box_append(gtk.cast(gtk.Box, heading), removeButton(editor, group, "Remove Group"));

    const items = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.g_object_set_data(group, "orca-items", items);

    const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), addButton(editor, group, "Add Rule", gtk.callback(addRuleClicked)));
    const add_group = addButton(editor, group, "Add Group", gtk.callback(addGroupClicked));
    if (depth >= max_depth) {
        gtk.gtk_widget_set_sensitive(add_group, gtk.false_);
        gtk.gtk_widget_set_tooltip_text(add_group, "Groups nest at most four deep");
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), add_group);

    for ([_]*gtk.Widget{ heading, items, footer }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, group), child);
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

fn loadRule(editor: *Editor, object: std.json.ObjectMap) *gtk.Widget {
    const row = newRule(editor);
    const field_name = stringOf(object.get("field")) orelse "";
    const operator_name = stringOf(object.get("op")) orelse "";
    var buffer: [32]u8 = undefined;
    const kept = strings.terminated(&buffer, operator_name);
    gtk.g_object_set_data(row, "orca-kept-operator", @constCast(kept.ptr));
    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, field_name))
            gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, part(row, "orca-field").?), @intCast(index));
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
        .days => showNumber(part(row, "orca-days").?, value, .{ .name = "", .label = "", .type = .integer }),
        .boolean => switch (value) {
            .bool => |yes| gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, part(row, "orca-boolean").?), if (yes) 0 else 1),
            else => {},
        },
    }
    return row;
}

fn loadGroup(editor: *Editor, group: *gtk.Widget, object: std.json.ObjectMap) void {
    if (stringOf(object.get("match"))) |match|
        gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, part(group, "orca-match").?), if (std.mem.eql(u8, match, "any")) 1 else 0);
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
        } else gtk.gtk_box_append(box, loadRule(editor, child));
    }
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
    if (root.get("sort")) |sort| switch (sort) {
        .object => |order| {
            var name = stringOf(order.get("field")) orelse "";
            for (sort_aliases) |alias| if (std.mem.eql(u8, alias.alias, name)) {
                name = alias.name;
            };
            for (sorts, 0..) |entry_, index| {
                if (entry_.name != null and std.mem.eql(u8, entry_.name.?, name)) gtk.gtk_drop_down_set_selected(editor.sort, @intCast(index));
            }
            if (order.get("descending")) |descending| switch (descending) {
                .bool => |yes| gtk.gtk_check_button_set_active(editor.descending, @intFromBool(yes)),
                else => {},
            };
        },
        else => {},
    };
    if (root.get("limit")) |limit| showNumber(editor.limit, limit, .{ .name = "", .label = "", .type = .integer });
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
    _ = adw.adw_dialog_close(editor.dialog);
    playlists.rulesSaved(self, playlist_id, created);
}

fn saveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    save(editorOf(data));
}

fn cancelClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = adw.adw_dialog_close(editorOf(data).dialog);
}

fn closed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    if (editor.timer != 0) _ = gtk.g_source_remove(editor.timer);
    editor.self.allocator.destroy(editor);
}

fn labelled(words: [*:0]const u8, control: *gtk.Widget) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const name = gtk.gtk_label_new(words);
    gtk.gtk_widget_add_css_class(name, "smart-label");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), control);
    return box;
}

pub fn present(self: *App, playlist_id: ?i64) void {
    const library = self.library orelse return self.toast("No library is open");
    const editor = self.allocator.create(Editor) catch return self.toast("Out of memory");

    const name = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, name), "Smart Playlist");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    const sort_labels = comptime labels: {
        var all: [sorts.len + 1]?[*:0]const u8 = undefined;
        for (sorts, 0..) |sort, index| all[index] = sort.label;
        all[sorts.len] = null;
        break :labels all;
    };
    const sort = gtk.gtk_drop_down_new_from_strings(&sort_labels);
    const descending = gtk.gtk_check_button_new_with_label("Descending");
    const limit = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, limit), "No limit");
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, limit), 8);
    const count = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(count, "smart-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, count), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, count), gtk.true_);
    const dialog = adw.adw_dialog_new();
    editor.* = .{
        .self = self,
        .playlist_id = playlist_id,
        .dialog = dialog,
        .name = name,
        .root = undefined,
        .sort = gtk.cast(gtk.DropDown, sort),
        .descending = gtk.cast(gtk.CheckButton, descending),
        .limit = limit,
        .count = gtk.cast(gtk.Label, count),
    };
    editor.root = newGroup(editor, 1);

    if (playlist_id) |id| {
        if (self.runtime.libraryPlaylist(library, id)) |summary| {
            defer summary.deinit(self.runtime.allocator);
            setText(name, summary.name);
        } else |_| {}
        if (self.runtime.librarySmartPlaylistRules(library, id) catch null) |json| {
            defer self.runtime.allocator.free(json);
            loadRules(editor, json);
        }
    } else gtk.gtk_box_append(gtk.cast(gtk.Box, part(editor.root, "orca-items").?), newRule(editor));
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(selectionChanged), editor);
    _ = gtk.signalConnect(descending, "toggled", gtk.callback(somethingChanged), editor);
    _ = gtk.signalConnect(limit, "changed", gtk.callback(somethingChanged), editor);

    const rules = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, rules), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(rules, gtk.true_);
    gtk.gtk_widget_add_css_class(rules, "smart-rules");
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, rules), editor.root);

    const order = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, order), 16);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, order), 8);
    gtk.gtk_widget_add_css_class(order, "smart-order");
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, order), labelled("Order by", sort));
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, order), descending);
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, order), labelled("Limit to", limit));

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(content, "smart-editor");
    for ([_]*gtk.Widget{ labelled("Name", name), rules, order, count }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, content), child);

    const header = adw.adw_header_bar_new();
    const cancel = gtk.gtk_button_new_with_label("Cancel");
    _ = gtk.signalConnect(cancel, "clicked", gtk.callback(cancelClicked), editor);
    const save_button = gtk.gtk_button_new_with_label(if (playlist_id == null) "Create" else "Save");
    gtk.gtk_widget_add_css_class(save_button, "suggested-action");
    _ = gtk.signalConnect(save_button, "clicked", gtk.callback(saveClicked), editor);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, header), cancel);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), save_button);
    adw.adw_header_bar_set_show_end_title_buttons(gtk.cast(adw.HeaderBar, header), gtk.false_);
    adw.adw_header_bar_set_show_start_title_buttons(gtk.cast(adw.HeaderBar, header), gtk.false_);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), content);

    adw.adw_dialog_set_title(dialog, if (playlist_id == null) "New Smart Playlist" else "Edit Smart Playlist");
    adw.adw_dialog_set_content_width(dialog, 720);
    adw.adw_dialog_set_content_height(dialog, 560);
    adw.adw_dialog_set_child(dialog, view);
    _ = gtk.signalConnect(dialog, "closed", gtk.callback(closed), editor);
    showCount(editor);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
