//! The Albums page's Filters popover. Every filter is a field of the engine's
//! `ReleaseQuery`; the controls take effect on Apply.

const std = @import("std");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const strings = @import("strings.zig");
const albums = @import("albums.zig");

const App = app.App;

pub const Artwork = enum { any, with, without };

pub const Filters = struct {
    genre_id: ?i64 = null,
    year_from: ?i32 = null,
    year_to: ?i32 = null,
    lossless_only: bool = false,
    artwork: Artwork = .any,

    /// How many filters are set; a year range counts once.
    pub fn count(self: Filters) usize {
        var result: usize = 0;
        if (self.genre_id != null) result += 1;
        if (self.year_from != null or self.year_to != null) result += 1;
        if (self.lossless_only) result += 1;
        if (self.artwork != .any) result += 1;
        return result;
    }

    pub fn hasArtwork(self: Filters) ?bool {
        return switch (self.artwork) {
            .any => null,
            .with => true,
            .without => false,
        };
    }
};

/// The popover's widgets and the genre ids behind its dropdown's entries.
pub const Ui = struct {
    button: ?*gtk.Widget = null,
    popover: ?*gtk.Widget = null,
    genre: ?*gtk.DropDown = null,
    genre_names: ?*gtk.StringList = null,
    genre_ids: std.ArrayList(i64) = .empty,
    year_from: ?*gtk.Editable = null,
    year_to: ?*gtk.Editable = null,
    formats: [2]?*gtk.ToggleButton = @splat(null),
    artwork: [std.meta.fields(Artwork).len]?*gtk.ToggleButton = @splat(null),

    pub fn deinit(self: *Ui, allocator: std.mem.Allocator) void {
        self.genre_ids.deinit(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

/// A four-digit year, or null for anything else.
fn parseYear(editable: ?*gtk.Editable) ?i32 {
    const text = std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(editable orelse return null)), " ");
    if (text.len != 4) return null;
    return std.fmt.parseInt(i32, text, 10) catch null;
}

fn chosen(self: *App) Filters {
    const ui = &self.album_filters_ui;
    var filters: Filters = .{};
    if (ui.genre) |genre| {
        const index = gtk.gtk_drop_down_get_selected(genre);
        if (index != 0 and index != gtk.INVALID_LIST_POSITION and index - 1 < ui.genre_ids.items.len)
            filters.genre_id = ui.genre_ids.items[index - 1];
    }
    filters.year_from = parseYear(ui.year_from);
    filters.year_to = parseYear(ui.year_to);
    if (ui.formats[1]) |lossless| filters.lossless_only = gtk.gtk_toggle_button_get_active(lossless) != 0;
    for (ui.artwork, 0..) |toggle, index| {
        const button = toggle orelse continue;
        if (gtk.gtk_toggle_button_get_active(button) != 0) filters.artwork = @enumFromInt(index);
    }
    return filters;
}

fn setYear(editable: ?*gtk.Editable, year: ?i32) void {
    const entry = editable orelse return;
    var buffer: [16]u8 = undefined;
    const text: [:0]const u8 = if (year) |value| strings.format(&buffer, "{d}", .{value}) else "";
    gtk.gtk_editable_set_text(entry, text.ptr);
}

/// Sets the controls to what is applied, so edits left without Apply are
/// dropped.
fn showFilters(self: *App) void {
    const ui = &self.album_filters_ui;
    const filters = self.album_filters;
    setYear(ui.year_from, filters.year_from);
    setYear(ui.year_to, filters.year_to);
    if (ui.formats[@intFromBool(filters.lossless_only)]) |toggle| gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
    if (ui.artwork[@intFromEnum(filters.artwork)]) |toggle| gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
}

pub fn showActive(self: *App) void {
    const button = self.album_filters_ui.button orelse return;
    const active = self.album_filters.count();
    var buffer: [32]u8 = undefined;
    const label: [:0]const u8 = if (active == 0) "Filters" else strings.format(&buffer, "Filters • {d}", .{active});
    gtk.gtk_menu_button_set_label(gtk.cast(gtk.MenuButton, button), label.ptr);
    if (active != 0)
        gtk.gtk_widget_add_css_class(button, "filters-active")
    else
        gtk.gtk_widget_remove_css_class(button, "filters-active");
}

fn apply(self: *App, filters: Filters) void {
    if (self.album_filters_ui.popover) |popover| gtk.gtk_popover_popdown(gtk.cast(gtk.Popover, popover));
    if (std.meta.eql(filters, self.album_filters)) return;
    self.album_filters = filters;
    showActive(self);
    albums.reload(self);
}

fn applyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    apply(self, chosen(self));
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    apply(state(data), .{});
}

/// Refills the genre list with every genre each time the popover opens,
/// keeping the applied genre selected.
fn popoverShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const ui = &self.album_filters_ui;
    showFilters(self);
    const names = ui.genre_names orelse return;
    const genre = ui.genre orelse return;
    const library = self.library orelse return;
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
            if (self.album_filters.genre_id == item.id) selected = @intCast(ui.genre_ids.items.len);
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

fn yearEntry(placeholder: [*:0]const u8) *gtk.Widget {
    const entry = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), placeholder);
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, entry), 5);
    gtk.gtk_widget_set_hexpand(entry, gtk.true_);
    return entry;
}

fn choices(labels: []const [*:0]const u8, toggles: []?*gtk.ToggleButton) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "linked");
    for (labels, toggles, 0..) |label, *slot, index| {
        const toggle = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, toggle), label);
        gtk.gtk_widget_set_hexpand(toggle, gtk.true_);
        slot.* = gtk.cast(gtk.ToggleButton, toggle);
        if (index != 0) gtk.gtk_toggle_button_set_group(slot.*.?, toggles[0].?);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), toggle);
    }
    gtk.gtk_toggle_button_set_active(toggles[0].?, gtk.true_);
    return box;
}

/// The Filters button for the Albums title row.
pub fn build(self: *App) *gtk.Widget {
    const ui = &self.album_filters_ui;
    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(list, "song-filters");

    const names = gtk.gtk_string_list_new(null);
    gtk.gtk_string_list_append(names, "Any genre");
    ui.genre_names = names;
    const genre = gtk.gtk_drop_down_new(gtk.cast(gtk.ListModel, names), null);
    ui.genre = gtk.cast(gtk.DropDown, genre);
    row(list, "Genre", genre);

    const years = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const from = yearEntry("From");
    const to = yearEntry("To");
    ui.year_from = gtk.cast(gtk.Editable, from);
    ui.year_to = gtk.cast(gtk.Editable, to);
    gtk.gtk_box_append(gtk.cast(gtk.Box, years), from);
    gtk.gtk_box_append(gtk.cast(gtk.Box, years), gtk.gtk_label_new("–"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, years), to);
    row(list, "Year", years);

    row(list, "Format", choices(&.{ "Any", "Lossless only" }, &ui.formats));
    row(list, "Has artwork", choices(&.{ "Any", "Yes", "No" }, &ui.artwork));

    const clear = gtk.gtk_button_new_with_label("Clear");
    const apply_button = gtk.gtk_button_new_with_label("Apply");
    gtk.gtk_widget_add_css_class(apply_button, "suggested-action");
    _ = gtk.signalConnect(clear, "clicked", gtk.callback(clearClicked), self);
    _ = gtk.signalConnect(apply_button, "clicked", gtk.callback(applyClicked), self);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), clear);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), apply_button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, list), actions);

    const popover = gtk.gtk_popover_new();
    ui.popover = popover;
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), list);
    gtk.gtk_popover_set_default_widget(gtk.cast(gtk.Popover, popover), apply_button);
    _ = gtk.signalConnect(popover, "show", gtk.callback(popoverShown), self);

    const button = gtk.gtk_menu_button_new();
    ui.button = button;
    gtk.gtk_menu_button_set_label(gtk.cast(gtk.MenuButton, button), "Filters");
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "filters-button");
    gtk.gtk_widget_set_tooltip_text(button, "Filter albums");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    showActive(self);
    return button;
}
