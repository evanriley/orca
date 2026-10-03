//! The command palette: the header's library search opens a popover listing
//! `librarySearch` hits by kind, the app's commands, and the entities opened
//! last.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const strings = @import("strings.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const playlists = @import("playlists.zig");
const genres = @import("genres.zig");
const jobs = @import("jobs.zig");
const details = @import("details.zig");
const lyrics = @import("lyrics.zig");
const transport = @import("transport.zig");
const preferences = @import("preferences.zig");
const queue = @import("queue.zig");

const App = app.App;
const SearchKind = liborca.SearchKind;

const palette_width: c_int = 640;
const palette_height: c_int = 480;
const window_margin: c_int = 32;
const entry_height: c_int = 48;
const thumb_pixels: c_int = 28;
const search_delay_ms: c_uint = 120;
const recent_limit = 5;
const index_key = "orca-palette-index";
const watched_key = "orca-palette-watched";

const Entity = struct {
    kind: SearchKind,
    id: i64,
    title: []const u8,
    subtitle: []const u8,
};

const Recent = struct {
    kind: SearchKind,
    id: i64,
    title: []u8,
    subtitle: []u8,

    fn entity(self: Recent) Entity {
        return .{ .kind = self.kind, .id = self.id, .title = self.title, .subtitle = self.subtitle };
    }

    fn free(self: Recent, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.subtitle);
    }
};

const Choice = union(enum) {
    entity: Entity,
    command: usize,
};

pub const State = struct {
    popover: ?*gtk.Widget = null,
    anchor: ?*gtk.Widget = null,
    entry: ?*gtk.Widget = null,
    owns_entry: bool = false,
    list: ?*gtk.Box = null,
    scroller: ?*gtk.ScrolledWindow = null,
    timer: c_uint = 0,
    suppress: bool = false,
    results: ?liborca.SearchResults = null,
    choices: std.ArrayList(Choice) = .empty,
    rows: std.ArrayList(*gtk.Widget) = .empty,
    selected: usize = 0,
    recents: std.ArrayList(Recent) = .empty,

    fn forgetResults(self: *State) void {
        self.choices.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.selected = 0;
        if (self.results) |*results| results.deinit();
        self.results = null;
    }

    fn reset(self: *State) void {
        if (self.timer != 0) _ = gtk.g_source_remove(self.timer);
        self.timer = 0;
        self.forgetResults();
        self.popover = null;
        self.anchor = null;
        self.entry = null;
        self.list = null;
        self.scroller = null;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.reset();
        self.choices.deinit(allocator);
        self.rows.deinit(allocator);
        for (self.recents.items) |recent| recent.free(allocator);
        self.recents.deinit(allocator);
    }
};

const Command = struct {
    name: [:0]const u8,
    shortcut: ?[:0]const u8 = null,
    run: *const fn (*App) void,
};

fn goTo(comptime page: window.Page) *const fn (*App) void {
    return struct {
        fn run(self: *App) void {
            window.goTo(self, page);
        }
    }.run;
}

fn openSettings(comptime tab: app.SettingsTab) *const fn (*App) void {
    return struct {
        fn run(self: *App) void {
            preferences.selectTab(self, tab);
            window.showPage(self, .settings);
        }
    }.run;
}

const commands = [_]Command{
    .{ .name = "Go to Albums", .run = goTo(.albums) },
    .{ .name = "Go to Artists", .run = goTo(.artists) },
    .{ .name = "Go to Songs", .run = goTo(.tracks) },
    .{ .name = "Go to Genres", .run = goTo(.genres) },
    .{ .name = "Go to Folders", .run = goTo(.folders) },
    .{ .name = "Go to Loved", .run = goTo(.loved) },
    .{ .name = "Go to Playlists", .run = goTo(.playlists) },
    .{ .name = "Go to Now Playing", .run = goTo(.now_playing) },
    .{ .name = "Go to Queue", .shortcut = "Ctrl L", .run = goTo(.queue) },
    .{ .name = "Go to Health", .run = goTo(.health) },
    .{ .name = "Go to Matches", .run = goTo(.matches) },
    .{ .name = "Open Settings › General", .run = openSettings(.general) },
    .{ .name = "Open Settings › Library", .run = openSettings(.library) },
    .{ .name = "Open Settings › Playback", .run = openSettings(.playback) },
    .{ .name = "Open Settings › Sound", .run = openSettings(.sound) },
    .{ .name = "Open Settings › Listening", .run = openSettings(.listening) },
    .{ .name = "Open Settings › Appearance", .run = openSettings(.appearance) },
    .{ .name = "Open Settings › Advanced", .run = openSettings(.advanced) },
    .{ .name = "Scan library", .run = jobs.rescan },
    .{ .name = "Analyze library", .run = jobs.startAnalysis },
    .{ .name = "Find duplicates", .run = jobs.startDuplicates },
    .{ .name = "Toggle Inspector", .shortcut = "Ctrl I", .run = details.toggle },
    .{ .name = "Toggle Lyrics", .shortcut = "Ctrl Shift L", .run = lyrics.toggle },
    .{ .name = "Show Signal Path", .shortcut = "Ctrl Shift S", .run = details.toggleSignalPath },
    .{ .name = "Play/Pause", .shortcut = "Space", .run = transport.toggle },
    .{ .name = "Next", .shortcut = "Ctrl →", .run = transport.next },
    .{ .name = "Previous", .shortcut = "Ctrl ←", .run = transport.previous },
    .{ .name = "Shuffle on/off", .run = transport.toggleShuffle },
    .{ .name = "Repeat mode", .run = transport.cycleRepeat },
    .{ .name = "Save queue as playlist", .run = queue.askSaveName },
};

const Group = struct {
    kind: SearchKind,
    heading: [*:0]const u8,
};

const groups = [_]Group{
    .{ .kind = .track, .heading = "TRACKS" },
    .{ .kind = .release, .heading = "ALBUMS" },
    .{ .kind = .artist, .heading = "ARTISTS" },
    .{ .kind = .playlist, .heading = "PLAYLISTS" },
    .{ .kind = .genre, .heading = "GENRES" },
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

pub fn attach(self: *App, entry: *gtk.Widget) void {
    _ = gtk.signalConnect(entry, "changed", gtk.callback(typed), self);
    addKeys(self, entry);
    const focus = gtk.gtk_event_controller_focus_new();
    _ = gtk.signalConnect(focus, "leave", gtk.callback(unfocused), self);
    gtk.gtk_widget_add_controller(entry, focus);
    const press = gtk.gtk_gesture_click_new();
    gtk.gtk_event_controller_set_propagation_phase(press, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(press, "pressed", gtk.callback(clicked), self);
    gtk.gtk_widget_add_controller(entry, press);
}

fn addKeys(self: *App, entry: *gtk.Widget) void {
    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(keyPressed), self);
    gtk.gtk_widget_add_controller(entry, keys);
}

pub fn summon(self: *App) void {
    const switcher = self.top_bar.search orelse return;
    if (self.header_compact) {
        const button = gtk.gtk_stack_get_child_by_name(switcher, "icon") orelse return;
        return open(self, button, true);
    }
    const entry = self.top_bar.entry orelse return;
    if (!focusWithin(self, entry)) _ = gtk.gtk_widget_grab_focus(entry);
    open(self, entry, false);
}

pub fn dismiss(self: *App) void {
    close(self, false);
}

fn focusWithin(self: *App, widget: *gtk.Widget) bool {
    const root = self.window orelse return false;
    const focus = gtk.gtk_window_get_focus(root) orelse return false;
    return focus == widget or gtk.gtk_widget_is_ancestor(focus, widget) != 0;
}

fn open(self: *App, target: *gtk.Widget, owns_entry: bool) void {
    const palette = &self.palette;
    if (palette.popover != null) {
        if (!owns_entry and palette.entry == target) return refresh(self);
        close(self, false);
    }
    const anchor = if (owns_entry) target else gtk.gtk_widget_get_parent(target) orelse target;

    const popover = gtk.gtk_popover_new();
    gtk.gtk_widget_add_css_class(popover, "palette");
    gtk.gtk_popover_set_has_arrow(gtk.cast(gtk.Popover, popover), gtk.false_);
    gtk.gtk_popover_set_position(gtk.cast(gtk.Popover, popover), gtk.POS_BOTTOM);
    gtk.gtk_popover_set_autohide(gtk.cast(gtk.Popover, popover), if (owns_entry) gtk.true_ else gtk.false_);
    if (!owns_entry) gtk.gtk_widget_set_can_focus(popover, gtk.false_);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    var width = palette_width;
    if (self.window) |w| {
        const available = gtk.gtk_widget_get_width(gtk.cast(gtk.Widget, w)) - window_margin;
        if (available > 0) width = @min(width, available);
    }
    gtk.gtk_widget_set_size_request(content, width, -1);

    var entry = target;
    if (owns_entry) {
        entry = gtk.gtk_search_entry_new();
        gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search your library…");
        gtk.gtk_widget_add_css_class(entry, "palette-entry");
        _ = gtk.signalConnect(entry, "changed", gtk.callback(typed), self);
        addKeys(self, entry);
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), entry);
    }

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(list, "palette-list");
    const scroller = gtk.gtk_scrolled_window_new();
    const scrolled = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(scrolled, gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(scrolled, if (owns_entry) palette_height - entry_height else palette_height);
    gtk.gtk_scrolled_window_set_child(scrolled, list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), scroller);
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), content);

    gtk.gtk_widget_set_parent(popover, anchor);
    if (!owns_entry) watchWindow(self);
    keepInWindow(self, gtk.cast(gtk.Popover, popover), anchor, width);
    _ = gtk.signalConnect(popover, "closed", gtk.callback(closed), self);
    _ = gtk.signalConnect(popover, "destroy", gtk.callback(popoverDestroyed), self);
    if (gtk.g_object_get_data(anchor, watched_key) == null) {
        gtk.g_object_set_data(anchor, watched_key, anchor);
        _ = gtk.signalConnect(anchor, "destroy", gtk.callback(anchorDestroyed), self);
    }

    palette.* = .{
        .popover = popover,
        .anchor = anchor,
        .entry = entry,
        .owns_entry = owns_entry,
        .list = gtk.cast(gtk.Box, list),
        .scroller = scrolled,
        .choices = palette.choices,
        .rows = palette.rows,
        .recents = palette.recents,
    };
    refresh(self);
    gtk.gtk_popover_popup(gtk.cast(gtk.Popover, popover));
    if (owns_entry) _ = gtk.gtk_widget_grab_focus(entry);
}

fn watchWindow(self: *App) void {
    const root = gtk.cast(gtk.Widget, self.window orelse return);
    if (gtk.g_object_get_data(root, watched_key) != null) return;
    gtk.g_object_set_data(root, watched_key, root);
    const press = gtk.gtk_gesture_click_new();
    gtk.gtk_gesture_single_set_button(gtk.cast(gtk.GestureSingle, press), 0);
    gtk.gtk_event_controller_set_propagation_phase(press, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(press, "pressed", gtk.callback(windowPressed), self);
    gtk.gtk_widget_add_controller(root, press);
}

fn windowPressed(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const palette = &self.palette;
    if (palette.owns_entry) return;
    const anchor = palette.anchor orelse return;
    const controller = gtk.cast(gtk.EventController, gesture.?);
    const root = gtk.gtk_event_controller_get_widget(controller);
    const event = gtk.gtk_event_controller_get_current_event(controller) orelse return;
    if (gtk.gdk_event_get_surface(event) != gtk.gtk_native_get_surface(root)) return;
    const target = gtk.gtk_widget_pick(root, x, y, 0) orelse return;
    if (target == anchor or gtk.gtk_widget_is_ancestor(target, anchor) != 0) return;
    close(self, false);
}

fn keepInWindow(self: *App, popover: *gtk.Popover, anchor: *gtk.Widget, width: c_int) void {
    const root = gtk.cast(gtk.Widget, self.window orelse return);
    var bounds: gtk.Rect = .{};
    if (gtk.gtk_widget_compute_bounds(anchor, root, &bounds) == 0) return;
    const half: f32 = @floatFromInt(@divTrunc(width + window_margin, 2));
    const window_width: f32 = @floatFromInt(gtk.gtk_widget_get_width(root));
    const lowest = half;
    const highest = @max(lowest, window_width - half);
    const centre = std.math.clamp(bounds.x + bounds.width / 2, lowest, highest);
    const rect: gtk.Rectangle = .{
        .x = @intFromFloat(centre - bounds.x),
        .y = 0,
        .width = 1,
        .height = @intFromFloat(bounds.height),
    };
    gtk.gtk_popover_set_pointing_to(popover, &rect);
}

fn close(self: *App, clear: bool) void {
    const palette = &self.palette;
    const popover = palette.popover orelse return;
    if (clear and !palette.owns_entry) {
        if (palette.entry) |entry| {
            palette.suppress = true;
            gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), "");
            palette.suppress = false;
        }
    }
    gtk.gtk_popover_popdown(gtk.cast(gtk.Popover, popover));
    release(self);
}

fn release(self: *App) void {
    const popover = self.palette.popover orelse return;
    self.palette.reset();
    _ = gtk.g_idle_add(unparentLater, gtk.g_object_ref(popover));
}

fn unparentLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const popover = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(popover);
    if (gtk.gtk_widget_get_parent(popover) != null) gtk.gtk_widget_unparent(popover);
    return gtk.SOURCE_REMOVE;
}

fn closed(popover: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (@as(?*anyopaque, self.palette.popover) == popover) release(self);
}

fn popoverDestroyed(popover: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (@as(?*anyopaque, self.palette.popover) == popover) self.palette.reset();
}

fn anchorDestroyed(anchor: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const popover = self.palette.popover orelse return;
    if (@as(?*anyopaque, gtk.gtk_widget_get_parent(popover)) != anchor) return;
    release(self);
    gtk.gtk_widget_unparent(popover);
}

fn clicked(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (window.filterTarget(self) != null) return;
    const controller = gtk.cast(gtk.EventController, gesture.?);
    open(self, gtk.gtk_event_controller_get_widget(controller), false);
}

fn unfocused(controller_pointer: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const controller = gtk.cast(gtk.EventController, controller_pointer.?);
    const widget = gtk.gtk_event_controller_get_widget(controller);
    if (self.palette.owns_entry or self.palette.entry != widget) return;
    if (focusWithin(self, widget)) return;
    close(self, false);
}

fn typed(editable: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const palette = &self.palette;
    if (palette.suppress) return;
    const entry = gtk.cast(gtk.Widget, editable.?);
    if (palette.entry != entry) {
        if (window.filterTarget(self) != null) return;
        return open(self, entry, false);
    }
    if (palette.timer != 0) _ = gtk.g_source_remove(palette.timer);
    palette.timer = 0;
    if (gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry))[0] == 0) return refresh(self);
    palette.timer = gtk.g_timeout_add(search_delay_ms, searchLater, self);
}

fn searchLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.palette.timer = 0;
    refresh(self);
    return gtk.SOURCE_REMOVE;
}

fn keyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    data: ?*anyopaque,
) callconv(.c) gtk.gboolean {
    const self = state(data);
    const palette = &self.palette;
    if (palette.popover == null) return gtk.false_;
    switch (keyval) {
        gtk.KEY_Up => select(self, if (palette.selected == 0) 0 else palette.selected - 1),
        gtk.KEY_Down => select(self, palette.selected + 1),
        gtk.KEY_Return, gtk.KEY_KP_Enter, gtk.KEY_ISO_Enter => {
            if (palette.timer != 0) {
                _ = gtk.g_source_remove(palette.timer);
                palette.timer = 0;
                refresh(self);
            }
            activate(self, palette.selected, modifiers & gtk.MODIFIER_SHIFT != 0);
        },
        gtk.KEY_Escape => close(self, true),
        else => return gtk.false_,
    }
    return gtk.true_;
}

fn text(self: *App) []const u8 {
    const entry = self.palette.entry orelse return "";
    return std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry))), " \t");
}

fn refresh(self: *App) void {
    const palette = &self.palette;
    const list = palette.list orelse return;
    palette.forgetResults();
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list))) |child| gtk.gtk_box_remove(list, child);

    const typed_text = text(self);
    if (typed_text.len == 0) {
        showRecents(self);
    } else if (typed_text[0] == '>') {
        showCommands(self, typed_text[1..], true);
    } else {
        showHits(self, typed_text);
        showCommands(self, typed_text, false);
    }
    if (palette.rows.items.len == 0) {
        const empty = gtk.gtk_label_new(if (typed_text.len == 0)
            "Type to search your library, or > for commands"
        else
            "No results");
        gtk.gtk_widget_add_css_class(empty, "palette-empty");
        gtk.gtk_box_append(list, empty);
    }
    if (palette.scroller) |scroller| gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), 0);
    select(self, 0);
}

fn showRecents(self: *App) void {
    const palette = &self.palette;
    if (palette.recents.items.len == 0) return;
    heading(self, "RECENT");
    for (palette.recents.items) |recent| addEntity(self, recent.entity());
}

fn showHits(self: *App, query: []const u8) void {
    const palette = &self.palette;
    const library = self.library orelse return;
    palette.results = self.runtime.librarySearch(library, query, .{}) catch return;
    const hits = palette.results.?.hits;
    for (groups) |group| {
        var headed = false;
        for (hits) |hit| {
            if (hit.kind != group.kind) continue;
            if (!headed) heading(self, group.heading);
            headed = true;
            addEntity(self, .{ .kind = hit.kind, .id = hit.id, .title = hit.title, .subtitle = hit.subtitle });
        }
    }
}

fn showCommands(self: *App, query: []const u8, all: bool) void {
    var headed = false;
    for (commands, 0..) |command, index| {
        if (!matches(command.name, query, all)) continue;
        if (!headed) heading(self, "COMMANDS");
        headed = true;
        addCommand(self, index);
    }
}

fn matches(name: []const u8, query: []const u8, empty_matches: bool) bool {
    var wanted = std.mem.tokenizeAny(u8, query, " \t");
    var any = false;
    while (wanted.next()) |word| {
        any = true;
        var found = false;
        var words = std.mem.tokenizeAny(u8, name, " /›");
        while (words.next()) |candidate| {
            if (candidate.len >= word.len and std.ascii.eqlIgnoreCase(candidate[0..word.len], word)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return any or empty_matches;
}

fn heading(self: *App, label_text: [*:0]const u8) void {
    const list = self.palette.list orelse return;
    const label = gtk.gtk_label_new(label_text);
    gtk.gtk_widget_add_css_class(label, "palette-heading");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_box_append(list, label);
}

fn addRow(self: *App, choice: Choice, thumb: ?*gtk.Widget, title: []const u8, subtitle: []const u8, shortcut: ?[:0]const u8) ?*gtk.Widget {
    const palette = &self.palette;
    const list = palette.list orelse return null;
    palette.choices.append(self.allocator, choice) catch return null;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    palette.rows.append(self.allocator, row) catch {
        _ = palette.choices.pop();
        _ = gtk.g_object_ref_sink(row);
        gtk.g_object_unref(row);
        return null;
    };
    gtk.gtk_widget_add_css_class(row, "palette-row");
    if (thumb) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, row), widget);

    var buffer: [512]u8 = undefined;
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    const name = gtk.gtk_label_new(strings.terminated(&buffer, title).ptr);
    gtk.gtk_widget_add_css_class(name, "palette-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), name);
    if (subtitle.len > 0) {
        const detail = gtk.gtk_label_new(strings.terminated(&buffer, subtitle).ptr);
        gtk.gtk_widget_add_css_class(detail, "palette-subtitle");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, detail), 0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, detail), gtk.ELLIPSIZE_END);
        gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), labels);
    if (shortcut) |keys| {
        const hint = gtk.gtk_label_new(keys.ptr);
        gtk.gtk_widget_add_css_class(hint, "palette-shortcut");
        gtk.gtk_widget_set_valign(hint, gtk.ALIGN_CENTER);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), hint);
    }

    gtk.g_object_set_data(row, index_key, @ptrFromInt(palette.rows.items.len));
    const click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(click, "released", gtk.callback(rowClicked), self);
    gtk.gtk_widget_add_controller(row, click);
    gtk.gtk_box_append(list, row);
    return row;
}

fn addEntity(self: *App, entity: Entity) void {
    const row = addRow(self, .{ .entity = entity }, thumbFor(self, entity), entity.title, entity.subtitle, null) orelse return;
    albums.showPlaying(row, entityPlaying(self.playing(), entity));
}

fn entityPlaying(playing: app.Playing, entity: Entity) bool {
    return switch (entity.kind) {
        .track => playing.matches(.track, entity.id),
        .release => playing.matches(.release, entity.id),
        .artist => playing.matches(.artist, entity.id),
        .playlist, .genre => false,
    };
}

pub fn markPlaying(self: *App, _: ?i64) void {
    const palette = &self.palette;
    if (palette.popover == null) return;
    const playing = self.playing();
    for (palette.choices.items, palette.rows.items) |choice, row| switch (choice) {
        .entity => |entity| albums.showPlaying(row, entityPlaying(playing, entity)),
        .command => {},
    };
}

fn addCommand(self: *App, index: usize) void {
    const command = commands[index];
    _ = addRow(self, .{ .command = index }, null, command.name, "", command.shortcut);
}

fn thumbFor(self: *App, entity: Entity) *gtk.Widget {
    switch (entity.kind) {
        .playlist, .genre => {
            const icon = gtk.gtk_image_new_from_icon_name(if (entity.kind == .playlist)
                "media-playlist-consecutive-symbolic"
            else
                "applications-multimedia-symbolic");
            gtk.gtk_widget_add_css_class(icon, "palette-icon");
            gtk.gtk_widget_set_size_request(icon, thumb_pixels, thumb_pixels);
            gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
            return icon;
        },
        .track => {
            const cover = art.newCover(self, art.iconPlaceholder(thumb_pixels), thumb_pixels);
            gtk.gtk_widget_add_css_class(cover, "palette-thumb");
            art.show(self, cover, art.Key.track(entity.id, .thumb));
            return cover;
        },
        .release => {
            const cover = art.newCover(self, art.initialsPlaceholder(), thumb_pixels);
            gtk.gtk_widget_add_css_class(cover, "palette-thumb");
            art.setInitials(cover, entity.title);
            art.show(self, cover, art.Key.release(entity.id, .thumb));
            return cover;
        },
        .artist => {
            const cover = art.newCover(self, art.initialsPlaceholder(), thumb_pixels);
            gtk.gtk_widget_add_css_class(cover, "palette-thumb");
            gtk.gtk_widget_add_css_class(cover, "palette-portrait");
            art.setInitials(cover, entity.title);
            art.showArtist(self, cover, entity.id, .unknown, artists.firstRelease(self, entity.id), .thumb);
            return cover;
        },
    }
}

fn select(self: *App, wanted: usize) void {
    const palette = &self.palette;
    const rows = palette.rows.items;
    if (rows.len == 0) return;
    const index = @min(wanted, rows.len - 1);
    if (palette.selected < rows.len) gtk.gtk_widget_remove_css_class(rows[palette.selected], "selected");
    palette.selected = index;
    gtk.gtk_widget_add_css_class(rows[index], "selected");
    reveal(self, rows[index]);
}

fn reveal(self: *App, row: *gtk.Widget) void {
    const palette = &self.palette;
    const scroller = palette.scroller orelse return;
    const list = palette.list orelse return;
    var bounds: gtk.Rect = .{};
    if (gtk.gtk_widget_compute_bounds(row, gtk.cast(gtk.Widget, list), &bounds) == 0) return;
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(scroller);
    const top = gtk.gtk_adjustment_get_value(adjustment);
    const page = gtk.gtk_adjustment_get_page_size(adjustment);
    const row_top: f64 = bounds.y;
    const row_bottom: f64 = bounds.y + bounds.height;
    if (row_top < top) {
        gtk.gtk_adjustment_set_value(adjustment, row_top);
    } else if (row_bottom > top + page) {
        gtk.gtk_adjustment_set_value(adjustment, row_bottom - page);
    }
}

fn rowClicked(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture.?));
    const position = @intFromPtr(gtk.g_object_get_data(row, index_key));
    if (position == 0) return;
    activate(self, position - 1, false);
}

fn activate(self: *App, index: usize, play: bool) void {
    const palette = &self.palette;
    if (index >= palette.choices.items.len) return;
    switch (palette.choices.items[index]) {
        .command => |command| {
            close(self, true);
            commands[command].run(self);
        },
        .entity => |entity| {
            remember(self, entity);
            const kind = entity.kind;
            const id = entity.id;
            close(self, true);
            openEntity(self, kind, id, play);
        },
    }
}

fn openEntity(self: *App, kind: SearchKind, id: i64, play: bool) void {
    switch (kind) {
        .track => transport.playIds(self, &.{id}, 0),
        .release => if (play) albums.playRelease(self, id) else window.showAlbum(self, id),
        .artist => window.showArtist(self, id),
        .playlist => if (play) playlists.playWhole(self, id, false) else playlists.open(self, id),
        .genre => if (play) genres.playGenreId(self, id) else genres.open(self, id),
    }
}

fn remember(self: *App, entity: Entity) void {
    const allocator = self.allocator;
    const recents = &self.palette.recents;
    const title = allocator.dupe(u8, entity.title) catch return;
    const subtitle = allocator.dupe(u8, entity.subtitle) catch {
        allocator.free(title);
        return;
    };
    const fresh: Recent = .{ .kind = entity.kind, .id = entity.id, .title = title, .subtitle = subtitle };
    for (recents.items, 0..) |recent, position| {
        if (recent.kind != entity.kind or recent.id != entity.id) continue;
        recent.free(allocator);
        _ = recents.orderedRemove(position);
        break;
    }
    if (recents.items.len == recent_limit) recents.pop().?.free(allocator);
    recents.insert(allocator, 0, fresh) catch fresh.free(allocator);
}
