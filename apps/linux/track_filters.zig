//! The Tracks page's Filters popover and, for a large library, the bar of
//! filter tokens above the list. Every filter is a field of the engine's
//! `TrackQuery`, with or without search text, and each has a smart playlist
//! rule that selects the same Tracks.

const std = @import("std");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const albums = @import("albums.zig");
const strings = @import("strings.zig");
const playlists = @import("playlists.zig");

const App = app.App;

pub const Format = enum { any, lossless, lossy };

/// The codecs offered, named as `files.codec` stores them.
pub const Codec = enum {
    flac,
    alac,
    mp3,
    aac,
    opus,
    vorbis,
    pcm,

    pub fn label(self: Codec) [*:0]const u8 {
        return switch (self) {
            .flac => "FLAC",
            .alac => "ALAC",
            .mp3 => "MP3",
            .aac => "AAC",
            .opus => "Opus",
            .vorbis => "Vorbis",
            .pcm => "PCM",
        };
    }
};

const codec_labels = [_]?[*:0]const u8{ "Any", "FLAC", "ALAC", "MP3", "AAC", "Opus", "Vorbis", "PCM", null };
const sample_rates = [_]?u32{ null, 44_100, 48_000, 88_200, 96_000, 176_400 };
const sample_rate_labels = [_]?[*:0]const u8{ "Any", "> 44.1 kHz", "> 48 kHz", "> 88.2 kHz", "> 96 kHz", "> 176.4 kHz", null };
const added_windows = [_]albums.Added.Window{ .any, .week, .month, .year };
const added_labels = [_]?[*:0]const u8{ "Any time", "Last 7 days", "Last 30 days", "Last 12 months", null };

pub const Filters = struct {
    genre_id: ?i64 = null,
    year_from: ?i32 = null,
    year_to: ?i32 = null,
    format: Format = .any,
    codec: ?Codec = null,
    /// Only Tracks whose sample rate is above this.
    rate_above: ?u32 = null,
    added: albums.Added = .{},
    loved_only: bool = false,
    explicit_only: bool = false,

    pub fn active(self: Filters) bool {
        return !std.meta.eql(self, Filters{});
    }
};

const Token = enum { genre, year, format, codec, sample_rate, added, loved, explicit };

/// The popover's widgets and the genre ids behind its dropdown's entries.
pub const Ui = struct {
    button: ?*gtk.Widget = null,
    genre: ?*gtk.DropDown = null,
    genre_names: ?*gtk.StringList = null,
    genre_ids: std.ArrayList(i64) = .empty,
    year_from: ?*gtk.Editable = null,
    year_to: ?*gtk.Editable = null,
    formats: [3]?*gtk.ToggleButton = @splat(null),
    codec: ?*gtk.DropDown = null,
    sample_rate: ?*gtk.DropDown = null,
    added: ?*gtk.DropDown = null,
    loved: ?*gtk.CheckButton = null,
    explicit: ?*gtk.CheckButton = null,
    suppress: bool = false,
    popover: ?*gtk.Widget = null,
    /// The token bar: the tokens and "+ Filter" on the left, the totals and
    /// "Save as Smart Playlist" on the right.
    bar: ?*gtk.Widget = null,
    tokens: ?*gtk.Box = null,
    plus: ?*gtk.Widget = null,
    totals: ?*gtk.Label = null,
    save: ?*gtk.Widget = null,
    tokens_cell: [@typeInfo(Token).@"enum".field_names.len]TokenCell = undefined,
    large: bool = false,

    pub fn deinit(self: *Ui, allocator: std.mem.Allocator) void {
        self.genre_ids.deinit(allocator);
    }
};

const TokenCell = struct { app: *App, token: Token };

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
    const ui = &self.track_filters_ui;
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
        if (gtk.gtk_toggle_button_get_active(button) != 0) filters.format = @fromBackingInt(@intCast(index));
    }
    if (ui.codec) |dropdown| {
        const index = gtk.gtk_drop_down_get_selected(dropdown);
        if (index != 0 and index != gtk.INVALID_LIST_POSITION and index - 1 < @typeInfo(Codec).@"enum".field_names.len)
            filters.codec = @fromBackingInt(@intCast(index - 1));
    }
    if (ui.sample_rate) |dropdown| {
        const index = gtk.gtk_drop_down_get_selected(dropdown);
        if (index < sample_rates.len) filters.rate_above = sample_rates[index];
    }
    if (ui.added) |dropdown| {
        const index = gtk.gtk_drop_down_get_selected(dropdown);
        if (index < added_windows.len) filters.added = addedFor(self, added_windows[index]);
    }
    if (ui.loved) |check| filters.loved_only = gtk.gtk_check_button_get_active(check) != 0;
    if (ui.explicit) |check| filters.explicit_only = gtk.gtk_check_button_get_active(check) != 0;
    if (std.meta.eql(filters, self.track_filters)) return;
    self.track_filters = filters;
    showActive(self);
    self.reload();
}

/// The cutoff is kept while the window is unchanged, so changing another
/// filter does not move it.
fn addedFor(self: *App, window: albums.Added.Window) albums.Added {
    if (window == self.track_filters.added.window) return self.track_filters.added;
    const days = window.days() orelse return .{};
    return .{
        .window = window,
        .after = std.Io.Clock.real.now(self.io).toSeconds() - days * std.time.s_per_day - 1,
    };
}

fn showActive(self: *App) void {
    if (self.track_filters_ui.button) |button| {
        if (self.track_filters.active())
            gtk.gtk_widget_add_css_class(button, "filters-active")
        else
            gtk.gtk_widget_remove_css_class(button, "filters-active");
    }
    showTokens(self);
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
    if (ui.codec) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, 0);
    if (ui.sample_rate) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, 0);
    if (ui.added) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, 0);
    if (ui.loved) |check| gtk.gtk_check_button_set_active(check, gtk.false_);
    if (ui.explicit) |check| gtk.gtk_check_button_set_active(check, gtk.false_);
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const ui = &self.track_filters_ui;
    ui.suppress = true;
    resetControls(ui);
    ui.suppress = false;
    changed(self);
}

/// Refills the genre list with every genre each time the popover opens,
/// keeping the chosen genre selected.
fn popoverShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const ui = &self.track_filters_ui;
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
            if (self.track_filters.genre_id == item.id) selected = @intCast(ui.genre_ids.items.len);
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

/// The Filters button for the Tracks page header.
pub fn build(self: *App) *gtk.Widget {
    const ui = &self.track_filters_ui;
    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(list, "track-filters");

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

    const codec = gtk.gtk_drop_down_new_from_strings(&codec_labels);
    ui.codec = gtk.cast(gtk.DropDown, codec);
    _ = gtk.signalConnect(codec, "notify::selected", gtk.callback(propertyChanged), self);
    row(list, "Codec", codec);

    const rate = gtk.gtk_drop_down_new_from_strings(&sample_rate_labels);
    ui.sample_rate = gtk.cast(gtk.DropDown, rate);
    _ = gtk.signalConnect(rate, "notify::selected", gtk.callback(propertyChanged), self);
    row(list, "Sample rate", rate);

    const added = gtk.gtk_drop_down_new_from_strings(&added_labels);
    ui.added = gtk.cast(gtk.DropDown, added);
    _ = gtk.signalConnect(added, "notify::selected", gtk.callback(propertyChanged), self);
    row(list, "Added", added);

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
    ui.popover = popover;

    const button = gtk.gtk_menu_button_new();
    ui.button = button;
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_image_new_from_icon_name("orca-filter-symbolic"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new("Filters"));
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), content);
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, button), gtk.false_);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_add_css_class(button, "filters-button");
    gtk.gtk_widget_add_css_class(button, "btn-menu");
    gtk.gtk_widget_set_tooltip_text(button, "Filter tracks");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

/// Brings the popover's controls in line with `self.track_filters`.
fn syncControls(self: *App) void {
    const ui = &self.track_filters_ui;
    const filters = self.track_filters;
    ui.suppress = true;
    defer ui.suppress = false;
    if (ui.genre) |genre| {
        var selected: c_uint = 0;
        if (filters.genre_id) |id| {
            if (std.mem.indexOfScalar(i64, ui.genre_ids.items, id)) |index| selected = @intCast(index + 1);
        }
        gtk.gtk_drop_down_set_selected(genre, selected);
    }
    var year_buffer: [16]u8 = undefined;
    if (ui.year_from) |entry| gtk.gtk_editable_set_text(entry, if (filters.year_from) |year| strings.format(&year_buffer, "{d}", .{year}).ptr else "");
    if (ui.year_to) |entry| gtk.gtk_editable_set_text(entry, if (filters.year_to) |year| strings.format(&year_buffer, "{d}", .{year}).ptr else "");
    if (ui.formats[@backingInt(filters.format)]) |toggle| gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
    if (ui.codec) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, if (filters.codec) |codec| @backingInt(codec) + 1 else 0);
    if (ui.sample_rate) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, @intCast(std.mem.indexOfScalar(?u32, &sample_rates, filters.rate_above) orelse 0));
    if (ui.added) |dropdown| gtk.gtk_drop_down_set_selected(dropdown, @backingInt(filters.added.window));
    if (ui.loved) |check| gtk.gtk_check_button_set_active(check, if (filters.loved_only) gtk.true_ else gtk.false_);
    if (ui.explicit) |check| gtk.gtk_check_button_set_active(check, if (filters.explicit_only) gtk.true_ else gtk.false_);
}

fn tokenActive(filters: Filters, token: Token) bool {
    return switch (token) {
        .genre => filters.genre_id != null,
        .year => filters.year_from != null or filters.year_to != null,
        .format => filters.format != .any,
        .codec => filters.codec != null,
        .sample_rate => filters.rate_above != null,
        .added => filters.added.window != .any,
        .loved => filters.loved_only,
        .explicit => filters.explicit_only,
    };
}

fn tokenName(token: Token) ?[*:0]const u8 {
    return switch (token) {
        .genre => "Genre",
        .year => "Year",
        .format => "Format",
        .codec => "Codec",
        .sample_rate => "Sample rate",
        .added => "Added",
        .loved, .explicit => null,
    };
}

fn writeRate(writer: *std.Io.Writer, hertz: u32) std.Io.Writer.Error!void {
    if (hertz % 1000 == 0)
        try writer.print("{d} kHz", .{hertz / 1000})
    else
        try writer.print("{d}.{d} kHz", .{ hertz / 1000, hertz % 1000 / 100 });
}

/// What the token says after its name: `FLAC`, `> 48 kHz`, `last 12 months`.
fn writeTokenValue(self: *App, writer: *std.Io.Writer, token: Token) std.Io.Writer.Error!void {
    const filters = self.track_filters;
    switch (token) {
        .genre => {
            const library = self.library orelse return;
            const genre = (self.runtime.libraryGenre(library, filters.genre_id orelse return) catch null) orelse return;
            defer genre.deinit(self.allocator);
            try writer.writeAll(genre.name);
        },
        .year => {
            if (filters.year_from != null and filters.year_to != null)
                try writer.print("{d}–{d}", .{ filters.year_from.?, filters.year_to.? })
            else if (filters.year_from) |year|
                try writer.print("from {d}", .{year})
            else if (filters.year_to) |year|
                try writer.print("to {d}", .{year});
        },
        .format => try writer.writeAll(if (filters.format == .lossless) "Lossless" else "Lossy"),
        .codec => try writer.writeAll(std.mem.span((filters.codec orelse return).label())),
        .sample_rate => {
            try writer.writeAll("> ");
            try writeRate(writer, filters.rate_above orelse return);
        },
        .added => {
            const text = std.mem.span(filters.added.window.label());
            try writer.writeByte(std.ascii.toLower(text[0]));
            try writer.writeAll(text[1..]);
        },
        .loved => try writer.writeAll("Loved only"),
        .explicit => try writer.writeAll("Explicit only"),
    }
}

fn tokenText(self: *App, buffer: []u8, token: Token) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeTokenValue(self, &writer, token) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn tokenRemoved(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const cell: *TokenCell = @ptrCast(@alignCast(data.?));
    const self = cell.app;
    var filters = self.track_filters;
    switch (cell.token) {
        .genre => filters.genre_id = null,
        .year => {
            filters.year_from = null;
            filters.year_to = null;
        },
        .format => filters.format = .any,
        .codec => filters.codec = null,
        .sample_rate => filters.rate_above = null,
        .added => filters.added = .{},
        .loved => filters.loved_only = false,
        .explicit => filters.explicit_only = false,
    }
    self.track_filters = filters;
    syncControls(self);
    showActive(self);
    self.reload();
}

fn tokenWidget(self: *App, token: Token) *gtk.Widget {
    const ui = &self.track_filters_ui;
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(box, "tok");
    if (tokenName(token)) |name| {
        const label = gtk.gtk_label_new(name);
        gtk.gtk_widget_add_css_class(label, "tok-name");
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), label);
    }
    var buffer: [160]u8 = undefined;
    const value = gtk.gtk_label_new(tokenText(self, &buffer, token).ptr);
    gtk.gtk_widget_add_css_class(value, "tok-value");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), value);
    const remove = gtk.gtk_button_new_from_icon_name("orca-close-symbolic");
    gtk.gtk_widget_add_css_class(remove, "flat");
    gtk.gtk_widget_add_css_class(remove, "tok-remove");
    gtk.gtk_widget_set_valign(remove, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(remove, "Remove filter");
    const cell = &ui.tokens_cell[@backingInt(token)];
    cell.* = .{ .app = self, .token = token };
    _ = gtk.signalConnect(remove, "clicked", gtk.callback(tokenRemoved), cell);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), remove);
    return box;
}

pub fn forgetLibrary(self: *App) void {
    self.track_filters.genre_id = null;
    syncControls(self);
    showActive(self);
}

fn showTokens(self: *App) void {
    const ui = &self.track_filters_ui;
    const tokens = ui.tokens orelse return;
    const plus = ui.plus orelse return;
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, tokens))) |child| {
        if (child == plus) break;
        gtk.gtk_box_remove(tokens, child);
    }
    var previous: ?*gtk.Widget = null;
    for (std.enums.values(Token)) |token| {
        if (!tokenActive(self.track_filters, token)) continue;
        const widget = tokenWidget(self, token);
        gtk.gtk_box_insert_child_after(tokens, widget, previous);
        previous = widget;
    }
}

/// `18,772 tracks · 61 h 14 min · ` before "Save as Smart Playlist", or only
/// the count when nothing is filtered. Save is offered only when the
/// listing is exactly what the tokens say: no search text and no Artist or
/// Release scope, which no rule can express.
pub fn showTotals(self: *App) void {
    const ui = &self.track_filters_ui;
    const label = ui.totals orelse return;
    const filtered = self.track_filters.active();
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.print("{f} {s}", .{ strings.grouped(self.track_count), if (self.track_count == 1) "track" else "tracks" }) catch {};
    const savable = filtered and self.query.value.len == 0 and self.browse.artist_id == null and self.browse.release_id == null;
    if (filtered) {
        const minutes = (self.track_duration_ms + 30_000) / 60_000;
        if (minutes >= 60)
            writer.print(" · {f} h {d} min", .{ strings.grouped(minutes / 60), minutes % 60 }) catch {}
        else
            writer.print(" · {d} min", .{minutes}) catch {};
        if (savable) writer.writeAll(" · ") catch {};
    }
    buffer[writer.end] = 0;
    gtk.gtk_label_set_text(label, buffer[0..writer.end :0].ptr);
    if (ui.save) |save| gtk.gtk_widget_set_visible(save, if (savable) gtk.true_ else gtk.false_);
}

fn writeRules(self: *App, writer: *std.Io.Writer) !void {
    const filters = self.track_filters;
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("v");
    try json.write(1);
    try json.objectField("match");
    try json.write("all");
    try json.objectField("rules");
    try json.beginArray();
    if (filters.genre_id) |id| {
        const library = self.library orelse return error.NoLibrary;
        const genre = (try self.runtime.libraryGenre(library, id)) orelse return error.NoGenre;
        defer genre.deinit(self.allocator);
        try writeRule(&json, "genre", "is", genre.name);
    }
    if (filters.year_from) |year| try writeRule(&json, "year", "gte", year);
    if (filters.year_to) |year| try writeRule(&json, "year", "lte", year);
    switch (filters.format) {
        .any => {},
        .lossless => try writeRule(&json, "lossless", "is", true),
        .lossy => {
            try writeRule(&json, "lossless", "is", false);
            try writeRule(&json, "codec", "is_set", null);
        },
    }
    if (filters.codec) |codec| try writeRule(&json, "codec", "is", @tagName(codec));
    if (filters.rate_above) |rate| try writeRule(&json, "sample_rate", "gt", rate);
    if (filters.added.window.days()) |days| try writeRule(&json, "added_at", "in_last_days", days);
    if (filters.loved_only) try writeRule(&json, "loved", "is", true);
    if (filters.explicit_only) try writeRule(&json, "explicit", "is", true);
    try json.endArray();
    try json.endObject();
}

fn writeRule(json: *std.json.Stringify, field: []const u8, operator: []const u8, value: anytype) !void {
    try json.beginObject();
    try json.objectField("field");
    try json.write(field);
    try json.objectField("op");
    try json.write(operator);
    try json.objectField("value");
    try json.write(value);
    try json.endObject();
}

/// The tokens, joined: `Codec FLAC · Sample rate > 48 kHz`.
fn playlistName(self: *App, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var first = true;
    for (std.enums.values(Token)) |token| {
        if (!tokenActive(self.track_filters, token)) continue;
        if (!first) try writer.writeAll(" · ");
        first = false;
        if (tokenName(token)) |name| try writer.print("{s} ", .{std.mem.span(name)});
        try writeTokenValue(self, writer, token);
    }
}

fn saveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    var rules = std.Io.Writer.Allocating.init(self.allocator);
    defer rules.deinit();
    writeRules(self, &rules.writer) catch return self.toast("Could not create the playlist");
    var name_buffer: [256]u8 = undefined;
    var name = std.Io.Writer.fixed(&name_buffer);
    playlistName(self, &name) catch {};
    const id = self.runtime.libraryCreateSmartPlaylist(library, name.buffered(), rules.written()) catch
        return self.toast("Could not create the playlist");
    playlists.refresh(self);
    playlists.open(self, id);
}

/// The bar of filter tokens for a large library, hidden until `setLarge`.
pub fn buildBar(self: *App) *gtk.Widget {
    const ui = &self.track_filters_ui;
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(bar, "token-bar");
    const tokens = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_hexpand(tokens, gtk.true_);
    ui.tokens = gtk.cast(gtk.Box, tokens);

    const plus = gtk.gtk_menu_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const icon = gtk.gtk_image_new_from_icon_name("orca-plus-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 12);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new("Filter"));
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, plus), content);
    gtk.gtk_menu_button_set_always_show_arrow(gtk.cast(gtk.MenuButton, plus), gtk.false_);
    gtk.gtk_widget_add_css_class(plus, "tok-add");
    gtk.gtk_widget_set_tooltip_text(plus, "Add a filter");
    gtk.gtk_widget_set_valign(plus, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tokens), plus);
    ui.plus = plus;
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), tokens);

    const summary = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_valign(summary, gtk.ALIGN_CENTER);
    const totals = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(totals, "token-totals");
    gtk.gtk_box_append(gtk.cast(gtk.Box, summary), totals);
    ui.totals = gtk.cast(gtk.Label, totals);
    const save = gtk.gtk_button_new_with_label("Save as Smart Playlist");
    gtk.gtk_widget_add_css_class(save, "flat");
    gtk.gtk_widget_add_css_class(save, "token-save");
    _ = gtk.signalConnect(save, "clicked", gtk.callback(saveClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, summary), save);
    ui.save = save;
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), summary);

    gtk.gtk_widget_set_visible(bar, gtk.false_);
    ui.bar = bar;
    showTokens(self);
    return bar;
}

/// Shows the token bar for a large library, with the Filters popover on
/// "+ Filter", or hides it and puts the popover back on the Filters button.
pub fn setLarge(self: *App, large: bool) void {
    const ui = &self.track_filters_ui;
    if (ui.large == large) return;
    ui.large = large;
    if (ui.bar) |bar| gtk.gtk_widget_set_visible(bar, if (large) gtk.true_ else gtk.false_);
    const popover = ui.popover orelse return;
    const from = (if (large) ui.button else ui.plus) orelse return;
    const to = (if (large) ui.plus else ui.button) orelse return;
    _ = gtk.g_object_ref(popover);
    defer gtk.g_object_unref(popover);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, from), null);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, to), popover);
}
