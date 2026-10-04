//! The Albums page's Filters popover and, in the large form, its facet chips.
//! Every filter is a field of the engine's `ReleaseQuery`; the popover's
//! controls take effect on Apply, a facet's when it is chosen.

const std = @import("std");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const strings = @import("strings.zig");
const albums = @import("albums.zig");
const settings = @import("settings.zig");

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
    label: ?*gtk.Label = null,
    popover: ?*gtk.Widget = null,
    genre: ?*gtk.DropDown = null,
    genre_names: ?*gtk.StringList = null,
    genre_ids: std.ArrayList(i64) = .empty,
    year_from: ?*gtk.Editable = null,
    year_to: ?*gtk.Editable = null,
    formats: [2]?*gtk.ToggleButton = @splat(null),
    artwork: [std.meta.fields(Artwork).len]?*gtk.ToggleButton = @splat(null),
    facets: Facets = .{},

    pub fn deinit(self: *Ui, allocator: std.mem.Allocator) void {
        self.genre_ids.deinit(allocator);
    }
};

pub const Facets = struct {
    lossless: ?*gtk.ToggleButton = null,
    lossless_clear: ?*gtk.Widget = null,
    added: ?*gtk.MenuButton = null,
    added_popover: ?*gtk.Widget = null,
    added_checks: [std.meta.fields(albums.Added.Window).len]?*gtk.CheckButton = @splat(null),
    genre: ?*gtk.MenuButton = null,
    genre_popover: ?*gtk.Widget = null,
    genre_selection: ?*gtk.SingleSelection = null,
    decade: ?*gtk.MenuButton = null,
    decade_popover: ?*gtk.Widget = null,
    decades: [max_decades]Decade = @splat(.{}),
    decade_checks: [max_decades]?*gtk.CheckButton = @splat(null),
    more: ?*gtk.MenuButton = null,
    more_popover: ?*gtk.Widget = null,
    shelf_checks: [std.meta.fields(albums.Shelf).len]?*gtk.CheckButton = @splat(null),
    artwork_checks: [std.meta.fields(Artwork).len]?*gtk.CheckButton = @splat(null),
};

const Decade = struct {
    from: ?i32 = null,
    to: ?i32 = null,
    label: [16:0]u8 = @splat(0),
};

const max_decades = 12;
const earliest_decade = 1950;
const shelf_labels = [_][*:0]const u8{ "All albums", "Loved", "High resolution", "Needs review" };
const artwork_labels = [_][*:0]const u8{ "With or without artwork", "With artwork", "Without artwork" };

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
    const text = self.album_filters_ui.label orelse return;
    const active = self.album_filters.count();
    var buffer: [32]u8 = undefined;
    const label: [:0]const u8 = if (active == 0) "Filters" else strings.format(&buffer, "Filters • {d}", .{active});
    gtk.gtk_label_set_text(text, label.ptr);
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
    albums.relist(self);
}

fn applyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    apply(self, chosen(self));
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    apply(state(data), .{});
}

fn refillGenres(self: *App) c_uint {
    const ui = &self.album_filters_ui;
    const names = ui.genre_names orelse return 0;
    const library = self.library orelse return 0;
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
    return selected;
}

fn popoverShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    showFilters(self);
    const genre = self.album_filters_ui.genre orelse return;
    gtk.gtk_drop_down_set_selected(genre, refillGenres(self));
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
    gtk.gtk_widget_add_css_class(list, "track-filters");

    const names = genreNames(ui);
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
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_image_new_from_icon_name("orca-filter-symbolic"));
    const label = gtk.gtk_label_new("Filters");
    ui.label = gtk.cast(gtk.Label, label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), label);
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), content);
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, button), gtk.false_);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "filters-button");
    gtk.gtk_widget_add_css_class(button, "btn-menu");
    gtk.gtk_widget_set_tooltip_text(button, "Filter albums");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    showActive(self);
    return button;
}

fn facetIndex(widget: ?*anyopaque) ?usize {
    const stored = gtk.g_object_get_data(widget.?, "orca-facet-index") orelse return null;
    return @intFromPtr(stored) - 1;
}

fn radio(
    self: *App,
    list: *gtk.Widget,
    label: [*:0]const u8,
    group: *?*gtk.CheckButton,
    index: usize,
    handler: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
) *gtk.CheckButton {
    const check = gtk.gtk_check_button_new_with_label(label);
    const button = gtk.cast(gtk.CheckButton, check);
    gtk.gtk_check_button_set_group(button, group.*);
    group.* = group.* orelse button;
    gtk.g_object_set_data(check, "orca-facet-index", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(check, "toggled", gtk.callback(handler), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, list), check);
    return button;
}

fn options() *gtk.Widget {
    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(list, "facet-options");
    return list;
}

fn heading(list: *gtk.Widget, text: [*:0]const u8) void {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_widget_add_css_class(label, "facet-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, list), label);
}

fn facetMenu(child: *gtk.Widget, tooltip: [*:0]const u8, slot: *?*gtk.Widget) *gtk.MenuButton {
    const popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), child);
    slot.* = popover;
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, button), gtk.true_);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "facet-chip");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    return gtk.cast(gtk.MenuButton, button);
}

fn popdown(popover: ?*gtk.Widget) void {
    if (popover) |shown| gtk.gtk_popover_popdown(gtk.cast(gtk.Popover, shown));
}

fn chosenCheck(self: *App, button: ?*anyopaque) ?usize {
    if (self.albums_syncing_controls) return null;
    if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, button.?)) == gtk.false_) return null;
    return facetIndex(button);
}

fn losslessToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.albums_syncing_controls) return;
    self.album_filters.lossless_only = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) != 0;
    showActive(self);
    albums.relist(self);
}

fn addedChecked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenCheck(self, button) orelse return;
    popdown(self.album_filters_ui.facets.added_popover);
    const window: albums.Added.Window = @enumFromInt(index);
    if (window == self.album_added.window) return;
    albums.setAdded(self, window);
    albums.relist(self);
}

fn decadeChecked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenCheck(self, button) orelse return;
    const facets = &self.album_filters_ui.facets;
    popdown(facets.decade_popover);
    const decade = facets.decades[index];
    if (decade.from == self.album_filters.year_from and decade.to == self.album_filters.year_to) return;
    self.album_filters.year_from = decade.from;
    self.album_filters.year_to = decade.to;
    showActive(self);
    albums.relist(self);
}

fn shelfChecked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenCheck(self, button) orelse return;
    popdown(self.album_filters_ui.facets.more_popover);
    const shelf: albums.Shelf = @enumFromInt(index);
    if (shelf == self.album_shelf) return;
    self.album_shelf = shelf;
    settings.save(self);
    albums.relist(self);
}

fn artworkChecked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = chosenCheck(self, button) orelse return;
    popdown(self.album_filters_ui.facets.more_popover);
    const artwork: Artwork = @enumFromInt(index);
    if (artwork == self.album_filters.artwork) return;
    self.album_filters.artwork = artwork;
    showActive(self);
    albums.relist(self);
}

fn genreActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const ui = &self.album_filters_ui;
    popdown(ui.facets.genre_popover);
    const genre_id: ?i64 = if (position == 0 or position - 1 >= ui.genre_ids.items.len) null else ui.genre_ids.items[position - 1];
    if (genre_id == self.album_filters.genre_id) return;
    self.album_filters.genre_id = genre_id;
    showActive(self);
    albums.relist(self);
}

fn genreShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const selection = self.album_filters_ui.facets.genre_selection orelse return;
    gtk.gtk_single_selection_set_selected(selection, refillGenres(self));
}

fn setupGenre(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), label);
}

fn bindGenre(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const label = gtk.gtk_list_item_get_child(list_item) orelse return;
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), gtk.gtk_string_object_get_string(gtk.cast(gtk.StringObject, object)));
}

fn genreNames(ui: *Ui) *gtk.StringList {
    if (ui.genre_names) |names| return names;
    const names = gtk.gtk_string_list_new(null);
    gtk.gtk_string_list_append(names, "Any genre");
    ui.genre_names = names;
    return names;
}

fn newGenreFacet(self: *App) *gtk.MenuButton {
    const facets = &self.album_filters_ui.facets;
    const selection = gtk.gtk_single_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(genreNames(&self.album_filters_ui))));
    gtk.gtk_single_selection_set_autoselect(selection, gtk.false_);
    facets.genre_selection = selection;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupGenre), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindGenre), self);
    const view = gtk.gtk_list_view_new(gtk.cast(gtk.SelectionModel, selection), factory);
    gtk.gtk_widget_add_css_class(view, "facet-genres");
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, view), gtk.true_);
    _ = gtk.signalConnect(view, "activate", gtk.callback(genreActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 360);
    gtk.gtk_widget_set_size_request(scroller, 220, -1);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    const button = facetMenu(scroller, "Filter by genre", &facets.genre_popover);
    _ = gtk.signalConnect(facets.genre_popover.?, "show", gtk.callback(genreShown), self);
    return button;
}

fn currentYear(self: *App) i32 {
    const seconds = std.Io.Clock.real.now(self.io).toSeconds();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    return epoch.getEpochDay().calculateYearDay().year;
}

fn newDecadeFacet(self: *App) *gtk.MenuButton {
    const facets = &self.album_filters_ui.facets;
    const list = options();
    var group: ?*gtk.CheckButton = null;
    var count: usize = 0;
    facets.decades[count] = .{};
    _ = std.fmt.bufPrintZ(&facets.decades[count].label, "Any year", .{}) catch {};
    count += 1;
    var start = currentYear(self) - @mod(currentYear(self), 10);
    while (start >= earliest_decade and count < max_decades - 1) : (start -= 10) {
        facets.decades[count] = .{ .from = start, .to = start + 9 };
        _ = std.fmt.bufPrintZ(&facets.decades[count].label, "{d}s", .{@as(u32, @intCast(start))}) catch {};
        count += 1;
    }
    facets.decades[count] = .{ .to = earliest_decade - 1 };
    _ = std.fmt.bufPrintZ(&facets.decades[count].label, "Before {d}", .{@as(u32, earliest_decade)}) catch {};
    count += 1;
    for (facets.decades[0..count], 0..) |*decade, index|
        facets.decade_checks[index] = radio(self, list, &decade.label, &group, index, decadeChecked);
    return facetMenu(list, "Filter by decade", &facets.decade_popover);
}

fn newMoreFacet(self: *App) *gtk.MenuButton {
    const facets = &self.album_filters_ui.facets;
    const list = options();
    heading(list, "Show");
    var shelves: ?*gtk.CheckButton = null;
    for (shelf_labels, 0..) |label, index|
        facets.shelf_checks[index] = radio(self, list, label, &shelves, index, shelfChecked);
    heading(list, "Artwork");
    var artwork: ?*gtk.CheckButton = null;
    for (artwork_labels, 0..) |label, index|
        facets.artwork_checks[index] = radio(self, list, label, &artwork, index, artworkChecked);
    const button = facetMenu(list, "More filters", &facets.more_popover);
    gtk.gtk_menu_button_set_label(button, "More filters");
    return button;
}

fn newAddedFacet(self: *App) *gtk.MenuButton {
    const facets = &self.album_filters_ui.facets;
    const list = options();
    var group: ?*gtk.CheckButton = null;
    for (std.enums.values(albums.Added.Window), 0..) |window, index|
        facets.added_checks[index] = radio(self, list, window.label(), &group, index, addedChecked);
    return facetMenu(list, "Filter by date added", &facets.added_popover);
}

fn newLosslessFacet(self: *App) *gtk.Widget {
    const facets = &self.album_filters_ui.facets;
    const toggle = gtk.gtk_toggle_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new("Lossless"));
    const clear = gtk.gtk_image_new_from_icon_name("window-close-symbolic");
    gtk.gtk_widget_add_css_class(clear, "facet-clear");
    gtk.gtk_widget_set_visible(clear, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), clear);
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, toggle), content);
    gtk.gtk_widget_add_css_class(toggle, "facet-chip");
    gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(toggle, "Lossless albums only");
    _ = gtk.signalConnect(toggle, "toggled", gtk.callback(losslessToggled), self);
    facets.lossless = gtk.cast(gtk.ToggleButton, toggle);
    facets.lossless_clear = clear;
    return toggle;
}

pub fn buildFacets(self: *App) *gtk.Widget {
    const facets = &self.album_filters_ui.facets;
    const row_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row_box), newLosslessFacet(self));
    facets.added = newAddedFacet(self);
    facets.genre = newGenreFacet(self);
    facets.decade = newDecadeFacet(self);
    facets.more = newMoreFacet(self);
    for ([_]*gtk.MenuButton{ facets.added.?, facets.genre.?, facets.decade.?, facets.more.? }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, row_box), gtk.cast(gtk.Widget, button));
    showFacets(self);
    return row_box;
}

fn markOn(widget: ?*anyopaque, on: bool) void {
    const chip = gtk.cast(gtk.Widget, widget orelse return);
    if (on) gtk.gtk_widget_add_css_class(chip, "chip-on") else gtk.gtk_widget_remove_css_class(chip, "chip-on");
}

fn activate(button: ?*gtk.CheckButton) void {
    if (button) |chosen_button| gtk.gtk_check_button_set_active(chosen_button, gtk.true_);
}

fn genreName(self: *App, buffer: []u8) ?[:0]const u8 {
    const genre_id = self.album_filters.genre_id orelse return null;
    const library = self.library orelse return null;
    const genre = (self.runtime.libraryGenre(library, genre_id) catch null) orelse return null;
    defer genre.deinit(self.allocator);
    return strings.printZ(buffer, "{s}", .{genre.name}) catch null;
}

fn decadeLabel(self: *App, buffer: []u8) [:0]const u8 {
    const filters = self.album_filters;
    if (filters.year_from == null and filters.year_to == null) return "Decade";
    for (self.album_filters_ui.facets.decades[1..]) |*decade| {
        if (decade.from == null and decade.to == null) break;
        if (decade.from == filters.year_from and decade.to == filters.year_to) return std.mem.sliceTo(&decade.label, 0);
    }
    if (filters.year_from) |from| {
        if (filters.year_to) |to| return strings.printZ(buffer, "{d}\u{2013}{d}", .{ from, to }) catch "Decade";
        return strings.printZ(buffer, "From {d}", .{from}) catch "Decade";
    }
    return strings.printZ(buffer, "Until {d}", .{filters.year_to.?}) catch "Decade";
}

pub fn showFacets(self: *App) void {
    const facets = &self.album_filters_ui.facets;
    const added = facets.added orelse return;
    self.albums_syncing_controls = true;
    defer self.albums_syncing_controls = false;
    const filters = self.album_filters;

    if (facets.lossless) |toggle| gtk.gtk_toggle_button_set_active(toggle, @intFromBool(filters.lossless_only));
    if (facets.lossless_clear) |clear| gtk.gtk_widget_set_visible(clear, @intFromBool(filters.lossless_only));
    markOn(facets.lossless, filters.lossless_only);

    var buffer: [160]u8 = undefined;
    const window = self.album_added.window;
    const added_label: [:0]const u8 = if (window == .any) "Added: any time" else strings.printZ(&buffer, "Added: {s}", .{std.mem.span(window.label())}) catch "Added";
    gtk.gtk_menu_button_set_label(added, added_label.ptr);
    activate(facets.added_checks[@intFromEnum(window)]);
    markOn(added, window != .any);

    if (facets.genre) |genre| {
        gtk.gtk_menu_button_set_label(genre, (genreName(self, &buffer) orelse @as([:0]const u8, "Genre")).ptr);
        markOn(genre, filters.genre_id != null);
    }

    if (facets.decade) |decade| {
        gtk.gtk_menu_button_set_label(decade, decadeLabel(self, &buffer).ptr);
        markOn(decade, filters.year_from != null or filters.year_to != null);
        for (facets.decades, facets.decade_checks) |entry, button| {
            const chosen_button = button orelse continue;
            gtk.gtk_check_button_set_active(chosen_button, @intFromBool(entry.from == filters.year_from and entry.to == filters.year_to));
        }
    }

    activate(facets.shelf_checks[@intFromEnum(self.album_shelf)]);
    activate(facets.artwork_checks[@intFromEnum(filters.artwork)]);
    markOn(facets.more, self.album_shelf != .all or filters.artwork != .any);
}
