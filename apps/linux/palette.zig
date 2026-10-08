//! Library search and the command palette. Search covers the content area
//! with `librarySearch` hits grouped by kind; the palette is a modal list of
//! the app's commands, its Settings sections and the entities opened last.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const frost = @import("frost.zig");
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
const menu = @import("menu.zig");

const App = app.App;
const SearchKind = liborca.SearchKind;
const SearchHit = liborca.SearchHit;

const palette_width: c_int = 640;
const palette_top: c_int = 110;
const palette_list_height: c_int = 460;
const window_gutter: c_int = 16;
const icon_box_pixels: c_int = 30;
const row_thumb_pixels: c_int = 40;
const portrait_pixels: c_int = 96;
const tile_pixels: c_int = 160;
const top_section_width: c_int = 340;
const search_entry_chars: c_int = 52;
const recent_limit = 5;
const kind_limit: u8 = 50;
const mosaic_entries: u32 = 64;
const search_delay_ms: c_uint = 120;
const query_capacity = 256;
const index_key = "orca-palette-index";

const prefixes = [_][]const u8{ "›", ">" };

pub fn isCommandText(text: []const u8) bool {
    return prefixLength(text) != 0;
}

fn prefixLength(text: []const u8) usize {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return prefix.len;
    }
    return 0;
}

const Recent = struct {
    kind: SearchKind,
    id: i64,
    title: []u8,
    detail: []u8,

    fn free(self: Recent, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.detail);
    }
};

const Choice = union(enum) {
    hit: SearchHit,
    command: usize,
    recent: usize,
};

const Picker = struct {
    choices: std.ArrayList(Choice) = .empty,
    rows: std.ArrayList(*gtk.Widget) = .empty,
    selected: usize = 0,

    fn clear(self: *Picker) void {
        self.choices.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.selected = 0;
    }

    fn deinit(self: *Picker, allocator: std.mem.Allocator) void {
        self.choices.deinit(allocator);
        self.rows.deinit(allocator);
    }
};

const Palette = struct {
    layer: ?*gtk.Widget = null,
    covered: ?*gtk.Widget = null,
    dialog: ?*gtk.Widget = null,
    entry: ?*gtk.Widget = null,
    list: ?*gtk.Box = null,
    scroller: ?*gtk.ScrolledWindow = null,
    frost: frost.Frost = .{},
    picker: Picker = .{},
    open: bool = false,
    refocus: ?*gtk.Widget = null,
};

const chip_kinds = [_]?SearchKind{ null, .artist, .release, .track, .playlist, .genre };
const chip_labels = [_][*:0]const u8{ "All", "Artists", "Albums", "Tracks", "Playlists", "Genres" };

const Search = struct {
    layer: ?*gtk.Widget = null,
    covered: ?*gtk.Widget = null,
    entry: ?*gtk.Widget = null,
    content: ?*gtk.Box = null,
    chips: ?*gtk.Widget = null,
    chip_buttons: [chip_kinds.len]?*gtk.Widget = @splat(null),
    scroller: ?*gtk.ScrolledWindow = null,
    frosted: ?*gtk.Widget = null,
    frost: frost.Frost = .{},
    kind: ?SearchKind = null,
    results: ?liborca.SearchResults = null,
    picker: Picker = .{},
    open: bool = false,
    refocus: ?*gtk.Widget = null,
    query: [query_capacity]u8 = undefined,
    query_len: usize = 0,
    searched: bool = false,
    timer: c_uint = 0,

    fn cancelTimer(self: *Search) void {
        if (self.timer != 0) _ = gtk.g_source_remove(self.timer);
        self.timer = 0;
    }

    fn forgetResults(self: *Search) void {
        self.picker.clear();
        if (self.results) |*results| results.deinit();
        self.results = null;
    }
};

pub const State = struct {
    palette: Palette = .{},
    search: Search = .{},
    handoff: c_uint = 0,
    suppress: bool = false,
    recents: std.ArrayList(Recent) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.handoff != 0) _ = gtk.g_source_remove(self.handoff);
        self.handoff = 0;
        self.search.cancelTimer();
        self.search.forgetResults();
        self.search.picker.deinit(allocator);
        self.palette.picker.deinit(allocator);
        dropFocus(&self.palette.refocus);
        dropFocus(&self.search.refocus);
        for (self.recents.items) |recent| recent.free(allocator);
        self.recents.deinit(allocator);
    }
};

const Section = enum { commands, settings };

const Command = struct {
    title: [:0]const u8,
    subtitle: [:0]const u8,
    keywords: []const u8 = "",
    shortcut: ?[:0]const u8 = null,
    icon: [:0]const u8,
    section: Section = .commands,
    needs_library: bool = false,
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

fn activateAction(comptime name: [*:0]const u8) *const fn (*App) void {
    return struct {
        fn run(self: *App) void {
            const root = self.window orelse return;
            _ = gtk.gtk_widget_activate_action_variant(gtk.cast(gtk.Widget, root), name, null);
        }
    }.run;
}

fn setting(comptime title: [:0]const u8, comptime tab: app.SettingsTab, comptime tab_name: []const u8, comptime keywords: []const u8, comptime icon: [:0]const u8) Command {
    return .{
        .title = title,
        .subtitle = "Settings › " ++ tab_name,
        .keywords = keywords,
        .icon = icon,
        .section = .settings,
        .run = openSettings(tab),
    };
}

const commands = [_]Command{
    .{ .title = "Scan library", .subtitle = "Rescan all music folders", .keywords = "rescan", .shortcut = "Ctrl ⇧ R", .icon = "view-refresh-symbolic", .run = jobs.rescan, .needs_library = true },
    .{ .title = "Scan for duplicates", .subtitle = "Library tools", .keywords = "find duplicates", .icon = "edit-copy-symbolic", .run = jobs.startDuplicates, .needs_library = true },
    .{ .title = "Show Library Health", .subtitle = "Go to", .keywords = "scan issues problems", .icon = "orca-health-symbolic", .run = goTo(.health) },
    .{ .title = "Measure loudness", .subtitle = "Library tools", .keywords = "analyze analyse replaygain fingerprints", .icon = "orca-pulse-symbolic", .run = jobs.startAnalysis, .needs_library = true },
    .{ .title = "Find matches", .subtitle = "Library tools", .keywords = "musicbrainz acoustid identify", .icon = "orca-matches-symbolic", .run = jobs.startMatching, .needs_library = true },
    .{ .title = "Verify recording IDs", .subtitle = "Library tools", .keywords = "acoustid", .icon = "auth-fingerprint-symbolic", .run = jobs.startLibraryVerification, .needs_library = true },
    .{ .title = "Submit to AcoustID", .subtitle = "Library tools", .icon = "auth-fingerprint-symbolic", .run = jobs.startSubmission, .needs_library = true },
    .{ .title = "Add music folder…", .subtitle = "Library tools", .shortcut = "Ctrl O", .icon = "list-add-symbolic", .run = jobs.chooseFolder, .needs_library = true },
    .{ .title = "Search library", .subtitle = "Go to", .keywords = "find", .icon = "orca-search-symbolic", .run = summonSearch, .needs_library = true },
    .{ .title = "Show Home", .subtitle = "Go to", .keywords = "daily mixes start radio this week", .icon = "orca-home-symbolic", .run = goTo(.home) },
    .{ .title = "Show Albums", .subtitle = "Go to", .icon = "orca-albums-symbolic", .run = goTo(.albums) },
    .{ .title = "Show Artists", .subtitle = "Go to", .icon = "orca-artists-symbolic", .run = goTo(.artists) },
    .{ .title = "Show Tracks", .subtitle = "Go to", .icon = "orca-tracks-symbolic", .run = goTo(.tracks) },
    .{ .title = "Show Genres", .subtitle = "Go to", .icon = "orca-genres-symbolic", .run = goTo(.genres) },
    .{ .title = "Show Folders", .subtitle = "Go to", .icon = "orca-folders-symbolic", .run = goTo(.folders) },
    .{ .title = "Show Loved", .subtitle = "Go to", .icon = "orca-loved-symbolic", .run = goTo(.loved) },
    .{ .title = "Show Playlists", .subtitle = "Go to", .icon = "orca-playlists-symbolic", .run = goTo(.playlists) },
    .{ .title = "Show Now Playing", .subtitle = "Go to", .icon = "orca-now-playing-symbolic", .run = goTo(.now_playing) },
    .{ .title = "Show Queue", .subtitle = "Go to", .shortcut = "Ctrl L", .icon = "orca-queue-symbolic", .run = goTo(.queue) },
    .{ .title = "Show Matches", .subtitle = "Go to", .icon = "orca-matches-symbolic", .run = goTo(.matches) },
    .{ .title = "Show Activity", .subtitle = "Go to", .keywords = "jobs tasks history background", .icon = "orca-pulse-symbolic", .run = goTo(.activity) },
    .{ .title = "Show Change History", .subtitle = "Go to", .keywords = "undo tag writes log", .icon = "orca-undo-symbolic", .run = goTo(.changes) },
    .{ .title = "Show Duplicates", .subtitle = "Go to", .keywords = "copies duplicate files health", .icon = "orca-health-symbolic", .run = goTo(.duplicates) },
    .{ .title = "Show Audio Problems", .subtitle = "Go to", .keywords = "clipping decode errors replaygain health", .icon = "orca-health-symbolic", .run = goTo(.audio_problems) },
    .{ .title = "Show Artwork Review", .subtitle = "Go to", .keywords = "artwork covers missing undersized health", .icon = "orca-health-symbolic", .run = goTo(.artwork_review) },
    .{ .title = "Show Metadata Issues", .subtitle = "Go to", .keywords = "metadata inconsistencies album artist dates track numbers genres musicbrainz health", .icon = "orca-health-symbolic", .run = goTo(.metadata_issues) },
    .{ .title = "Show Settings", .subtitle = "Go to", .keywords = "preferences", .shortcut = "Ctrl ,", .icon = "orca-settings-symbolic", .run = goTo(.settings) },
    .{ .title = "Toggle Inspector", .subtitle = "View", .keywords = "details", .shortcut = "Ctrl I", .icon = "orca-columns-symbolic", .run = details.toggle },
    .{ .title = "Toggle Lyrics", .subtitle = "View", .shortcut = "Ctrl ⇧ L", .icon = "media-view-subtitles-symbolic", .run = lyrics.toggle },
    .{ .title = "Show Signal Path", .subtitle = "View", .shortcut = "Ctrl ⇧ S", .icon = "orca-signal-symbolic", .run = details.toggleSignalPath },
    .{ .title = "Play/Pause", .subtitle = "Playback", .shortcut = "Space", .icon = "orca-play-symbolic", .run = transport.toggle },
    .{ .title = "Next", .subtitle = "Playback", .shortcut = "Ctrl →", .icon = "orca-next-symbolic", .run = transport.next },
    .{ .title = "Previous", .subtitle = "Playback", .shortcut = "Ctrl ←", .icon = "orca-previous-symbolic", .run = transport.previous },
    .{ .title = "Shuffle on/off", .subtitle = "Playback", .icon = "orca-shuffle-symbolic", .run = transport.toggleShuffle },
    .{ .title = "Repeat mode", .subtitle = "Playback", .icon = "orca-repeat-symbolic", .run = transport.cycleRepeat },
    .{ .title = "Save queue as playlist", .subtitle = "Playback", .icon = "orca-playlists-symbolic", .run = queue.askSaveName, .needs_library = true },
    .{ .title = "Keyboard shortcuts", .subtitle = "Help", .shortcut = "Ctrl ?", .icon = "orca-more-symbolic", .run = activateAction("app.shortcuts") },
    .{ .title = "About Orca", .subtitle = "Help", .icon = "orca-more-symbolic", .run = activateAction("app.about") },
    setting("Startup", .general, "General", "login autostart default page", "orca-play-symbolic"),
    setting("Notifications", .general, "General", "track changes library tasks", "orca-info-symbolic"),
    setting("Language & Sorting", .general, "General", "sort artist names articles", "orca-genres-symbolic"),
    setting("Keyboard", .general, "General", "shortcuts keys", "input-keyboard-symbolic"),
    setting("Scan settings", .library, "Library", "music folders watch", "folder-symbolic"),
    setting("Maintenance", .library, "Library", "", "folder-symbolic"),
    setting("AcoustID", .library, "Library", "fingerprints submit", "auth-fingerprint-symbolic"),
    setting("Volume", .playback, "Playback", "replaygain leveling", "orca-volume-high-symbolic"),
    setting("Output", .playback, "Playback", "gapless", "audio-card-symbolic"),
    setting("Equalizer", .sound, "Sound", "eq preset", "multimedia-volume-control-symbolic"),
    setting("Output device", .sound, "Sound", "", "audio-card-symbolic"),
    setting("Crossfeed", .sound, "Sound", "headphones", "audio-headphones-symbolic"),
    setting("Audio information", .sound, "Sound", "signal path", "orca-signal-symbolic"),
    setting("Scrobbling", .listening, "Listening", "listenbrainz", "audio-headphones-symbolic"),
    setting("Lyrics", .listening, "Listening", "lrclib", "media-view-subtitles-symbolic"),
    setting("Artist info", .listening, "Listening", "wikipedia biography photos", "avatar-default-symbolic"),
    setting("Color", .appearance, "Appearance", "artwork influence", "orca-image-symbolic"),
    setting("Type", .appearance, "Appearance", "typeface font numerals", "orca-type-symbolic"),
    setting("Layout", .appearance, "Appearance", "density grid counts inspector", "orca-grid-symbolic"),
    setting("Motion", .appearance, "Appearance", "reduce animation", "orca-pulse-symbolic"),
    setting("Data sources", .advanced, "Advanced", "providers", "emblem-system-symbolic"),
    setting("Library database", .advanced, "Advanced", "", "emblem-system-symbolic"),
    setting("About", .about, "About", "version", "emblem-system-symbolic"),
    setting("Diagnostics", .about, "About", "logs", "emblem-system-symbolic"),
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn editableText(widget: ?*gtk.Widget) []const u8 {
    const entry = widget orelse return "";
    return std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry)));
}

fn setText(self: *App, entry: *gtk.Widget, text: []const u8) void {
    var buffer: [query_capacity]u8 = undefined;
    self.palette.suppress = true;
    defer self.palette.suppress = false;
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), strings.terminated(&buffer, text).ptr);
    gtk.gtk_editable_set_position(gtk.cast(gtk.Editable, entry), -1);
}

fn keepFocus(slot: *?*gtk.Widget, self: *App) void {
    dropFocus(slot);
    const root = self.window orelse return;
    const focus = gtk.gtk_window_get_focus(root) orelse return;
    _ = gtk.g_object_ref(focus);
    slot.* = focus;
}

fn dropFocus(slot: *?*gtk.Widget) void {
    const widget = slot.* orelse return;
    slot.* = null;
    gtk.g_object_unref(widget);
}

fn restoreFocus(slot: *?*gtk.Widget) void {
    const widget = slot.* orelse return;
    if (gtk.gtk_widget_get_root(widget) != null) _ = gtk.gtk_widget_grab_focus(widget);
    dropFocus(slot);
}

fn cover(widget: *gtk.Widget, covered: bool) void {
    gtk.gtk_widget_set_can_focus(widget, @intFromBool(!covered));
    gtk.gtk_widget_set_can_target(widget, @intFromBool(!covered));
}

fn removeChildren(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn newLabel(text: []const u8, class: [*:0]const u8) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const label = gtk.gtk_label_new(strings.terminated(&buffer, text).ptr);
    gtk.gtk_widget_add_css_class(label, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    return label;
}

fn iconBox(icon_name: [*:0]const u8, pixels: c_int, class: [*:0]const u8) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(icon_name);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), if (pixels > row_thumb_pixels) 40 else 14);
    gtk.gtk_widget_add_css_class(icon, class);
    gtk.gtk_widget_set_size_request(icon, pixels, pixels);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    return icon;
}

pub fn attach(self: *App, entry: *gtk.Widget) void {
    _ = gtk.signalConnect(entry, "changed", gtk.callback(barTyped), self);
}

fn barTakesText(self: *App, text: []const u8) bool {
    if (isCommandText(text)) return true;
    if (text.len == 0) return false;
    return window.filterTarget(self) == null;
}

fn barTyped(editable: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.palette.suppress) return;
    const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, editable.?)));
    if (!barTakesText(self, text) or self.palette.handoff != 0) return;
    self.palette.handoff = gtk.g_idle_add(handOff, self);
}

fn handOff(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.palette.handoff = 0;
    const entry = self.top_bar.entry orelse return gtk.SOURCE_REMOVE;
    var buffer: [query_capacity]u8 = undefined;
    const typed = editableText(entry);
    if (!barTakesText(self, typed)) return gtk.SOURCE_REMOVE;
    const text = buffer[0..@min(typed.len, buffer.len)];
    @memcpy(text, typed[0..text.len]);
    setText(self, entry, "");
    const prefix = prefixLength(text);
    if (prefix != 0) openPalette(self, text[prefix..]) else openSearch(self, text);
    return gtk.SOURCE_REMOVE;
}

pub fn summon(self: *App) void {
    openPalette(self, "");
}

pub fn summonSearch(self: *App) void {
    openSearch(self, "");
}

pub fn dismiss(self: *App) void {
    closePalette(self, false);
    closeSearch(self, false);
}

pub fn active(self: *const App) bool {
    return self.palette.palette.open or self.palette.search.open;
}

pub fn forgetLibrary(self: *App) void {
    dismiss(self);
    const palette = &self.palette;
    palette.search.cancelTimer();
    palette.search.forgetResults();
    for (palette.recents.items) |recent| recent.free(self.allocator);
    palette.recents.clearRetainingCapacity();
}

pub fn wrapWindow(self: *App, content: *gtk.Widget) *gtk.Widget {
    const overlay = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, overlay), content);
    self.palette.palette.covered = content;
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), buildPalette(self));
    return overlay;
}

fn keyHint(keys: [*:0]const u8, action: [*:0]const u8) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const key = gtk.gtk_label_new(keys);
    gtk.gtk_widget_add_css_class(key, "palette-key");
    const text = gtk.gtk_label_new(action);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), key);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), text);
    return box;
}

fn buildPalette(self: *App) *gtk.Widget {
    const palette = &self.palette.palette;
    const layer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(layer, "palette-scrim");
    gtk.gtk_widget_set_visible(layer, gtk.false_);
    const press = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(press, "released", gtk.callback(scrimClicked), self);
    gtk.gtk_widget_add_controller(layer, press);

    const dialog = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(dialog, "palette");
    gtk.gtk_widget_set_overflow(dialog, gtk.OVERFLOW_HIDDEN);
    _ = gtk.signalConnect(dialog, "get-child-position", gtk.callback(placeFrost), self);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, dialog), frost.newLayer(&palette.frost, palette.covered.?));
    const surface = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(surface, "palette-surface");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, dialog), surface);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, dialog), surface, gtk.true_);

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(header, "palette-header");
    const prefix = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(prefix, "palette-prefix");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(entry, "palette-entry");
    gtk.gtk_widget_set_hexpand(entry, gtk.true_);
    gtk.gtk_widget_set_valign(entry, gtk.ALIGN_CENTER);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), "Type a command");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, entry), gtk.ACCESSIBLE_PROPERTY_LABEL, "Command", @as(c_int, -1));
    _ = gtk.signalConnect(entry, "changed", gtk.callback(paletteTyped), self);
    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(paletteKeyPressed), self);
    gtk.gtk_widget_add_controller(entry, keys);
    const escape = gtk.gtk_label_new("esc");
    gtk.gtk_widget_add_css_class(escape, "palette-key");
    gtk.gtk_widget_set_valign(escape, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), prefix);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), entry);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), escape);

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(list, "palette-list");
    const scroller = gtk.gtk_scrolled_window_new();
    const scrolled = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(scrolled, gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(scrolled, palette_list_height);
    gtk.gtk_scrolled_window_set_child(scrolled, list);

    const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 18);
    gtk.gtk_widget_add_css_class(footer, "palette-footer");
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), keyHint("↑↓", "Move"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), keyHint("↵", "Run"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), keyHint("Ctrl ↵", "Play"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), keyHint("Shift ↵", "Play Next"));
    const tip = gtk.gtk_label_new("Type without › to search your library");
    gtk.gtk_widget_set_hexpand(tip, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, tip), 1);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, tip), gtk.ELLIPSIZE_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), tip);

    gtk.gtk_box_append(gtk.cast(gtk.Box, surface), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, surface), scroller);
    gtk.gtk_box_append(gtk.cast(gtk.Box, surface), footer);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), palette_width);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), palette_width);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), dialog);
    gtk.gtk_widget_set_valign(clamp, gtk.ALIGN_START);
    gtk.gtk_widget_set_margin_top(clamp, palette_top);
    gtk.gtk_widget_set_margin_start(clamp, window_gutter);
    gtk.gtk_widget_set_margin_end(clamp, window_gutter);
    gtk.gtk_box_append(gtk.cast(gtk.Box, layer), clamp);

    palette.layer = layer;
    palette.dialog = dialog;
    palette.entry = entry;
    palette.list = gtk.cast(gtk.Box, list);
    palette.scroller = scrolled;
    return layer;
}

fn placeFrost(overlay: ?*anyopaque, child: ?*anyopaque, allocation: *gtk.Rectangle, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const palette = &state(data).palette.palette;
    const layer = palette.frost.layer orelse return gtk.false_;
    const covered = palette.covered orelse return gtk.false_;
    if (child != @as(?*anyopaque, layer)) return gtk.false_;
    var bounds: gtk.Rect = .{};
    if (gtk.gtk_widget_compute_bounds(gtk.cast(gtk.Widget, overlay.?), covered, &bounds) == 0) return gtk.false_;
    allocation.* = .{
        .x = -@as(c_int, @intFromFloat(@round(bounds.x))),
        .y = -@as(c_int, @intFromFloat(@round(bounds.y))),
        .width = gtk.gtk_widget_get_width(covered),
        .height = gtk.gtk_widget_get_height(covered),
    };
    return gtk.true_;
}

fn openPalette(self: *App, text: []const u8) void {
    const palette = &self.palette.palette;
    const layer = palette.layer orelse return;
    const entry = palette.entry orelse return;
    if (!palette.open) {
        palette.open = true;
        keepFocus(&palette.refocus, self);
        if (palette.covered) |covered| cover(covered, true);
        frost.capture(&palette.frost);
        gtk.gtk_widget_set_visible(layer, gtk.true_);
    }
    setText(self, entry, text);
    _ = gtk.gtk_widget_grab_focus(entry);
    gtk.gtk_editable_set_position(gtk.cast(gtk.Editable, entry), -1);
    refreshPalette(self);
}

fn closePalette(self: *App, restore: bool) void {
    const palette = &self.palette.palette;
    if (!palette.open) return;
    palette.open = false;
    if (palette.covered) |covered| cover(covered, false);
    if (palette.layer) |layer| gtk.gtk_widget_set_visible(layer, gtk.false_);
    frost.release(&palette.frost);
    palette.picker.clear();
    if (palette.list) |list| removeChildren(list);
    if (palette.entry) |entry| setText(self, entry, "");
    if (restore) restoreFocus(&palette.refocus) else dropFocus(&palette.refocus);
}

fn scrimClicked(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const palette = &self.palette.palette;
    if (!palette.open) return;
    const layer = palette.layer orelse return;
    const dialog = palette.dialog orelse return;
    _ = gesture;
    if (gtk.gtk_widget_pick(layer, x, y, 0)) |target| {
        if (target == dialog or gtk.gtk_widget_is_ancestor(target, dialog) != 0) return;
    }
    closePalette(self, true);
}

fn paletteQuery(self: *App) []const u8 {
    const text = std.mem.trim(u8, editableText(self.palette.palette.entry), " \t");
    return std.mem.trimStart(u8, text[prefixLength(text)..], " \t");
}

fn paletteTyped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.palette.suppress or !self.palette.palette.open) return;
    refreshPalette(self);
}

fn paletteKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const palette = &self.palette.palette;
    if (!palette.open) return gtk.false_;
    switch (keyval) {
        gtk.KEY_Up => selectPalette(self, if (palette.picker.selected == 0) 0 else palette.picker.selected - 1),
        gtk.KEY_Down => selectPalette(self, palette.picker.selected + 1),
        gtk.KEY_Return, gtk.KEY_KP_Enter, gtk.KEY_ISO_Enter => activatePalette(self, palette.picker.selected, activation(modifiers)),
        gtk.KEY_Escape => closePalette(self, true),
        gtk.KEY_BackSpace => {
            if (editableText(palette.entry).len != 0) return gtk.false_;
            closePalette(self, false);
            openSearch(self, "");
        },
        else => return gtk.false_,
    }
    return gtk.true_;
}

const Activation = enum { open, play, play_next };

fn activation(modifiers: c_uint) Activation {
    const held = modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT);
    if (held & gtk.MODIFIER_CONTROL != 0) return .play;
    if (held == gtk.MODIFIER_SHIFT) return .play_next;
    return .open;
}

fn refreshPalette(self: *App) void {
    const palette = &self.palette.palette;
    const list = palette.list orelse return;
    palette.picker.clear();
    removeChildren(list);
    const query = paletteQuery(self);
    showCommands(self, .commands, "COMMANDS", query);
    showCommands(self, .settings, "SETTINGS", query);
    showRecents(self);
    if (palette.picker.rows.items.len == 0) {
        const empty = gtk.gtk_label_new("No matching commands");
        gtk.gtk_widget_add_css_class(empty, "palette-empty");
        gtk.gtk_box_append(list, empty);
    }
    if (palette.scroller) |scroller| gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), 0);
    selectPalette(self, 0);
}

fn paletteHeading(self: *App, text: [*:0]const u8) void {
    const list = self.palette.palette.list orelse return;
    const label = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(label, "palette-heading");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_box_append(list, label);
}

fn showCommands(self: *App, section: Section, heading: [*:0]const u8, query: []const u8) void {
    var headed = false;
    for (commands, 0..) |command, index| {
        if (command.section != section) continue;
        if (command.needs_library and self.library == null) continue;
        if (!matches(&.{ command.title, command.subtitle, command.keywords }, query)) continue;
        if (!headed) paletteHeading(self, heading);
        headed = true;
        addPaletteRow(self, .{ .command = index }, command.icon, command.title, command.subtitle, command.shortcut);
    }
}

fn recentVerb(kind: SearchKind) []const u8 {
    return if (kind == .artist) "Show" else "Play";
}

fn showRecents(self: *App) void {
    if (self.palette.recents.items.len != 0) paletteHeading(self, "RECENT");
    for (self.palette.recents.items, 0..) |recent, index| {
        var buffer: [512]u8 = undefined;
        const title = strings.format(&buffer, "{s} {s}", .{ recentVerb(recent.kind), recent.title });
        addPaletteRow(self, .{ .recent = index }, kindIcon(recent.kind), title, recent.detail, if (recent.kind == .artist) null else "Ctrl ↵");
    }
}

fn kindIcon(kind: SearchKind) [:0]const u8 {
    return switch (kind) {
        .artist => "orca-artists-symbolic",
        .release => "orca-albums-symbolic",
        .track => "orca-tracks-symbolic",
        .playlist => "orca-playlists-symbolic",
        .genre => "orca-genres-symbolic",
    };
}

fn matches(fields: []const []const u8, query: []const u8) bool {
    var wanted = std.mem.tokenizeAny(u8, query, " \t");
    while (wanted.next()) |word| {
        if (!anyWordStarts(fields, word)) return false;
    }
    return true;
}

fn anyWordStarts(fields: []const []const u8, prefix: []const u8) bool {
    for (fields) |field| {
        var words = std.mem.tokenizeAny(u8, field, " /›·");
        while (words.next()) |candidate| {
            if (candidate.len >= prefix.len and std.ascii.eqlIgnoreCase(candidate[0..prefix.len], prefix)) return true;
        }
    }
    return false;
}

fn addPaletteRow(self: *App, choice: Choice, icon_name: [*:0]const u8, title: []const u8, subtitle: []const u8, shortcut: ?[:0]const u8) void {
    const palette = &self.palette.palette;
    const list = palette.list orelse return;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "palette-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), iconBox(icon_name, icon_box_pixels, "palette-icon"));
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), newLabel(title, "palette-title"));
    if (subtitle.len > 0) gtk.gtk_box_append(gtk.cast(gtk.Box, labels), newLabel(subtitle, "palette-subtitle"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), labels);
    if (shortcut) |keys| {
        const hint = gtk.gtk_label_new(keys.ptr);
        gtk.gtk_widget_add_css_class(hint, "palette-shortcut");
        gtk.gtk_widget_set_valign(hint, gtk.ALIGN_CENTER);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), hint);
    }
    if (!register(self, &palette.picker, choice, row, gtk.callback(paletteRowClicked))) return;
    gtk.gtk_box_append(list, row);
}

fn register(self: *App, picker: *Picker, choice: Choice, row: *gtk.Widget, clicked: gtk.GCallback) bool {
    picker.choices.append(self.allocator, choice) catch return discard(row);
    picker.rows.append(self.allocator, row) catch {
        _ = picker.choices.pop();
        return discard(row);
    };
    gtk.g_object_set_data(row, index_key, @ptrFromInt(picker.rows.items.len));
    const click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(click, "released", clicked, self);
    gtk.gtk_widget_add_controller(row, click);
    return true;
}

fn discard(widget: *gtk.Widget) bool {
    _ = gtk.g_object_ref_sink(widget);
    gtk.g_object_unref(widget);
    return false;
}

fn rowIndex(gesture: ?*anyopaque) ?usize {
    const row = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture.?));
    const position = @intFromPtr(gtk.g_object_get_data(row, index_key));
    return if (position == 0) null else position - 1;
}

fn paletteRowClicked(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    activatePalette(state(data), rowIndex(gesture) orelse return, .open);
}

fn selectPalette(self: *App, wanted: usize) void {
    const palette = &self.palette.palette;
    selectRow(&palette.picker, wanted);
    const rows = palette.picker.rows.items;
    if (rows.len == 0) return;
    reveal(palette.scroller, gtk.cast(gtk.Widget, palette.list orelse return), rows[palette.picker.selected]);
}

fn selectRow(picker: *Picker, wanted: usize) void {
    const rows = picker.rows.items;
    if (rows.len == 0) return;
    const index = @min(wanted, rows.len - 1);
    if (picker.selected < rows.len) gtk.gtk_widget_remove_css_class(rows[picker.selected], "selected");
    picker.selected = index;
    gtk.gtk_widget_add_css_class(rows[index], "selected");
}

fn reveal(scroller: ?*gtk.ScrolledWindow, content: *gtk.Widget, row: *gtk.Widget) void {
    const scrolled = scroller orelse return;
    var bounds: gtk.Rect = .{};
    if (gtk.gtk_widget_compute_bounds(row, content, &bounds) == 0) return;
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(scrolled);
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

fn activatePalette(self: *App, index: usize, how: Activation) void {
    const palette = &self.palette.palette;
    if (index >= palette.picker.choices.items.len) return;
    switch (palette.picker.choices.items[index]) {
        .command => |command| {
            closePalette(self, true);
            commands[command].run(self);
        },
        .recent => |position| {
            const recent = self.palette.recents.items[position];
            closePalette(self, true);
            openEntity(self, recent.kind, recent.id, if (how == .open and recent.kind != .artist) .play else how);
        },
        .hit => {},
    }
}

pub fn wrapSearch(self: *App, content: *gtk.Widget) *gtk.Widget {
    const overlay = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, overlay), content);
    const search = &self.palette.search;
    search.covered = content;
    const frosted = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(frosted, "search-frost");
    gtk.gtk_widget_set_visible(frosted, gtk.false_);
    const layer = frost.newLayer(&search.frost, content);
    gtk.gtk_widget_set_vexpand(layer, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, frosted), layer);
    search.frosted = frosted;
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), frosted);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, overlay), buildSearch(self));
    return overlay;
}

fn historyButton(icon_name: [*:0]const u8, label: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon_name);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "search-history");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, label, @as(c_int, -1));
    return button;
}

fn buildSearch(self: *App) *gtk.Widget {
    const search = &self.palette.search;
    const view = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(view, "search-view");
    gtk.gtk_widget_set_visible(view, gtk.false_);

    const top = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(top, "search-top");
    const back = historyButton("orca-back-symbolic", "Close search");
    gtk.gtk_widget_set_tooltip_text(back, "Close search (Esc)");
    _ = gtk.signalConnect(back, "clicked", gtk.callback(backClicked), self);
    const forward = historyButton("orca-forward-symbolic", "Forward");
    gtk.gtk_widget_set_sensitive(forward, gtk.false_);
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_widget_add_css_class(entry, "search-field");
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search your library…");
    gtk.gtk_search_entry_set_search_delay(gtk.cast(gtk.SearchEntry, entry), app.search_delay_ms);
    gtk.gtk_editable_set_width_chars(gtk.cast(gtk.Editable, entry), 12);
    gtk.gtk_editable_set_max_width_chars(gtk.cast(gtk.Editable, entry), search_entry_chars);
    gtk.gtk_widget_set_valign(entry, gtk.ALIGN_CENTER);
    if (gtk.gtk_widget_get_first_child(entry)) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), "orca-search-symbolic");
    if (gtk.gtk_widget_get_last_child(entry)) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), "orca-close-symbolic");
    _ = gtk.signalConnect(entry, "search-changed", gtk.callback(searchTyped), self);
    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_CAPTURE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(searchKeyPressed), self);
    gtk.gtk_widget_add_controller(entry, keys);
    const hint = gtk.gtk_label_new("↑↓ to move · ↵ to open · Ctrl ↵ to play · Shift ↵ to play next");
    gtk.gtk_widget_add_css_class(hint, "search-hint");
    gtk.gtk_widget_set_hexpand(hint, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, hint), 1);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, hint), gtk.ELLIPSIZE_START);
    gtk.gtk_box_append(gtk.cast(gtk.Box, top), back);
    gtk.gtk_box_append(gtk.cast(gtk.Box, top), forward);
    gtk.gtk_box_append(gtk.cast(gtk.Box, top), entry);
    gtk.gtk_box_append(gtk.cast(gtk.Box, top), hint);

    const chips = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(chips, "search-chips");
    var group: ?*gtk.ToggleButton = null;
    for (chip_labels, 0..) |label, index| {
        const chip = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, chip), label);
        gtk.gtk_widget_add_css_class(chip, "search-chip");
        gtk.gtk_widget_set_focus_on_click(chip, gtk.false_);
        gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, chip), group);
        if (group == null) {
            group = gtk.cast(gtk.ToggleButton, chip);
            gtk.gtk_toggle_button_set_active(group.?, gtk.true_);
        }
        _ = gtk.signalConnect(chip, "toggled", gtk.callback(chipToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, chips), chip);
        search.chip_buttons[index] = chip;
    }

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 26);
    gtk.gtk_widget_add_css_class(content, "search-results");
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), chips);
    const scroller = gtk.gtk_scrolled_window_new();
    const scrolled = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(scrolled, content);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);

    gtk.gtk_box_append(gtk.cast(gtk.Box, view), top);
    gtk.gtk_box_append(gtk.cast(gtk.Box, view), scroller);

    search.layer = view;
    search.entry = entry;
    search.content = gtk.cast(gtk.Box, content);
    search.chips = chips;
    search.scroller = scrolled;
    return view;
}

fn openSearch(self: *App, text: []const u8) void {
    const search = &self.palette.search;
    const layer = search.layer orelse return;
    const entry = search.entry orelse return;
    if (!search.open) {
        search.open = true;
        keepFocus(&search.refocus, self);
        if (search.covered) |covered| cover(covered, true);
        frost.capture(&search.frost);
        if (search.frosted) |frosted| gtk.gtk_widget_set_visible(frosted, gtk.true_);
        gtk.gtk_widget_set_visible(layer, gtk.true_);
    }
    search.kind = null;
    self.palette.suppress = true;
    if (search.chip_buttons[0]) |all| gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, all), gtk.true_);
    self.palette.suppress = false;
    setText(self, entry, text);
    _ = gtk.gtk_widget_grab_focus(entry);
    gtk.gtk_editable_set_position(gtk.cast(gtk.Editable, entry), -1);
    runSearch(self, true);
}

fn closeSearch(self: *App, restore: bool) void {
    const search = &self.palette.search;
    if (!search.open) return;
    search.open = false;
    search.cancelTimer();
    if (search.covered) |covered| cover(covered, false);
    if (search.layer) |layer| gtk.gtk_widget_set_visible(layer, gtk.false_);
    if (search.frosted) |frosted| gtk.gtk_widget_set_visible(frosted, gtk.false_);
    frost.release(&search.frost);
    clearResults(self);
    search.searched = false;
    if (search.entry) |entry| setText(self, entry, "");
    if (restore) restoreFocus(&search.refocus) else dropFocus(&search.refocus);
}

fn backClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    closeSearch(state(data), true);
}

fn chipToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const search = &self.palette.search;
    if (self.palette.suppress) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == 0) return;
    for (search.chip_buttons, chip_kinds) |chip, kind| {
        if (@as(?*anyopaque, chip) == button) search.kind = kind;
    }
    runSearch(self, true);
    if (search.entry) |entry| _ = gtk.gtk_widget_grab_focus(entry);
}

fn searchTyped(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.palette.suppress) return;
    const search = &self.palette.search;
    search.cancelTimer();
    search.timer = gtk.g_timeout_add(search_delay_ms, searchLater, self);
}

fn searchLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.palette.search.timer = 0;
    runSearch(self, false);
    return gtk.SOURCE_REMOVE;
}

fn searchKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const search = &self.palette.search;
    if (!search.open) return gtk.false_;
    switch (keyval) {
        gtk.KEY_Up => selectSearch(self, if (search.picker.selected == 0) 0 else search.picker.selected - 1),
        gtk.KEY_Down => selectSearch(self, search.picker.selected + 1),
        gtk.KEY_Return, gtk.KEY_KP_Enter, gtk.KEY_ISO_Enter => {
            runSearch(self, false);
            activateSearch(self, search.picker.selected, activation(modifiers));
        },
        gtk.KEY_Escape => closeSearch(self, true),
        else => return gtk.false_,
    }
    return gtk.true_;
}

fn searchQuery(self: *App) []const u8 {
    return std.mem.trim(u8, editableText(self.palette.search.entry), " \t");
}

fn clearResults(self: *App) void {
    const search = &self.palette.search;
    search.forgetResults();
    const content = search.content orelse return;
    const chips = search.chips orelse return;
    while (gtk.gtk_widget_get_next_sibling(chips)) |child| gtk.gtk_box_remove(content, child);
}

fn limitsFor(kind: ?SearchKind) liborca.SearchLimits {
    const chosen = kind orelse return .{ .tracks = 5 };
    var limits: liborca.SearchLimits = .{ .artists = 0, .releases = 0, .tracks = 0, .playlists = 0, .genres = 0 };
    switch (chosen) {
        .artist => limits.artists = kind_limit,
        .release => limits.releases = kind_limit,
        .track => limits.tracks = kind_limit,
        .playlist => {
            limits.artists = 1;
            limits.playlists = kind_limit;
        },
        .genre => {
            limits.artists = 1;
            limits.genres = kind_limit;
        },
    }
    return limits;
}

fn runSearch(self: *App, force: bool) void {
    const search = &self.palette.search;
    if (!search.open) return;
    const content = search.content orelse return;
    search.cancelTimer();
    const query = searchQuery(self);
    const stored = query[0..@min(query.len, search.query.len)];
    if (!force and search.searched and std.mem.eql(u8, stored, search.query[0..search.query_len])) return;
    @memcpy(search.query[0..stored.len], stored);
    search.query_len = stored.len;
    search.searched = true;

    clearResults(self);
    if (search.scroller) |scroller| gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), 0);
    if (query.len == 0) return message(self, "Search artists, albums, tracks, playlists and genres");
    const library = self.library orelse return message(self, "No library is open");
    search.results = self.runtime.librarySearch(library, query, limitsFor(search.kind)) catch return message(self, "Search failed");
    const results = &search.results.?;
    if (search.kind) |kind| showKind(self, results, kind) else showAll(self, results);
    if (search.picker.rows.items.len == 0) {
        var buffer: [query_capacity + 32]u8 = undefined;
        return message(self, strings.format(&buffer, "No results for “{s}”", .{stored}));
    }
    _ = content;
    selectSearch(self, 0);
}

fn message(self: *App, text: []const u8) void {
    const content = self.palette.search.content orelse return;
    const label = newLabel(text, "search-empty");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    gtk.gtk_box_append(content, label);
}

fn isTop(results: *const liborca.SearchResults, hit: SearchHit) bool {
    const top = results.top orelse return false;
    return top.kind == hit.kind and top.id == hit.id;
}

fn countKind(results: *const liborca.SearchResults, kind: SearchKind, skip_top: bool) usize {
    var count: usize = 0;
    for (results.hits) |hit| {
        if (hit.kind == kind and !(skip_top and isTop(results, hit))) count += 1;
    }
    return count;
}

fn firstArtist(results: *const liborca.SearchResults) []const u8 {
    for (results.hits) |hit| {
        if (hit.kind == .artist) return hit.title;
    }
    return "";
}

const Group = struct {
    kind: SearchKind,
    heading: [*:0]const u8,
};

fn groupHeading(kind: SearchKind) [*:0]const u8 {
    return switch (kind) {
        .artist => "ARTISTS",
        .release => "ALBUMS",
        .track => "TRACKS",
        .playlist => "PLAYLISTS",
        .genre => "GENRES",
    };
}

fn newSection(heading: [*:0]const u8) *gtk.Widget {
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(section, "search-section");
    const label = gtk.gtk_label_new(heading);
    gtk.gtk_widget_add_css_class(label, "search-heading");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), label);
    return section;
}

fn showAll(self: *App, results: *const liborca.SearchResults) void {
    const content = self.palette.search.content orelse return;
    const first = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    var first_used = false;
    if (results.top) |top| {
        const section = newSection("TOP RESULT");
        gtk.gtk_widget_set_size_request(section, top_section_width, -1);
        addTopCard(self, results, top, section);
        gtk.gtk_box_append(gtk.cast(gtk.Box, first), section);
        first_used = true;
    }
    if (countKind(results, .track, true) > 0) {
        const section = kindSection(self, results, .track, true);
        gtk.gtk_widget_set_hexpand(section, gtk.true_);
        gtk.gtk_box_append(gtk.cast(gtk.Box, first), section);
        first_used = true;
    }
    if (first_used) gtk.gtk_box_append(content, first) else _ = discard(first);

    for ([_]SearchKind{ .release, .artist }) |kind| {
        if (countKind(results, kind, true) > 0) gtk.gtk_box_append(content, kindSection(self, results, kind, true));
    }

    const last = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, last), gtk.true_);
    var last_used = false;
    for ([_]SearchKind{ .playlist, .genre }) |kind| {
        if (countKind(results, kind, true) == 0) continue;
        const section = kindSection(self, results, kind, true);
        gtk.gtk_widget_set_hexpand(section, gtk.true_);
        gtk.gtk_box_append(gtk.cast(gtk.Box, last), section);
        last_used = true;
    }
    if (last_used) gtk.gtk_box_append(content, last) else _ = discard(last);
}

fn showKind(self: *App, results: *const liborca.SearchResults, kind: SearchKind) void {
    const content = self.palette.search.content orelse return;
    if (countKind(results, kind, false) == 0) return;
    gtk.gtk_box_append(content, kindSection(self, results, kind, false));
}

fn kindSection(self: *App, results: *const liborca.SearchResults, kind: SearchKind, skip_top: bool) *gtk.Widget {
    const section = newSection(groupHeading(kind));
    var tiles: ?*gtk.FlowBox = null;
    if (kind == .release) {
        const flow = gtk.gtk_flow_box_new();
        gtk.gtk_widget_add_css_class(flow, "search-albums");
        const box = gtk.cast(gtk.FlowBox, flow);
        gtk.gtk_flow_box_set_selection_mode(box, gtk.SELECTION_NONE);
        gtk.gtk_flow_box_set_homogeneous(box, gtk.true_);
        gtk.gtk_flow_box_set_column_spacing(box, 20);
        gtk.gtk_flow_box_set_row_spacing(box, 20);
        gtk.gtk_flow_box_set_min_children_per_line(box, 1);
        gtk.gtk_flow_box_set_max_children_per_line(box, 12);
        gtk.gtk_box_append(gtk.cast(gtk.Box, section), flow);
        tiles = box;
    }
    const artist = firstArtist(results);
    for (results.hits) |hit| {
        if (hit.kind != kind or (skip_top and isTop(results, hit))) continue;
        const row = switch (kind) {
            .release => albumTile(self, hit),
            .track => trackRow(self, hit),
            .artist => artistRow(self, hit),
            .playlist => playlistRow(self, hit, artist),
            .genre => genreRow(hit, artist),
        };
        if (!register(self, &self.palette.search.picker, .{ .hit = hit }, row, gtk.callback(searchRowClicked))) continue;
        albums.showPlaying(row, hitPlaying(self.playing(), hit));
        if (tiles) |flow| {
            gtk.gtk_flow_box_append(flow, row);
            if (gtk.gtk_widget_get_parent(row)) |child| gtk.gtk_widget_set_can_focus(child, gtk.false_);
        } else gtk.gtk_box_append(gtk.cast(gtk.Box, section), row);
    }
    return section;
}

fn rowLabels(title: []const u8, subtitle: []const u8) *gtk.Widget {
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), newLabel(title, "search-row-title"));
    if (subtitle.len > 0) gtk.gtk_box_append(gtk.cast(gtk.Box, labels), newLabel(subtitle, "search-row-subtitle"));
    return labels;
}

fn newRow() *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "search-row");
    return row;
}

fn trackAlbum(hit: SearchHit) []const u8 {
    if (hit.artist.len > 0 and std.mem.startsWith(u8, hit.subtitle, hit.artist))
        return std.mem.trimStart(u8, hit.subtitle[hit.artist.len..], " ");
    return hit.subtitle;
}

fn joined(buffer: []u8, parts: []const []const u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var first = true;
    for (parts) |part| {
        if (part.len == 0) continue;
        if (!first) writer.writeAll(" · ") catch break;
        writer.writeAll(part) catch break;
        first = false;
    }
    return writer.buffered();
}

fn counted(buffer: []u8, count: u64, one: []const u8, many: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) one else many }) catch "";
}

fn trackRow(self: *App, hit: SearchHit) *gtk.Widget {
    const row = newRow();
    const thumb = art.newCover(self, art.iconPlaceholder(row_thumb_pixels), row_thumb_pixels);
    gtk.gtk_widget_add_css_class(thumb, "search-thumb");
    art.show(self, thumb, art.Key.track(hit.id, .thumb));
    var buffer: [512]u8 = undefined;
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), thumb);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), rowLabels(hit.title, joined(&buffer, &.{ hit.artist, trackAlbum(hit) })));
    if (hit.duration_ms) |duration| {
        var time: [32]u8 = undefined;
        const label = gtk.gtk_label_new(strings.formatMs(&time, @intCast(@max(duration, 0))).ptr);
        gtk.gtk_widget_add_css_class(label, "search-row-time");
        gtk.gtk_widget_add_css_class(label, "numeric");
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), label);
    }
    return row;
}

fn artistMeta(buffer: []u8, hit: SearchHit, with_kind: bool) []const u8 {
    var releases: [32]u8 = undefined;
    var tracks: [32]u8 = undefined;
    return joined(buffer, &.{
        if (with_kind) "Artist" else "",
        counted(&releases, hit.release_count, "album", "albums"),
        counted(&tracks, hit.track_count, "track", "tracks"),
    });
}

fn portrait(self: *App, artist_id: i64, name: []const u8, pixels: c_int) *gtk.Widget {
    const picture = art.newCover(self, art.initialsPlaceholder(), pixels);
    gtk.gtk_widget_add_css_class(picture, "search-portrait");
    art.setInitials(picture, name);
    art.showArtist(self, picture, artist_id, .unknown, artists.firstRelease(self, artist_id), art.Size.atLeast(pixels));
    return picture;
}

fn artistRow(self: *App, hit: SearchHit) *gtk.Widget {
    const row = newRow();
    var buffer: [128]u8 = undefined;
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), portrait(self, hit.id, hit.title, row_thumb_pixels));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), rowLabels(hit.title, artistMeta(&buffer, hit, true)));
    return row;
}

fn yearText(buffer: []u8, year: ?i32) []const u8 {
    const value = year orelse return "";
    return std.fmt.bufPrint(buffer, "{d}", .{@as(u32, @intCast(@max(value, 0)))}) catch "";
}

fn albumTile(self: *App, hit: SearchHit) *gtk.Widget {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "search-tile");
    gtk.gtk_widget_set_size_request(tile, tile_pixels, -1);
    gtk.gtk_widget_set_halign(tile, gtk.ALIGN_START);
    const art_widget = art.newCover(self, art.initialsPlaceholder(), tile_pixels);
    gtk.gtk_widget_add_css_class(art_widget, "search-tile-art");
    art.setInitials(art_widget, hit.title);
    art.show(self, art_widget, art.Key.release(hit.id, .tile));
    var year: [16]u8 = undefined;
    var buffer: [512]u8 = undefined;
    const title = newLabel(hit.title, "search-tile-title");
    const meta = newLabel(joined(&buffer, &.{ hit.artist, yearText(&year, hit.year) }), "search-tile-meta");
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), art_widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), meta);
    return tile;
}

fn playlistDetail(buffer: []u8, hit: SearchHit, artist: []const u8, with_kind: bool) []const u8 {
    if (hit.reason == .tracks_by)
        return std.fmt.bufPrint(buffer, "Playlist · contains {d} {s} {s}", .{ hit.reason_count, artist, if (hit.reason_count == 1) "track" else "tracks" }) catch "";
    if (hit.duration_ms == null) return "Smart playlist";
    var count: [32]u8 = undefined;
    return joined(buffer, &.{ if (with_kind) "Playlist" else "", counted(&count, hit.track_count, "track", "tracks") });
}

fn playlistRow(self: *App, hit: SearchHit, artist: []const u8) *gtk.Widget {
    const row = newRow();
    var buffer: [512]u8 = undefined;
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), playlistArt(self, hit));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), rowLabels(hit.title, playlistDetail(&buffer, hit, artist, true)));
    return row;
}

fn playlistCovers(self: *App, playlist_id: i64, covers: *[4]i64) usize {
    const library = self.library orelse return 0;
    const page = self.runtime.libraryPlaylistEntries(library, playlist_id, mosaic_entries, 0) catch return 0;
    defer page.deinit();
    var count: usize = 0;
    for (page.items) |entry| {
        const track = entry.track orelse continue;
        const release_id = track.release_id orelse continue;
        if (std.mem.indexOfScalar(i64, covers[0..count], release_id) != null) continue;
        covers[count] = release_id;
        count += 1;
        if (count == covers.len) break;
    }
    return count;
}

fn playlistArt(self: *App, hit: SearchHit) *gtk.Widget {
    var covers: [4]i64 = undefined;
    const count = if (hit.duration_ms == null) 0 else playlistCovers(self, hit.id, &covers);
    if (count == 0) return iconBox(if (hit.duration_ms == null) "orca-sparkle-symbolic" else "orca-playlists-symbolic", row_thumb_pixels, "search-icon");
    if (count < covers.len) {
        const single = art.newCover(self, art.iconPlaceholder(row_thumb_pixels), row_thumb_pixels);
        gtk.gtk_widget_add_css_class(single, "search-thumb");
        art.show(self, single, art.Key.release(covers[0], .thumb));
        return single;
    }
    const half = @divTrunc(row_thumb_pixels, 2);
    const grid = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(grid, "search-mosaic");
    gtk.gtk_widget_set_overflow(grid, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_valign(grid, gtk.ALIGN_CENTER);
    for (0..2) |line| {
        const strip = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        for (0..2) |column| {
            const cell = art.newCover(self, art.iconPlaceholder(half), half);
            gtk.gtk_widget_add_css_class(cell, "search-mosaic-cell");
            art.show(self, cell, art.Key.release(covers[line * 2 + column], .thumb));
            gtk.gtk_box_append(gtk.cast(gtk.Box, strip), cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), strip);
    }
    return grid;
}

fn genreDetail(buffer: []u8, hit: SearchHit, artist: []const u8) []const u8 {
    if (hit.reason == .main_genre_of) return std.fmt.bufPrint(buffer, "{s}’s main genre", .{artist}) catch "";
    return counted(buffer, hit.track_count, "track", "tracks");
}

fn genreRow(hit: SearchHit, artist: []const u8) *gtk.Widget {
    const row = newRow();
    gtk.gtk_widget_add_css_class(row, "search-genre-row");
    const name = newLabel(hit.title, "search-row-title");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    var buffer: [512]u8 = undefined;
    const detail = newLabel(genreDetail(&buffer, hit, artist), "search-row-subtitle");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), detail);
    return row;
}

fn addTopCard(self: *App, results: *const liborca.SearchResults, hit: SearchHit, section: *gtk.Widget) void {
    const card = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(card, "search-top-card");
    gtk.gtk_widget_set_valign(card, gtk.ALIGN_START);
    const picture = switch (hit.kind) {
        .artist => portrait(self, hit.id, hit.title, portrait_pixels),
        .release, .track => square: {
            const square = art.newCover(self, art.initialsPlaceholder(), portrait_pixels);
            gtk.gtk_widget_add_css_class(square, "search-top-art");
            art.setInitials(square, hit.title);
            art.show(self, square, if (hit.kind == .release) art.Key.release(hit.id, .medium) else art.Key.track(hit.id, .medium));
            break :square square;
        },
        .playlist, .genre => iconBox(kindIcon(hit.kind), portrait_pixels, "search-top-icon"),
    };
    gtk.gtk_widget_set_halign(picture, gtk.ALIGN_START);
    const name = newLabel(hit.title, "search-top-name");
    var buffer: [512]u8 = undefined;
    var year: [16]u8 = undefined;
    const meta_text = switch (hit.kind) {
        .artist => artistMeta(&buffer, hit, true),
        .release => joined(&buffer, &.{ "Album", hit.artist, yearText(&year, hit.year) }),
        .track => joined(&buffer, &.{ "Track", hit.artist, trackAlbum(hit) }),
        .playlist => playlistDetail(&buffer, hit, firstArtist(results), true),
        .genre => joined(&buffer, &.{ "Genre", counted(&year, hit.track_count, "track", "tracks") }),
    };
    const meta = newLabel(meta_text, "search-top-meta");
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), picture);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), meta);
    if (!register(self, &self.palette.search.picker, .{ .hit = hit }, card, gtk.callback(searchRowClicked))) return;
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), card);
}

fn searchRowClicked(gesture: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    activateSearch(state(data), rowIndex(gesture) orelse return, .open);
}

fn selectSearch(self: *App, wanted: usize) void {
    const search = &self.palette.search;
    selectRow(&search.picker, wanted);
    const rows = search.picker.rows.items;
    if (rows.len == 0) return;
    reveal(search.scroller, gtk.cast(gtk.Widget, search.content orelse return), rows[search.picker.selected]);
}

fn hitPlaying(playing: app.Playing, hit: SearchHit) bool {
    return switch (hit.kind) {
        .track => playing.matches(.track, hit.id),
        .release => playing.matches(.release, hit.id),
        .artist => playing.matches(.artist, hit.id),
        .playlist, .genre => false,
    };
}

pub fn markPlaying(self: *App, _: ?i64) void {
    const search = &self.palette.search;
    if (!search.open) return;
    const playing = self.playing();
    for (search.picker.choices.items, search.picker.rows.items) |choice, row| switch (choice) {
        .hit => |hit| albums.showPlaying(row, hitPlaying(playing, hit)),
        .command, .recent => {},
    };
}

fn activateSearch(self: *App, index: usize, how: Activation) void {
    const search = &self.palette.search;
    if (index >= search.picker.choices.items.len) return;
    switch (search.picker.choices.items[index]) {
        .hit => |hit| {
            remember(self, hit);
            const kind = hit.kind;
            const id = hit.id;
            closeSearch(self, false);
            openEntity(self, kind, id, how);
        },
        .command, .recent => {},
    }
}

fn openEntity(self: *App, kind: SearchKind, id: i64, how: Activation) void {
    switch (kind) {
        .track => if (how == .play_next) menu.playTracksNext(self, &.{id}) else transport.playIds(self, &.{id}, 0),
        .release => switch (how) {
            .open => window.showAlbum(self, id),
            .play => albums.playRelease(self, id),
            .play_next => if (albums.setAlbumContext(self, id)) menu.playNext(self),
        },
        .artist => window.showArtist(self, id),
        .playlist => if (how == .play) playlists.playWhole(self, id, false) else playlists.open(self, id),
        .genre => if (how == .play) genres.playGenreId(self, id) else genres.open(self, id),
    }
}

fn kindName(kind: SearchKind) []const u8 {
    return switch (kind) {
        .artist => "Artist",
        .release => "Album",
        .track => "Track",
        .playlist => "Playlist",
        .genre => "Genre",
    };
}

fn remember(self: *App, hit: SearchHit) void {
    const allocator = self.allocator;
    const recents = &self.palette.recents;
    var buffer: [512]u8 = undefined;
    const detail_text = joined(&buffer, &.{ kindName(hit.kind), if (hit.kind == .release or hit.kind == .track) hit.artist else "" });
    const title = allocator.dupe(u8, hit.title) catch return;
    const detail = allocator.dupe(u8, detail_text) catch {
        allocator.free(title);
        return;
    };
    const fresh: Recent = .{ .kind = hit.kind, .id = hit.id, .title = title, .detail = detail };
    for (recents.items, 0..) |recent, position| {
        if (recent.kind != hit.kind or recent.id != hit.id) continue;
        recent.free(allocator);
        _ = recents.orderedRemove(position);
        break;
    }
    if (recents.items.len == recent_limit) recents.pop().?.free(allocator);
    recents.insert(allocator, 0, fresh) catch fresh.free(allocator);
}
