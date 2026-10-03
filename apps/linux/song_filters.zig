//! The Songs page's Filters popover. Every filter is a field of the engine's
//! `TrackQuery`, with or without search text.

const std = @import("std");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const strings = @import("strings.zig");

const App = app.App;

pub const Format = enum { any, lossless, lossy };

const sample_rates = [_]?u32{ null, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000 };
const sample_rate_labels = [_]?[*:0]const u8{ "Any", "44.1 kHz", "48 kHz", "88.2 kHz", "96 kHz", "176.4 kHz", "192 kHz", null };

pub const Filters = struct {
    genre_id: ?i64 = null,
    year_from: ?i32 = null,
    year_to: ?i32 = null,
    format: Format = .any,
    min_sample_rate: ?u32 = null,
    loved_only: bool = false,
    explicit_only: bool = false,

    pub fn active(self: Filters) bool {
        return !std.meta.eql(self, Filters{});
    }
};

/// The popover's widgets and the genre ids behind its dropdown's entries.
pub const Ui = struct {
    button: ?*gtk.Widget = null,
    genre: ?*gtk.DropDown = null,
    genre_names: ?*gtk.StringList = null,
    genre_ids: std.ArrayList(i64) = .empty,
    year_from: ?*gtk.Editable = null,
    year_to: ?*gtk.Editable = null,
    formats: [3]?*gtk.ToggleButton = @splat(null),
    sample_rate: ?*gtk.DropDown = null,
    loved: ?*gtk.CheckButton = null,
    explicit: ?*gtk.CheckButton = null,
    suppress: bool = false,

    pub fn deinit(self: *Ui, allocator: std.mem.Allocator) void {
        self.genre_ids.deinit(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

/// A four-digit year, or null for anything else, including a year still
/// being typed.
fn parseYear(editable: ?*gtk.Editable) ?i32 {
    const text = std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(editable orelse return null)), " ");
    if (text.len != 4) return null;
    return std.fmt.parseInt(i32, text, 10) catch null;
}

fn changed(self: *App) void {
    const ui = &self.song_filters_ui;
    if (ui.suppress) return;
    var filters: Filters = .{};
    if (ui.genre) |genre| {
        const index = gtk.gtk_drop_down_get_selected(genre);
        if (index != 0 and index != gtk.INVALID_LIST_POSITION and index - 1 < ui.genre_ids.items.len)
            filters.genre_id = ui.genre_ids.items[index - 1];
    }
    filters.year_from = parseYear(ui.year_from);
    filters.year_to = parseYear(ui.year_to);
    for (ui.formats, 0..) |toggle, index| {
        const button = toggle orelse continue;
        if (gtk.gtk_toggle_button_get_active(button) != 0) filters.format = @enumFromInt(index);
    }
    if (ui.sample_rate) |dropdown| {
        const index = gtk.gtk_drop_down_get_selected(dropdown);
        if (index < sample_rates.len) filters.min_sample_rate = sample_rates[index];
    }
    if (ui.loved) |check| filters.loved_only = gtk.gtk_check_button_get_active(check) != 0;
    if (ui.explicit) |check| filters.explicit_only = gtk.gtk_check_button_get_active(check) != 0;
    if (std.meta.eql(filters, self.song_filters)) return;
    self.song_filters = filters;
    showActive(self);
    self.reload();
}

fn showActive(self: *App) void {
    const button = self.song_filters_ui.button orelse return;
    if (self.song_filters.active())
        gtk.gtk_widget_add_css_class(button, "filters-active")
    else
        gtk.gtk_widget_remove_css_class(button, "filters-active");
}

fn controlChanged(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    changed(state(data));
}

fn propertyChanged(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    changed(state(data));
}

fn resetControls(ui: *Ui) void {
    if (ui.genre) |genre| gtk.gtk_drop_down_set_selected(genre, 0);
    if (ui.year_from) |entry| gtk.gtk_editable_set_text(entry, "");
    if (ui.year_to) |entry| gtk.gtk_editable_set_text(entry, "");
    if (ui.formats[0]) |any| gtk.gtk_toggle_button_set_active(any, gtk.true_);
    if (ui.sample_rate) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, 0);
    if (ui.loved) |check| gtk.gtk_check_button_set_active(check, gtk.false_);
    if (ui.explicit) |check| gtk.gtk_check_button_set_active(check, gtk.false_);
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const ui = &self.song_filters_ui;
    ui.suppress = true;
    resetControls(ui);
    ui.suppress = false;
    changed(self);
}

pub fn showGenre(self: *App, genre_id: i64) void {
    const ui = &self.song_filters_ui;
    ui.suppress = true;
    resetControls(ui);
    ui.suppress = false;
    self.song_filters = .{ .genre_id = genre_id };
    showActive(self);
}

/// Refills the genre list with every genre each time the popover opens,
/// keeping the chosen genre selected.
fn popoverShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const ui = &self.song_filters_ui;
    const names = ui.genre_names orelse return;
    const genre = ui.genre orelse return;
    const library = self.library orelse return;
    ui.suppress = true;
    defer ui.suppress = false;
    const count = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, names));
    if (count > 1) gtk.gtk_string_list_splice(names, 1, count - 1, null);
    ui.genre_ids.clearRetainingCapacity();
    var selected: c_uint = 0;
    var offset: u32 = 0;
    while (true) {
        var page = self.runtime.libraryGenrePage(library, .{
            .sort = .name,
            .limit = app.page_size,
            .offset = offset,
        }) catch {
            self.toast("Unable to list the genres");
            break;
        };
        defer page.deinit();
        for (page.items) |item| {
            var buffer: [256]u8 = undefined;
            const name = strings.format(&buffer, "{s}", .{item.name});
            if (name.len == 0) continue;
            ui.genre_ids.append(self.allocator, item.id) catch break;
            gtk.gtk_string_list_append(names, name.ptr);
            if (self.song_filters.genre_id == item.id) selected = @intCast(ui.genre_ids.items.len);
        }
        if (page.items.len < app.page_size) break;
        offset += @intCast(page.items.len);
    }
    gtk.gtk_drop_down_set_selected(genre, selected);
}

fn fieldLabel(text: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_widget_add_css_class(label, "filters-label");
    gtk.gtk_widget_set_size_request(label, 116, -1);
    return label;
}

fn row(list: *gtk.Widget, text: [*:0]const u8, control: *gtk.Widget) void {
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), fieldLabel(text));
    gtk.gtk_widget_set_hexpand(control, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), control);
    gtk.gtk_box_append(gtk.cast(gtk.Box, list), line);
}

fn yearEntry(self: *App, placeholder: [*:0]const u8) *gtk.Widget {
    const entry = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), placeholder);
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, entry), 5);
    gtk.gtk_widget_set_hexpand(entry, gtk.true_);
    _ = gtk.signalConnect(entry, "changed", gtk.callback(controlChanged), self);
    return entry;
}

/// The Filters button for the Songs page header.
pub fn build(self: *App) *gtk.Widget {
    const ui = &self.song_filters_ui;
    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(list, "song-filters");

    const names = gtk.gtk_string_list_new(null);
    gtk.gtk_string_list_append(names, "Any genre");
    ui.genre_names = names;
    const genre = gtk.gtk_drop_down_new(gtk.cast(gtk.ListModel, names), null);
    ui.genre = gtk.cast(gtk.DropDown, genre);
    _ = gtk.signalConnect(genre, "notify::selected", gtk.callback(propertyChanged), self);
    row(list, "Genre", genre);

    const years = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const from = yearEntry(self, "From");
    const to = yearEntry(self, "To");
    ui.year_from = gtk.cast(gtk.Editable, from);
    ui.year_to = gtk.cast(gtk.Editable, to);
    gtk.gtk_box_append(gtk.cast(gtk.Box, years), from);
    gtk.gtk_box_append(gtk.cast(gtk.Box, years), gtk.gtk_label_new("–"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, years), to);
    row(list, "Year", years);

    const formats = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(formats, "linked");
    for ([_][*:0]const u8{ "Any", "Lossless", "Lossy" }, 0..) |label, index| {
        const toggle = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, toggle), label);
        gtk.gtk_widget_set_hexpand(toggle, gtk.true_);
        ui.formats[index] = gtk.cast(gtk.ToggleButton, toggle);
        if (index != 0) gtk.gtk_toggle_button_set_group(ui.formats[index].?, ui.formats[0].?);
        gtk.gtk_box_append(gtk.cast(gtk.Box, formats), toggle);
    }
    gtk.gtk_toggle_button_set_active(ui.formats[0].?, gtk.true_);
    for (ui.formats) |toggle| _ = gtk.signalConnect(toggle.?, "toggled", gtk.callback(controlChanged), self);
    row(list, "Format", formats);

    const rate = gtk.gtk_drop_down_new_from_strings(&sample_rate_labels);
    ui.sample_rate = gtk.cast(gtk.DropDown, rate);
    _ = gtk.signalConnect(rate, "notify::selected", gtk.callback(propertyChanged), self);
    row(list, "Min. sample rate", rate);

    const checks = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    const loved_check = gtk.gtk_check_button_new_with_label("Loved only");
    const explicit_check = gtk.gtk_check_button_new_with_label("Explicit only");
    ui.loved = gtk.cast(gtk.CheckButton, loved_check);
    ui.explicit = gtk.cast(gtk.CheckButton, explicit_check);
    _ = gtk.signalConnect(loved_check, "toggled", gtk.callback(controlChanged), self);
    _ = gtk.signalConnect(explicit_check, "toggled", gtk.callback(controlChanged), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, checks), loved_check);
    gtk.gtk_box_append(gtk.cast(gtk.Box, checks), explicit_check);
    gtk.gtk_box_append(gtk.cast(gtk.Box, list), checks);

    const clear = gtk.gtk_button_new_with_label("Clear Filters");
    gtk.gtk_widget_set_halign(clear, gtk.ALIGN_END);
    _ = gtk.signalConnect(clear, "clicked", gtk.callback(clearClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, list), clear);

    const popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), list);
    _ = gtk.signalConnect(popover, "show", gtk.callback(popoverShown), self);

    const button = gtk.gtk_menu_button_new();
    ui.button = button;
    gtk.gtk_menu_button_set_label(gtk.cast(gtk.MenuButton, button), "Filters");
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "filters-button");
    gtk.gtk_widget_set_tooltip_text(button, "Filter songs");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}
