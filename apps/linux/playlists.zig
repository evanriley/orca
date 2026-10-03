//! Playlists: the overview of every playlist, the page that lists one
//! playlist's songs, and the dialogs that create, rename, describe, delete,
//! import and export them.
//!
//! liborca keeps the playlists, filters, sorts and counts them, resolves their
//! entries and plays them; this asks and shows the answer.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const settings = @import("settings.zig");
const browse_model = @import("browse_model.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const details = @import("details.zig");
const page_ui = @import("page.zig");
const song_table = @import("song_table.zig");
const smart_playlist_editor = @import("smart_playlist_editor.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const insert_batch = 512;
const max_playlists = 4 * app.page_size;
const pinned_preview = 4;
const card_width: c_int = 196;
const card_art_height: c_int = 108;
const wide_width: c_int = 252;
const wide_art_height: c_int = 126;
const card_chrome: f64 = 28;
const sections_gutter: f64 = 40;
const row_art_width: c_int = 64;
const row_art_height: c_int = 32;
const hero_pixels: c_int = 232;
const overview_tag = "playlists";
pub const page_tag = "playlist";

pub const Tab = enum { all, mine, smart };
pub const TypeFilter = enum { all, manual, smart };

const tab_labels = std.enums.EnumArray(Tab, [*:0]const u8).init(.{
    .all = "All Playlists",
    .mine = "Created by Me",
    .smart = "Smart Playlists",
});

const type_labels = [_]?[*:0]const u8{ "All Types", "Playlists", "Smart Playlists", null };

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.PlaylistSort }{
    .{ .label = "Recently Updated", .sort = .recently_updated },
    .{ .label = "Name", .sort = .name },
    .{ .label = "Recently Created", .sort = .created },
    .{ .label = "Most Tracks", .sort = .entries },
};

const cell_keys = [_][*:0]const u8{ "orca-cell-0", "orca-cell-1", "orca-cell-2", "orca-cell-3" };

const Look = enum { loved, recent, rated, repeat, other };

const looks = std.enums.EnumArray(Look, struct { icon: [*:0]const u8, class: [*:0]const u8 }).init(.{
    .loved = .{ .icon = feedback.filled_icon, .class = "smart-tile-loved" },
    .recent = .{ .icon = "document-open-recent-symbolic", .class = "smart-tile-recent" },
    .rated = .{ .icon = "starred-symbolic", .class = "smart-tile-rated" },
    .repeat = .{ .icon = "media-playlist-repeat-symbolic", .class = "smart-tile-repeat" },
    .other = .{ .icon = "view-list-bullet-symbolic", .class = "smart-tile-other" },
});

pub const Card = struct {
    id: i64,
    name: [:0]u8,
    kind: liborca.PlaylistKind,
    creator: liborca.PlaylistCreator,
    pinned: bool,
    loved: bool,
    entries: u32,
    available: u32,
    duration_ms: i64,
    updated_at: i64,
    covers: [5]i64 = undefined,
    cover_count: u8 = 0,
    covers_loaded: bool = false,
    look: Look = .other,
    look_loaded: bool = false,

    fn releaseCovers(self: *const Card) []const i64 {
        return self.covers[0..self.cover_count];
    }
};

pub const Choice = struct {
    id: i64,
    name: [:0]u8,
};

pub const State = struct {
    navigation: ?*adw.NavigationView = null,
    page: ?*adw.NavigationPage = null,
    cards: std.ArrayList(Card) = .empty,
    choices: std.ArrayList(Choice) = .empty,
    pinned_store: ?*gtk.ListStore = null,
    all_store: ?*gtk.ListStore = null,
    tab: Tab = .all,
    type_filter: TypeFilter = .all,
    sort: liborca.PlaylistSort = .recently_updated,
    layout: albums.Layout = .grid,
    query: ?[:0]u8 = null,
    show_all_pinned: bool = false,
    syncing: bool = false,
    tabs: [std.enums.values(Tab).len]?*gtk.ToggleButton = @splat(null),
    layout_toggles: [2]?*gtk.ToggleButton = .{ null, null },
    type_control: ?*gtk.DropDown = null,
    sort_control: ?*gtk.DropDown = null,
    pinned_section: ?*gtk.Widget = null,
    pinned_more: ?*gtk.Button = null,
    all_meta: ?*gtk.Label = null,
    all_controls: ?*gtk.Widget = null,
    overview_body: ?*gtk.Stack = null,
    pinned_grid: ?*gtk.GridView = null,
    listed_grid: ?*gtk.GridView = null,
    pinned_columns: c_uint = 0,
    listed_columns: c_uint = 0,
    open_id: ?i64 = null,
    open_kind: liborca.PlaylistKind = .manual,
    open_pinned: bool = false,
    open_loved: bool = false,
    open_name: ?[:0]u8 = null,
    songs: song_table.Table = .{},
    hero: ?*gtk.Widget = null,
    hero_art: ?*gtk.Stack = null,
    mosaic: ?*gtk.Widget = null,
    smart_tile: ?*gtk.Widget = null,
    eyebrow: ?*gtk.Label = null,
    title: ?*gtk.Label = null,
    meta: ?*gtk.Label = null,
    description: ?*gtk.Label = null,
    body: ?*gtk.Stack = null,
    scroller: ?*gtk.Widget = null,
    play_button: ?*gtk.Widget = null,
    shuffle_button: ?*gtk.Widget = null,
    love_button: ?*gtk.Widget = null,
    rules_button: ?*gtk.Widget = null,
    details: ?*details.Panel = null,
    /// The last import's unmatched lines, for its toast's Details.
    unmatched: std.ArrayList([:0]u8) = .empty,
    unmatched_total: u32 = 0,

    fn clearCards(self: *State, allocator: std.mem.Allocator) void {
        for (self.cards.items) |card| allocator.free(card.name);
        self.cards.clearRetainingCapacity();
        for (self.choices.items) |choice| allocator.free(choice.name);
        self.choices.clearRetainingCapacity();
    }

    fn clearUnmatched(self: *State, allocator: std.mem.Allocator) void {
        for (self.unmatched.items) |line| allocator.free(line);
        self.unmatched.clearRetainingCapacity();
        self.unmatched_total = 0;
    }

    fn setOpenName(self: *State, allocator: std.mem.Allocator, name: ?[]const u8) void {
        if (self.open_name) |old| allocator.free(old);
        self.open_name = if (name) |text| allocator.dupeZ(u8, text) catch null else null;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearCards(allocator);
        self.cards.deinit(allocator);
        self.choices.deinit(allocator);
        if (self.query) |query| allocator.free(query);
        self.query = null;
        self.setOpenName(allocator, null);
        self.clearUnmatched(allocator);
        self.unmatched.deinit(allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn plural(count: u64, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

fn findCard(self: *App, playlist_id: i64) ?*Card {
    for (self.playlists.cards.items) |*card| {
        if (card.id == playlist_id) return card;
    }
    return null;
}

fn nameOf(self: *App, playlist_id: i64, buffer: []u8) [:0]const u8 {
    if (findCard(self, playlist_id)) |card| return card.name;
    for (self.playlists.choices.items) |choice| if (choice.id == playlist_id) return choice.name;
    const library = self.library orelse return "";
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch return "";
    defer summary.deinit(self.runtime.allocator);
    return strings.terminated(buffer, summary.name);
}

/// Playlist names for a menu, which reads `_` as a mnemonic.
pub fn menuLabel(buffer: []u8, name: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (name) |byte| {
        if (byte == '_') writer.writeAll("__") catch break else writer.writeByte(byte) catch break;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

pub fn choices(self: *App) []const Choice {
    return self.playlists.choices.items;
}

pub fn openIsSmart(self: *const App) bool {
    return self.playlists.open_id != null and self.playlists.open_kind == .smart;
}

fn playlistQuery(self: *const App, pinned: bool, limit: u32, offset: u32) liborca.PlaylistQuery {
    const playlists = &self.playlists;
    const kind: ?liborca.PlaylistKind = switch (playlists.tab) {
        .smart => .smart,
        .all, .mine => if (pinned) null else switch (playlists.type_filter) {
            .all => null,
            .manual => .manual,
            .smart => .smart,
        },
    };
    return .{
        .filter = if (playlists.query) |text| text else "",
        .kind = kind,
        .pinned_only = pinned,
        .created_by = if (playlists.tab == .mine) .user else null,
        .sort = if (pinned) .recently_updated else playlists.sort,
        .limit = limit,
        .offset = offset,
    };
}

fn appendCard(self: *App, summary: liborca.PlaylistSummary) !void {
    if (findCard(self, summary.id) != null) return;
    const name = try self.allocator.dupeZ(u8, summary.name);
    errdefer self.allocator.free(name);
    try self.playlists.cards.append(self.allocator, .{
        .id = summary.id,
        .name = name,
        .kind = summary.kind,
        .creator = summary.creator,
        .pinned = summary.pinned,
        .loved = summary.loved,
        .entries = summary.entries,
        .available = summary.available,
        .duration_ms = summary.duration_ms,
        .updated_at = summary.updated_at,
    });
}

fn appendObject(self: *App, objects: *std.ArrayList(?*anyopaque), summary: liborca.PlaylistSummary) void {
    appendCard(self, summary) catch return;
    const object = browse_model.new(summary.id, summary.name, "") orelse return;
    objects.append(self.allocator, object) catch gtk.g_object_unref(object);
}

fn readPlaylists(self: *App, library: liborca.LibraryHandle, request: liborca.PlaylistQuery, wanted: u32, objects: *std.ArrayList(?*anyopaque)) bool {
    var offset: u32 = 0;
    while (offset < wanted) : (offset += app.page_size) {
        var paged = request;
        paged.offset = offset;
        paged.limit = @min(app.page_size, wanted - offset);
        const page = self.runtime.libraryPlaylistPage(library, paged) catch return false;
        defer page.deinit();
        for (page.items) |summary| appendObject(self, objects, summary);
        if (page.items.len < paged.limit) break;
    }
    return true;
}

fn readChoices(self: *App, library: liborca.LibraryHandle) void {
    var offset: u32 = 0;
    while (offset < max_playlists) : (offset += app.page_size) {
        const page = self.runtime.libraryPlaylistPage(library, .{ .kind = .manual, .sort = .name, .limit = app.page_size, .offset = offset }) catch return;
        defer page.deinit();
        for (page.items) |summary| {
            const name = self.allocator.dupeZ(u8, summary.name) catch return;
            self.playlists.choices.append(self.allocator, .{ .id = summary.id, .name = name }) catch {
                self.allocator.free(name);
                return;
            };
        }
        if (page.items.len < app.page_size) break;
    }
}

fn splice(store: ?*gtk.ListStore, objects: []?*anyopaque) void {
    const target = store orelse return;
    const shown = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, target));
    gtk.g_list_store_splice(target, 0, shown, objects.ptr, @intCast(objects.len));
}

fn release(objects: *std.ArrayList(?*anyopaque), allocator: std.mem.Allocator) void {
    for (objects.items) |object| gtk.g_object_unref(object);
    objects.deinit(allocator);
}

pub fn exists(self: *App, playlist_id: i64) bool {
    const library = self.library orelse return false;
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch |err| return err != error.UnknownPlaylist;
    summary.deinit(self.runtime.allocator);
    return true;
}

pub fn refresh(self: *App) void {
    const playlists = &self.playlists;
    playlists.clearCards(self.allocator);
    var pinned: std.ArrayList(?*anyopaque) = .empty;
    defer release(&pinned, self.allocator);
    var listed: std.ArrayList(?*anyopaque) = .empty;
    defer release(&listed, self.allocator);
    var total: u64 = 0;
    var pinned_total: u64 = 0;
    var listed_total: u64 = 0;
    if (self.library) |library| {
        readChoices(self, library);
        total = self.runtime.libraryPlaylistCount(library, .{}) catch 0;
        const pinned_query = playlistQuery(self, true, app.page_size, 0);
        pinned_total = self.runtime.libraryPlaylistCount(library, pinned_query) catch 0;
        const pinned_wanted: u32 = if (playlists.show_all_pinned) max_playlists else pinned_preview;
        const listed_query = playlistQuery(self, false, app.page_size, 0);
        listed_total = self.runtime.libraryPlaylistCount(library, listed_query) catch 0;
        if (!readPlaylists(self, library, pinned_query, pinned_wanted, &pinned) or
            !readPlaylists(self, library, listed_query, max_playlists, &listed))
            self.toast("Could not read your playlists");
    }
    if (playlists.open_id) |id| if (!exists(self, id)) {
        playlists.open_id = null;
        if (playlists.navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, overview_tag);
        reloadPage(self, false);
    };
    splice(playlists.pinned_store, pinned.items);
    splice(playlists.all_store, listed.items);

    if (playlists.pinned_section) |section|
        gtk.gtk_widget_set_visible(section, @intFromBool(pinned_total != 0));
    if (playlists.pinned_more) |button| {
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, button), @intFromBool(pinned_total > pinned_preview));
        gtk.gtk_button_set_label(button, if (playlists.show_all_pinned) "Show fewer" else "Show all");
    }
    if (playlists.all_meta) |meta| {
        var buffer: [48]u8 = undefined;
        gtk.gtk_label_set_text(meta, strings.printZ(&buffer, "{d} {s}", .{ listed_total, plural(listed_total, "playlist", "playlists") }) catch "");
    }
    if (playlists.all_controls) |controls| gtk.gtk_widget_set_visible(controls, @intFromBool(total != 0));
    if (playlists.overview_body) |body| gtk.gtk_stack_set_visible_child_name(
        body,
        if (total == 0) "empty" else if (listed.items.len == 0) "no-results" else @tagName(playlists.layout),
    );
}

fn summaryText(buffer: []u8, card: *const Card) [:0]const u8 {
    var duration_buffer: [32]u8 = undefined;
    const tracks = plural(card.entries, "track", "tracks");
    if (card.entries == 0) return strings.printZ(buffer, "0 {s}", .{tracks}) catch "";
    const duration = strings.totalDuration(&duration_buffer, card.duration_ms);
    const missing = card.entries -| card.available;
    if (missing != 0)
        return strings.printZ(buffer, "{d} {s} • {s} • {d} unavailable", .{ card.entries, tracks, duration, missing }) catch "";
    return strings.printZ(buffer, "{d} {s} • {s}", .{ card.entries, tracks, duration }) catch "";
}

fn formatted(moment: *gtk.GDateTime, pattern: [*:0]const u8) ?[*:0]u8 {
    return gtk.g_date_time_format(moment, pattern);
}

fn sameDay(day: [*:0]const u8, moment: *gtk.GDateTime) bool {
    const other = formatted(moment, "%F") orelse return false;
    defer gtk.g_free(other);
    return std.mem.eql(u8, std.mem.span(day), std.mem.span(other));
}

fn updatedText(buffer: []u8, unix_seconds: i64) [:0]const u8 {
    const updated = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return "";
    defer gtk.g_date_time_unref(updated);
    const now = gtk.g_date_time_new_now_local() orelse return "";
    defer gtk.g_date_time_unref(now);
    const day = formatted(updated, "%F") orelse return "";
    defer gtk.g_free(day);
    if (sameDay(day, now)) return "Updated today";
    const elapsed = gtk.g_date_time_difference(now, updated);
    if (elapsed < 0) return "Updated today";
    if (gtk.g_date_time_add_days(now, -1)) |yesterday| {
        defer gtk.g_date_time_unref(yesterday);
        if (sameDay(day, yesterday)) return "Updated yesterday";
    }
    const days = @max(2, @divTrunc(elapsed, std.time.us_per_day));
    if (days <= 30) return strings.printZ(buffer, "Updated {d} days ago", .{days}) catch "";
    const date = formatted(updated, "%-d %b %Y") orelse return "";
    defer gtk.g_free(date);
    return strings.printZ(buffer, "Updated {s}", .{std.mem.span(date)}) catch "";
}

fn kindText(kind: liborca.PlaylistKind, creator: liborca.PlaylistCreator) [:0]const u8 {
    if (kind == .smart) return "Smart Playlist";
    return if (creator == .imported) "Imported" else "By You";
}

fn loadCovers(self: *App, card: *Card) void {
    if (card.covers_loaded) return;
    card.covers_loaded = true;
    card.cover_count = 0;
    if (card.kind == .smart) return;
    const library = self.library orelse return;
    const page = self.runtime.libraryPlaylistEntries(library, card.id, app.page_size, 0) catch return;
    defer page.deinit();
    for (page.items) |entry| {
        const track = entry.track orelse continue;
        const release_id = track.release_id orelse continue;
        if (std.mem.indexOfScalar(i64, card.releaseCovers(), release_id) != null) continue;
        card.covers[card.cover_count] = release_id;
        card.cover_count += 1;
        if (card.cover_count == card.covers.len) break;
    }
}

fn firstField(value: std.json.Value) ?[]const u8 {
    const object = switch (value) {
        .object => |found| found,
        else => return null,
    };
    if (object.get("op") != null) return switch (object.get("field") orelse return null) {
        .string => |name| name,
        else => null,
    };
    const items = switch (object.get("rules") orelse return null) {
        .array => |array| array.items,
        else => return null,
    };
    for (items) |item| if (firstField(item)) |name| return name;
    return null;
}

fn lookOf(self: *App, playlist_id: i64) Look {
    const library = self.library orelse return .other;
    const rules = (self.runtime.librarySmartPlaylistRules(library, playlist_id) catch return .other) orelse return .other;
    defer self.runtime.allocator.free(rules);
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, rules, .{}) catch return .other;
    defer parsed.deinit();
    const field = firstField(parsed.value) orelse return .other;
    if (std.mem.eql(u8, field, "loved")) return .loved;
    if (std.mem.eql(u8, field, "added_at") or std.mem.eql(u8, field, "last_played_at")) return .recent;
    if (std.mem.eql(u8, field, "rating")) return .rated;
    if (std.mem.eql(u8, field, "play_count")) return .repeat;
    return .other;
}

fn loadLook(self: *App, card: *Card) void {
    if (card.look_loaded or card.kind != .smart) return;
    card.look_loaded = true;
    card.look = lookOf(self, card.id);
}

fn part(widget: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    return gtk.cast(gtk.Widget, gtk.g_object_get_data(widget, key) orelse return null);
}

fn newSmartTile(pixels: c_int) *gtk.Widget {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "smart-tile");
    const icon = gtk.gtk_image_new();
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), pixels);
    gtk.gtk_widget_set_vexpand(icon, gtk.true_);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_halign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), icon);
    gtk.g_object_set_data(tile, "orca-icon", icon);
    return tile;
}

fn showSmartTile(tile: *gtk.Widget, look: Look) void {
    for (looks.values) |other| gtk.gtk_widget_remove_css_class(tile, other.class);
    gtk.gtk_widget_add_css_class(tile, looks.get(look).class);
    if (part(tile, "orca-icon")) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), looks.get(look).icon);
}

fn emptyArt(pixels: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, "playlist-art-empty");
    const icon = gtk.gtk_image_new_from_icon_name("media-playlist-consecutive-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), pixels);
    gtk.gtk_widget_add_css_class(icon, "cover-placeholder");
    gtk.gtk_widget_set_vexpand(icon, gtk.true_);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), icon);
    return box;
}

fn fillingCover(self: *App, pixels: c_int) *gtk.Widget {
    const cover = art.newFillingCover(self, art.iconPlaceholder(pixels));
    gtk.gtk_widget_add_css_class(cover, "playlist-art-cell");
    return cover;
}

fn homogeneous(orientation: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(orientation, 0);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, box), gtk.true_);
    return box;
}

fn newArt(self: *App, width: c_int, height: c_int) *gtk.Widget {
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "playlist-art");
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(frame, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(frame, gtk.ALIGN_START);
    const sizer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(sizer, width, height);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), sizer);

    const stack = gtk.gtk_stack_new();
    const icon_pixels = @divTrunc(height * 2, 5);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), emptyArt(@divTrunc(height, 3)), "none");
    const smart = newSmartTile(icon_pixels);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), smart, "smart");
    const one = fillingCover(self, @divTrunc(height, 2));
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), one, "one");

    const split = homogeneous(gtk.ORIENTATION_HORIZONTAL);
    const left = fillingCover(self, @divTrunc(height, 2));
    gtk.gtk_box_append(gtk.cast(gtk.Box, split), left);
    const right = gtk.gtk_stack_new();
    const pair = fillingCover(self, @divTrunc(height, 2));
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, right), pair, "pair");
    const grid = homogeneous(gtk.ORIENTATION_VERTICAL);
    for (0..2) |row_index| {
        const row = homogeneous(gtk.ORIENTATION_HORIZONTAL);
        for (0..2) |column| {
            const cell = fillingCover(self, @divTrunc(height, 4));
            gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            gtk.g_object_set_data(frame, cell_keys[row_index * 2 + column], cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
    }
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, right), grid, "grid");
    gtk.gtk_box_append(gtk.cast(gtk.Box, split), right);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), split, "split");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), stack);

    gtk.g_object_set_data(frame, "orca-art-stack", stack);
    gtk.g_object_set_data(frame, "orca-art-smart", smart);
    gtk.g_object_set_data(frame, "orca-art-one", one);
    gtk.g_object_set_data(frame, "orca-art-left", left);
    gtk.g_object_set_data(frame, "orca-art-right", right);
    gtk.g_object_set_data(frame, "orca-art-pair", pair);
    return frame;
}

fn forgetArt(self: *App, frame: *gtk.Widget) void {
    for ([_][*:0]const u8{ "orca-art-one", "orca-art-left", "orca-art-pair" }) |key| art.forget(self, part(frame, key) orelse continue);
    for (cell_keys) |key| art.forget(self, part(frame, key) orelse continue);
}

fn showArt(self: *App, frame: *gtk.Widget, card: *const Card) void {
    forgetArt(self, frame);
    const stack = gtk.cast(gtk.Stack, part(frame, "orca-art-stack") orelse return);
    if (card.kind == .smart) {
        if (part(frame, "orca-art-smart")) |tile| showSmartTile(tile, card.look);
        return gtk.gtk_stack_set_visible_child_name(stack, "smart");
    }
    const covers = card.releaseCovers();
    if (covers.len == 0) return gtk.gtk_stack_set_visible_child_name(stack, "none");
    if (covers.len == 1) {
        art.show(self, part(frame, "orca-art-one") orelse return, art.Key.release(covers[0], .tile));
        return gtk.gtk_stack_set_visible_child_name(stack, "one");
    }
    art.show(self, part(frame, "orca-art-left") orelse return, art.Key.release(covers[0], .tile));
    const right = gtk.cast(gtk.Stack, part(frame, "orca-art-right") orelse return);
    if (covers.len >= 1 + cell_keys.len) {
        for (cell_keys, 0..) |key, index| art.show(self, part(frame, key) orelse continue, art.Key.release(covers[index + 1], .thumb));
        gtk.gtk_stack_set_visible_child_name(right, "grid");
    } else {
        art.show(self, part(frame, "orca-art-pair") orelse return, art.Key.release(covers[1], .tile));
        gtk.gtk_stack_set_visible_child_name(right, "pair");
    }
    gtk.gtk_stack_set_visible_child_name(stack, "split");
}

fn mosaicPlaceholder(pixels: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("media-playlist-consecutive-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), @divTrunc(pixels, 3));
    gtk.gtk_widget_add_css_class(icon, "cover-placeholder");
    return icon;
}

fn newMosaic(self: *App, pixels: c_int) *gtk.Widget {
    const stack = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(stack, "playlist-mosaic");
    gtk.gtk_widget_set_overflow(stack, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(stack, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(stack, gtk.ALIGN_START);
    const single = art.newCover(self, mosaicPlaceholder(pixels), pixels);
    gtk.gtk_widget_add_css_class(single, "mosaic-cell");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), single, "single");
    gtk.g_object_set_data(stack, "orca-single", single);
    const half = @divTrunc(pixels, 2);
    const grid = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for (0..2) |row_index| {
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        for (0..2) |column| {
            const cell = art.newCover(self, art.iconPlaceholder(half), half);
            gtk.gtk_widget_add_css_class(cell, "mosaic-cell");
            gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            gtk.g_object_set_data(stack, cell_keys[row_index * 2 + column], cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
    }
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), grid, "grid");
    return stack;
}

fn clearCover(cover: *gtk.Widget) void {
    const stack = gtk.cast(gtk.Stack, cover);
    if (gtk.gtk_stack_get_child_by_name(stack, "art")) |image|
        gtk.gtk_image_set_from_paintable(gtk.cast(gtk.Image, image), null);
    gtk.gtk_stack_set_visible_child_name(stack, "placeholder");
}

fn showMosaic(self: *App, mosaic: *gtk.Widget, covers: []const i64) void {
    const single = part(mosaic, "orca-single") orelse return;
    if (covers.len == 0) {
        art.forget(self, single);
        clearCover(single);
    } else art.show(self, single, art.Key.release(covers[0], .tile));
    const tiled = covers.len >= cell_keys.len;
    for (cell_keys, 0..) |key, index| {
        const cell = part(mosaic, key) orelse continue;
        if (tiled) art.show(self, cell, art.Key.release(covers[index], .tile)) else art.forget(self, cell);
    }
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, mosaic), if (tiled) "grid" else "single");
}

fn label(class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(widget, class);
    return widget;
}

fn cardId(widget: *gtk.Widget) ?i64 {
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    return row.id();
}

fn moreButton(self: *App) *gtk.Widget {
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    for ([_][*:0]const u8{ "flat", "tile-more" }) |class| gtk.gtk_widget_add_css_class(more, class);
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(cardMoreClicked), self);
    return more;
}

fn pinIcon() *gtk.Widget {
    const pin = gtk.gtk_image_new_from_icon_name("view-pin-symbolic");
    gtk.gtk_widget_add_css_class(pin, "playlist-pin");
    gtk.gtk_widget_set_tooltip_text(pin, "Pinned");
    gtk.gtk_widget_set_valign(pin, gtk.ALIGN_CENTER);
    return pin;
}

fn setupCardSized(self: *App, item: ?*anyopaque, width: c_int, art_height: c_int, wide: bool) void {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "playlist-card");
    if (wide) gtk.gtk_widget_add_css_class(tile, "playlist-card-wide");
    gtk.gtk_widget_set_size_request(tile, width, -1);

    const frame = newArt(self, width, art_height);
    gtk.gtk_widget_set_halign(frame, gtk.ALIGN_FILL);
    const play_button = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    for ([_][*:0]const u8{ "tile-play", "tile-action", "circular" }) |class| gtk.gtk_widget_add_css_class(play_button, class);
    gtk.gtk_widget_set_halign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(play_button, "Play Playlist");
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(cardPlayClicked), self);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(layers, "album-cover-frame");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), frame);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), play_button);

    const title = label("playlist-card-title");
    const pin = pinIcon();
    const more = moreButton(self);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(heading, "playlist-card-heading");
    for ([_]*gtk.Widget{ title, pin, more }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, heading), child);
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    gtk.gtk_box_insert_child_after(gtk.cast(gtk.Box, heading), spacer, pin);
    const kind = label("playlist-card-kind");
    const songs = label("playlist-card-meta");
    gtk.gtk_widget_add_css_class(songs, "numeric");
    const updated = label("playlist-card-meta");

    for ([_]*gtk.Widget{ layers, heading, kind, songs, updated }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), child);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    for ([_]*gtk.Widget{ tile, play_button, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-art", frame);
    gtk.g_object_set_data(tile, "orca-title", title);
    gtk.g_object_set_data(tile, "orca-pin", pin);
    gtk.g_object_set_data(tile, "orca-kind", kind);
    gtk.g_object_set_data(tile, "orca-songs", songs);
    gtk.g_object_set_data(tile, "orca-updated", updated);
    menu.onSecondaryClick(tile, cardMenu, self);
}

fn setupCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setupCardSized(state(data), item, card_width, card_art_height, false);
}

fn setupWideCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setupCardSized(state(data), item, wide_width, wide_art_height, true);
}

fn setLabel(widget: *gtk.Widget, key: [*:0]const u8, text: [*:0]const u8) void {
    if (part(widget, key)) |found| gtk.gtk_label_set_text(gtk.cast(gtk.Label, found), text);
}

fn showKind(widget: *gtk.Widget, card: *const Card) void {
    const kind = part(widget, "orca-kind") orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, kind), kindText(card.kind, card.creator).ptr);
    if (card.kind == .smart) gtk.gtk_widget_add_css_class(kind, "accent") else gtk.gtk_widget_remove_css_class(kind, "accent");
}

fn bindCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const card = findCard(self, cardId(tile) orelse return) orelse return;
    var buffer: [128]u8 = undefined;
    setLabel(tile, "orca-title", card.name.ptr);
    if (part(tile, "orca-pin")) |pin| gtk.gtk_widget_set_visible(pin, @intFromBool(card.pinned));
    showKind(tile, card);
    setLabel(tile, "orca-songs", summaryText(&buffer, card).ptr);
    setLabel(tile, "orca-updated", updatedText(&buffer, card.updated_at).ptr);
    loadCovers(self, card);
    loadLook(self, card);
    if (part(tile, "orca-art")) |frame| showArt(self, frame, card);
}

fn unbindCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    forgetArt(state(data), part(tile, "orca-art") orelse return);
}

fn fixedLabel(class: [*:0]const u8, width: c_int, xalign: f32) *gtk.Widget {
    const widget = label(class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), xalign);
    gtk.gtk_widget_set_size_request(widget, width, -1);
    return widget;
}

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "album-list-row");
    gtk.gtk_widget_add_css_class(row, "playlist-list-row");
    const frame = newArt(self, row_art_width, row_art_height);
    gtk.gtk_widget_set_valign(frame, gtk.ALIGN_CENTER);
    const title = label("album-list-title");
    const pin = pinIcon();
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), pin);
    const kind = label("playlist-card-kind");
    const names = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(names, gtk.true_);
    gtk.gtk_widget_set_valign(names, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, names), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, names), kind);
    const songs = fixedLabel("album-list-detail", 72, 1);
    const duration = fixedLabel("album-list-detail", 80, 1);
    for ([_]*gtk.Widget{ songs, duration }) |widget| gtk.gtk_widget_add_css_class(widget, "numeric");
    const updated = fixedLabel("album-list-detail", 120, 0);
    gtk.gtk_widget_add_css_class(updated, "playlist-list-updated");
    const more = moreButton(self);
    gtk.gtk_widget_add_css_class(more, "row-more");
    for ([_]*gtk.Widget{ frame, names, songs, duration, updated, more }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, row), child);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    for ([_]*gtk.Widget{ row, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(row, "orca-art", frame);
    gtk.g_object_set_data(row, "orca-title", title);
    gtk.g_object_set_data(row, "orca-pin", pin);
    gtk.g_object_set_data(row, "orca-kind", kind);
    gtk.g_object_set_data(row, "orca-songs", songs);
    gtk.g_object_set_data(row, "orca-duration", duration);
    gtk.g_object_set_data(row, "orca-updated", updated);
    menu.onSecondaryClick(row, cardMenu, self);
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const card = findCard(self, cardId(row) orelse return) orelse return;
    var buffer: [128]u8 = undefined;
    setLabel(row, "orca-title", card.name.ptr);
    if (part(row, "orca-pin")) |pin| gtk.gtk_widget_set_visible(pin, @intFromBool(card.pinned));
    showKind(row, card);
    setLabel(row, "orca-songs", strings.printZ(&buffer, "{d} {s}", .{ card.entries, plural(card.entries, "track", "tracks") }) catch "");
    var duration_buffer: [32]u8 = undefined;
    setLabel(row, "orca-duration", strings.terminated(&buffer, strings.totalDuration(&duration_buffer, card.duration_ms)).ptr);
    setLabel(row, "orca-updated", updatedText(&buffer, card.updated_at).ptr);
    loadCovers(self, card);
    loadLook(self, card);
    if (part(row, "orca-art")) |frame| showArt(self, frame, card);
}

const Facts = struct {
    kind: liborca.PlaylistKind,
    pinned: bool,
    loved: bool,
};

fn actionMenu(playlist_id: i64, facts: Facts, playback: bool) *gtk.GMenu {
    const Item = struct { label: [*:0]const u8, action: []const u8 };
    const keep: []const Item = &.{
        .{ .label = if (facts.pinned) "Unpin" else "Pin", .action = "playlist-pin" },
        .{ .label = if (facts.loved) "Remove Love" else "Love", .action = "playlist-love" },
    };
    const edit_manual: []const Item = &.{
        .{ .label = "Edit Details…", .action = "playlist-edit" },
        .{ .label = "Rename…", .action = "playlist-rename" },
        .{ .label = "Export…", .action = "playlist-export" },
    };
    const edit_smart: []const Item = &.{
        .{ .label = "Edit Rules…", .action = "playlist-rules" },
        .{ .label = "Edit Details…", .action = "playlist-edit" },
        .{ .label = "Rename…", .action = "playlist-rename" },
        .{ .label = "Export…", .action = "playlist-export" },
    };
    const groups = [_][]const Item{
        &.{ .{ .label = "Play", .action = "playlist-play" }, .{ .label = "Shuffle", .action = "playlist-shuffle" } },
        keep,
        if (facts.kind == .smart) edit_smart else edit_manual,
        &.{.{ .label = "Delete…", .action = "playlist-delete" }},
    };
    const model = gtk.g_menu_new();
    for (groups, 0..) |group, index| {
        if (index == 0 and !playback) continue;
        const section = gtk.g_menu_new();
        for (group) |entry| {
            var buffer: [64]u8 = undefined;
            const detailed = strings.printZ(&buffer, "app.{s}(int64 {d})", .{ entry.action, playlist_id }) catch continue;
            gtk.g_menu_append(section, entry.label, detailed.ptr);
        }
        gtk.g_menu_append_section(model, null, gtk.cast(gtk.GMenuModel, section));
        gtk.g_object_unref(section);
    }
    return model;
}

fn popupActions(widget: *gtk.Widget, playlist_id: i64, facts: Facts, playback: bool, x: f64, y: f64) void {
    const model = actionMenu(playlist_id, facts, playback);
    defer gtk.g_object_unref(model);
    menu.popupModel(widget, gtk.cast(gtk.GMenuModel, model), x, y);
}

fn popupBelow(widget: *gtk.Widget, playlist_id: i64, facts: Facts, playback: bool) void {
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    popupActions(widget, playlist_id, facts, playback, x, y);
}

fn cardFacts(self: *App, playlist_id: i64) ?Facts {
    const card = findCard(self, playlist_id) orelse return null;
    return .{ .kind = card.kind, .pinned = card.pinned, .loved = card.loved };
}

fn cardMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = menu.gestureWidget(gesture);
    const id = cardId(tile) orelse return;
    popupActions(tile, id, cardFacts(self, id) orelse return, true, x, y);
}

fn cardMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const id = cardId(widget) orelse return;
    popupBelow(widget, id, cardFacts(self, id) orelse return, true);
}

fn cardPlayClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playWhole(state(data), cardId(gtk.cast(gtk.Widget, button.?)) orelse return, false);
}

fn pinnedActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    open(self, albums.releaseAt(self.playlists.pinned_store orelse return, position) orelse return);
}

fn listedActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    open(self, albums.releaseAt(self.playlists.all_store orelse return, position) orelse return);
}

fn pageMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const playlists = &self.playlists;
    popupBelow(gtk.cast(gtk.Widget, button.?), playlists.open_id orelse return, .{
        .kind = playlists.open_kind,
        .pinned = playlists.open_pinned,
        .loved = playlists.open_loved,
    }, false);
}

pub fn open(self: *App, playlist_id: i64) void {
    self.playlists.open_id = playlist_id;
    reloadPage(self, false);
    window.showPage(self, .playlists);
    const navigation = self.playlists.navigation orelse return;
    const visible = adw.adw_navigation_view_get_visible_page_tag(navigation);
    if (visible != null and std.mem.eql(u8, std.mem.span(visible.?), page_tag)) return;
    _ = adw.adw_navigation_view_pop_to_tag(navigation, overview_tag);
    adw.adw_navigation_view_push_by_tag(navigation, page_tag);
}

fn heroMeta(buffer: []u8, summary: *const liborca.PlaylistSummary) [:0]const u8 {
    const who: []const u8 = if (summary.kind == .smart)
        "Smart playlist"
    else if (summary.creator == .imported)
        "Imported from a file"
    else
        "Created by you";
    var duration_buffer: [32]u8 = undefined;
    const duration = strings.totalDuration(&duration_buffer, summary.duration_ms);
    const tracks = plural(summary.entries, "track", "tracks");
    const missing = summary.entries -| summary.available;
    if (summary.entries == 0) return strings.printZ(buffer, "{s} • 0 tracks", .{who}) catch "";
    if (missing != 0)
        return strings.printZ(buffer, "{s} • {d} {s} • {s} • {d} unavailable", .{ who, summary.entries, tracks, duration, missing }) catch "";
    return strings.printZ(buffer, "{s} • {d} {s} • {s}", .{ who, summary.entries, tracks, duration }) catch "";
}

fn showHero(self: *App, summary: ?*const liborca.PlaylistSummary, covers: []const i64) void {
    const playlists = &self.playlists;
    var upper_buffer: [512]u8 = undefined;
    const name: [:0]const u8 = if (summary) |found| strings.terminated(&upper_buffer, found.name) else "Playlist";
    playlists.setOpenName(self.allocator, name);
    playlists.open_kind = if (summary) |found| found.kind else .manual;
    playlists.open_pinned = if (summary) |found| found.pinned else false;
    playlists.open_loved = if (summary) |found| found.loved else false;
    const smart = playlists.open_kind == .smart;

    if (playlists.page) |page| adw.adw_navigation_page_set_title(page, name.ptr);
    page_ui.refresh(self);
    if (playlists.title) |title| {
        const upper = gtk.g_utf8_strup(name.ptr, @intCast(name.len));
        defer if (upper) |text| gtk.g_free(text);
        gtk.gtk_label_set_text(title, if (upper) |text| text else name.ptr);
    }
    if (playlists.eyebrow) |eyebrow| gtk.gtk_label_set_text(eyebrow, if (smart) "SMART PLAYLIST" else "PLAYLIST");
    if (playlists.meta) |meta| {
        var buffer: [256]u8 = undefined;
        gtk.gtk_label_set_text(meta, if (summary) |found| heroMeta(&buffer, found).ptr else "");
    }
    if (playlists.description) |description| {
        var buffer: [4100]u8 = undefined;
        const text: []const u8 = if (summary) |found| found.description else "";
        gtk.gtk_label_set_text(description, strings.terminated(&buffer, text).ptr);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, description), @intFromBool(text.len != 0));
    }
    if (playlists.love_button) |heart| showLove(heart, playlists.open_loved);
    if (playlists.rules_button) |button| gtk.gtk_widget_set_visible(button, @intFromBool(smart));
    if (playlists.hero_art) |hero_art| {
        gtk.gtk_stack_set_visible_child_name(hero_art, if (smart) "smart" else "mosaic");
        if (smart) {
            if (playlists.smart_tile) |tile| showSmartTile(tile, lookOf(self, playlists.open_id orelse 0));
        }
    }
    if (playlists.mosaic) |mosaic| showMosaic(self, mosaic, if (smart) &.{} else covers);
}

fn showLove(heart: *gtk.Widget, loved: bool) void {
    feedback.showAlbumButton(heart, loved);
    gtk.gtk_widget_set_tooltip_text(heart, if (loved) "Remove Playlist Love" else "Love Playlist");
}

/// Rereads the open playlist. `keep_scroll` holds the list where it was, for
/// an edit to the rows the user is looking at.
pub fn reloadPage(self: *App, keep_scroll: bool) void {
    const store = self.playlists.songs.store orelse return;
    const adjustment = if (self.playlists.scroller) |scroller|
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller))
    else
        null;
    const scrolled_to = if (adjustment) |value| gtk.gtk_adjustment_get_value(value) else 0;
    gtk.g_list_store_remove_all(store);
    const playlist_id = self.playlists.open_id orelse return;
    const library = self.library orelse return;

    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (additions.items) |row| gtk.g_object_unref(row);
        additions.deinit(self.allocator);
    }
    var covers: [cell_keys.len]i64 = undefined;
    var cover_count: usize = 0;
    var available: u32 = 0;
    var offset: u32 = 0;
    while (offset < liborca.max_playlist_entries) : (offset += app.page_size) {
        const page = self.runtime.libraryPlaylistEntries(library, playlist_id, app.page_size, offset) catch {
            self.toast("Could not read that playlist");
            break;
        };
        defer page.deinit();
        for (page.items) |entry| {
            if (entry.track) |track| if (track.release_id) |release_id| {
                if (cover_count < covers.len and std.mem.indexOfScalar(i64, covers[0..cover_count], release_id) == null) {
                    covers[cover_count] = release_id;
                    cover_count += 1;
                }
            };
            const row = if (entry.track) |track| track_model.new(track) else track_model.unavailable(entry.recording_id);
            additions.append(self.allocator, row orelse continue) catch {
                gtk.g_object_unref(row.?);
                break;
            };
            if (entry.track != null) available += 1;
        }
        if (page.items.len < app.page_size) break;
    }
    if (additions.items.len != 0)
        gtk.g_list_store_splice(store, 0, 0, additions.items.ptr, @intCast(additions.items.len));
    if (adjustment) |value| gtk.gtk_adjustment_set_value(value, if (keep_scroll) scrolled_to else 0);

    const summary: ?liborca.PlaylistSummary = self.runtime.libraryPlaylist(library, playlist_id) catch null;
    defer if (summary) |found| found.deinit(self.runtime.allocator);
    showHero(self, if (summary) |*found| found else null, covers[0..cover_count]);
    if (self.playlists.body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (additions.items.len == 0) "empty" else "list");
    for ([_]?*gtk.Widget{ self.playlists.play_button, self.playlists.shuffle_button }) |maybe| {
        const button = maybe orelse continue;
        gtk.gtk_widget_set_sensitive(button, if (available != 0) gtk.true_ else gtk.false_);
    }
    if (self.playlists.details) |panel| details.showPlaylist(panel, playlist_id);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    song_table.repaint(&self.playlists.songs, changed, change);
}

fn rowAt(self: *App, position: u32) ?*TrackObject {
    const store = self.playlists.songs.store orelse return null;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return null;
    gtk.g_object_unref(item);
    return @ptrCast(@alignCast(item));
}

/// Plays the open playlist from the row at `position`. liborca plays only the
/// entries in the library, so the start counts only those.
pub fn playFrom(self: *App, position: u32) void {
    const playlist_id = self.playlists.open_id orelse return;
    const library = self.library orelse return;
    const row = rowAt(self, position) orelse return;
    if (!row.inLibrary()) return self.toast("That song is not in your library");
    var start: u32 = 0;
    var index: u32 = 0;
    while (index < position) : (index += 1) {
        if ((rowAt(self, index) orelse continue).inLibrary()) start += 1;
    }
    play(self, playlist_id, library, start);
}

fn play(self: *App, playlist_id: i64, library: liborca.LibraryHandle, start: u32) void {
    if (!transport.ensureOutput(self)) return self.toast("No audio output is available");
    self.runtime.playerPlayPlaylist(self.player, library, self.io, playlist_id, start) catch |err| return self.toast(switch (err) {
        error.PlaylistEmpty => "Nothing in this playlist is in your library",
        else => "Could not start playback",
    });
    self.requestTick();
}

pub fn playWhole(self: *App, playlist_id: i64, shuffled: bool) void {
    const library = self.library orelse return;
    self.runtime.playerSetShuffle(self.player, shuffled) catch {};
    play(self, playlist_id, library, 0);
}

fn update(self: *App, playlist_id: i64, change: liborca.PlaylistUpdate) void {
    const library = self.library orelse return;
    self.runtime.libraryUpdatePlaylist(library, playlist_id, change) catch |err| return self.toast(switch (err) {
        error.PlaylistDescriptionTooLong => "That description is too long",
        error.InvalidPlaylistTag => "A tag is empty or longer than 64 bytes",
        error.TooManyPlaylistTags => "A playlist takes at most 8 tags",
        else => "Could not change that playlist",
    });
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

pub fn togglePin(self: *App, playlist_id: i64) void {
    const library = self.library orelse return;
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch return self.toast("Could not change that playlist");
    defer summary.deinit(self.runtime.allocator);
    update(self, playlist_id, .{ .pinned = !summary.pinned });
}

pub fn toggleLove(self: *App, playlist_id: i64) void {
    const library = self.library orelse return;
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch return self.toast("Could not change that playlist");
    defer summary.deinit(self.runtime.allocator);
    update(self, playlist_id, .{ .loved = !summary.loved });
}

pub fn editRules(self: *App, playlist_id: i64) void {
    smart_playlist_editor.present(self, playlist_id);
}

pub fn rulesSaved(self: *App, playlist_id: i64, created: bool) void {
    refresh(self);
    if (created) return open(self, playlist_id);
    if (self.playlists.open_id == playlist_id) reloadPage(self, false);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    playWhole(self, self.playlists.open_id orelse return, false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    playWhole(self, self.playlists.open_id orelse return, true);
}

fn loveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    toggleLove(self, self.playlists.open_id orelse return);
}

fn rulesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    editRules(self, self.playlists.open_id orelse return);
}

fn newClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    askNew(state(data), &.{});
}

fn newSmartClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    smart_playlist_editor.present(state(data), null);
}

fn importClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    chooseImport(state(data));
}

fn showAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.playlists.show_all_pinned = !self.playlists.show_all_pinned;
    refresh(self);
}

pub fn setFilter(self: *App, text: []const u8) void {
    const current: []const u8 = if (self.playlists.query) |query| query else "";
    if (std.mem.eql(u8, text, current)) return;
    if (self.playlists.query) |query| self.allocator.free(query);
    self.playlists.query = null;
    if (text.len != 0) self.playlists.query = self.allocator.dupeZ(u8, text) catch null;
    refresh(self);
}

fn sortChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.playlists.syncing) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= sorts.len) return;
    self.playlists.sort = sorts[selected].sort;
    settings.save(self);
    refresh(self);
}

fn typeChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.playlists.syncing) return;
    const selected = gtk.gtk_drop_down_get_selected(gtk.cast(gtk.DropDown, drop_down));
    if (selected >= std.enums.values(TypeFilter).len) return;
    self.playlists.type_filter = @enumFromInt(selected);
    refresh(self);
}

fn syncControls(self: *App) void {
    const playlists = &self.playlists;
    playlists.syncing = true;
    defer playlists.syncing = false;
    for (playlists.tabs, 0..) |maybe, index| {
        const tab = maybe orelse continue;
        const checked = index == @intFromEnum(playlists.tab);
        if (checked) gtk.gtk_toggle_button_set_active(tab, gtk.true_);
        gtk.gtk_widget_set_focusable(gtk.cast(gtk.Widget, tab), @intFromBool(checked));
    }
    if (playlists.layout_toggles[@intFromEnum(playlists.layout)]) |toggle| gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
    if (playlists.sort_control) |control| {
        for (sorts, 0..) |entry, index| {
            if (entry.sort == playlists.sort) gtk.gtk_drop_down_set_selected(control, @intCast(index));
        }
    }
    if (playlists.type_control) |control| {
        const smart_only = playlists.tab == .smart;
        gtk.gtk_drop_down_set_selected(control, if (smart_only) @intFromEnum(TypeFilter.smart) else @intFromEnum(playlists.type_filter));
        gtk.gtk_widget_set_sensitive(gtk.cast(gtk.Widget, control), @intFromBool(!smart_only));
    }
}

fn chooseTab(self: *App, tab: Tab) void {
    self.playlists.tab = tab;
    syncControls(self);
    settings.save(self);
    refresh(self);
}

fn tabToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.playlists.syncing) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    const tab: Tab = for (self.playlists.tabs, 0..) |candidate, index| {
        if (candidate == toggle) break @enumFromInt(index);
    } else return;
    chooseTab(self, tab);
}

fn tabKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const step: isize = switch (keyval) {
        gtk.KEY_Left => -1,
        gtk.KEY_Right => 1,
        else => return gtk.false_,
    };
    const count: isize = @intCast(self.playlists.tabs.len);
    const next: usize = @intCast(@mod(@as(isize, @intFromEnum(self.playlists.tab)) + step, count));
    chooseTab(self, @enumFromInt(next));
    const tab = self.playlists.tabs[next] orelse return gtk.true_;
    _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, tab));
    return gtk.true_;
}

fn newTabs(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, "playlist-tabs");
    var group: ?*gtk.ToggleButton = null;
    for (std.enums.values(Tab)) |tab| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), tab_labels.get(tab));
        gtk.gtk_widget_add_css_class(button, "playlist-tab");
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        self.playlists.tabs[@intFromEnum(tab)] = toggle;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(tabToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
    }
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(tabKeyPressed), self);
    gtk.gtk_widget_add_controller(row, keys);
    return row;
}

fn layoutToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.playlists.syncing) return;
    const toggle = gtk.cast(gtk.ToggleButton, button.?);
    if (gtk.gtk_toggle_button_get_active(toggle) == gtk.false_) return;
    const layout: albums.Layout = for (self.playlists.layout_toggles, 0..) |candidate, index| {
        if (candidate == toggle) break @enumFromInt(index);
    } else return;
    if (layout == self.playlists.layout) return;
    self.playlists.layout = layout;
    settings.save(self);
    const body = self.playlists.overview_body orelse return;
    const visible = gtk.gtk_stack_get_visible_child_name(body) orelse return;
    if (std.mem.eql(u8, std.mem.span(visible), "grid") or std.mem.eql(u8, std.mem.span(visible), "list"))
        gtk.gtk_stack_set_visible_child_name(body, @tagName(layout));
}

fn newLayoutSwitch(self: *App) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "linked");
    gtk.gtk_widget_add_css_class(box, "view-switch");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    const choices_ = [_]struct { layout: albums.Layout, icon: [*:0]const u8, tooltip: [*:0]const u8 }{
        .{ .layout = .grid, .icon = "view-grid-symbolic", .tooltip = "Grid" },
        .{ .layout = .list, .icon = "view-list-symbolic", .tooltip = "List" },
    };
    var group: ?*gtk.ToggleButton = null;
    for (choices_) |choice| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), choice.icon);
        gtk.gtk_widget_set_tooltip_text(button, choice.tooltip);
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        self.playlists.layout_toggles[@intFromEnum(choice.layout)] = toggle;
        _ = gtk.signalConnect(button, "toggled", gtk.callback(layoutToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    }
    return box;
}

pub fn setNarrow(self: *App) void {
    const hero = self.playlists.hero orelse return;
    gtk.gtk_orientable_set_orientation(
        gtk.cast(gtk.Orientable, hero),
        if (self.window_narrow or self.header_compact) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL,
    );
}

fn creationButtons(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_halign(row, gtk.ALIGN_CENTER);
    const import = gtk.gtk_button_new_with_label("Import…");
    gtk.gtk_widget_add_css_class(import, "pill");
    _ = gtk.signalConnect(import, "clicked", gtk.callback(importClicked), self);
    const smart = albums.pill("New Smart Playlist", "view-list-bullet-symbolic", false);
    _ = gtk.signalConnect(smart, "clicked", gtk.callback(newSmartClicked), self);
    const create = albums.pill("New Playlist", "list-add-symbolic", true);
    _ = gtk.signalConnect(create, "clicked", gtk.callback(newClicked), self);
    for ([_]*gtk.Widget{ import, smart, create }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
    return row;
}

fn statusPage(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) *gtk.Widget {
    const page = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, page), icon);
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, page), title);
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, page), description);
    gtk.gtk_widget_add_css_class(page, "compact");
    return page;
}

fn sectionHeading(heading: [*:0]const u8, caption: [*:0]const u8) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(box, gtk.true_);
    const title = label("playlist-section-title");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), heading);
    const subtitle = label("playlist-section-caption");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, subtitle), caption);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), subtitle);
    return box;
}

fn newCardGrid(self: *App, store: *gtk.ListStore, setup: gtk.GCallback, activated: gtk.GCallback) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", setup, self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindCard), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindCard), self);
    const grid = gtk.gtk_grid_view_new(albums.newSelection(store), factory);
    gtk.gtk_widget_add_css_class(grid, "playlist-grid");
    gtk.gtk_grid_view_set_max_columns(gtk.cast(gtk.GridView, grid), 16);
    gtk.gtk_grid_view_set_min_columns(gtk.cast(gtk.GridView, grid), 1);
    gtk.gtk_grid_view_set_tab_behavior(gtk.cast(gtk.GridView, grid), gtk.LIST_TAB_ITEM);
    gtk.gtk_grid_view_set_single_click_activate(gtk.cast(gtk.GridView, grid), gtk.true_);
    _ = gtk.signalConnect(grid, "activate", activated, self);
    return grid;
}

fn columnsFitting(width: f64, card: c_int) c_uint {
    const fitting = @floor((width - sections_gutter) / (@as(f64, @floatFromInt(card)) + card_chrome));
    if (!(fitting > 1)) return 1;
    return @intFromFloat(@min(fitting, 16));
}

fn applyColumns(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const playlists = &state(data).playlists;
    for ([_]?*gtk.GridView{ playlists.pinned_grid, playlists.listed_grid }, [_]c_uint{ playlists.pinned_columns, playlists.listed_columns }) |grid, columns| {
        gtk.gtk_grid_view_set_min_columns(grid orelse continue, columns);
        gtk.gtk_grid_view_set_max_columns(grid.?, columns);
    }
    return gtk.false_;
}

fn overviewResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    const pinned = columnsFitting(width, wide_width);
    const listed = columnsFitting(width, card_width);
    if (pinned == self.playlists.pinned_columns and listed == self.playlists.listed_columns) return;
    self.playlists.pinned_columns = pinned;
    self.playlists.listed_columns = listed;
    _ = gtk.g_idle_add(applyColumns, self);
}

fn newRowList(self: *App, store: *gtk.ListStore) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindRow), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindCard), self);
    const list = gtk.gtk_list_view_new(albums.newSelection(store), factory);
    gtk.gtk_widget_add_css_class(list, "album-list");
    gtk.gtk_widget_add_css_class(list, "playlist-list");
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, list), gtk.LIST_TAB_ITEM);
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, list), gtk.true_);
    _ = gtk.signalConnect(list, "activate", gtk.callback(listedActivated), self);
    return list;
}

fn buildPinned(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.playlists.pinned_store = store;
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(section, "playlist-section");
    self.playlists.pinned_section = section;
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), sectionHeading("Pinned", "Keep your favorites close."));
    const more = gtk.gtk_button_new_with_label("Show all");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "playlist-show-all");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(showAllClicked), self);
    self.playlists.pinned_more = gtk.cast(gtk.Button, more);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), more);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), heading);
    const grid = newCardGrid(self, store, gtk.callback(setupWideCard), gtk.callback(pinnedActivated));
    self.playlists.pinned_grid = gtk.cast(gtk.GridView, grid);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), grid);
    return section;
}

fn buildListed(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.playlists.all_store = store;
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(section, "playlist-section");
    const heading = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, heading), 12);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, heading), 8);
    adw.adw_wrap_box_set_align(gtk.cast(adw.WrapBox, heading), 1.0);
    const words = sectionHeading("All Playlists", "A mix of your playlists and smart collections.");
    const meta = label("playlist-section-count");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    self.playlists.all_meta = gtk.cast(gtk.Label, meta);
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), meta);
    const controls = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(controls, gtk.ALIGN_END);
    self.playlists.all_controls = controls;
    const types = gtk.gtk_drop_down_new_from_strings(&type_labels);
    gtk.gtk_widget_set_tooltip_text(types, "Show playlists of one type");
    gtk.gtk_widget_add_css_class(types, "sort-dropdown");
    self.playlists.type_control = gtk.cast(gtk.DropDown, types);
    _ = gtk.signalConnect(types, "notify::selected", gtk.callback(typeChanged), self);
    var sort_labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| sort_labels[index] = entry.label;
    sort_labels[sorts.len] = null;
    const sort = gtk.gtk_drop_down_new_from_strings(&sort_labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort playlists");
    gtk.gtk_widget_add_css_class(sort, "sort-dropdown");
    self.playlists.sort_control = gtk.cast(gtk.DropDown, sort);
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    for ([_]*gtk.Widget{ types, sort, newLayoutSwitch(self) }) |control| gtk.gtk_box_append(gtk.cast(gtk.Box, controls), control);
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, heading), words);
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, heading), controls);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);

    const empty = statusPage("media-playlist-consecutive-symbolic", "No playlists yet", "Make one, let rules choose its songs, or import an M3U file.");
    adw.adw_status_page_set_child(gtk.cast(adw.StatusPage, empty), creationButtons(self));
    const no_results = statusPage("edit-find-symbolic", "No playlists found", "Try a different search, tab or type.");
    const body = gtk.gtk_stack_new();
    gtk.gtk_stack_set_vhomogeneous(gtk.cast(gtk.Stack, body), gtk.false_);
    self.playlists.overview_body = gtk.cast(gtk.Stack, body);
    const grid = newCardGrid(self, store, gtk.callback(setupCard), gtk.callback(listedActivated));
    self.playlists.listed_grid = gtk.cast(gtk.GridView, grid);
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, grid, "grid");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, newRowList(self, store), "list");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, empty, "empty");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, no_results, "no-results");
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), body);
    return section;
}

fn buildOverview(self: *App) *gtk.Widget {
    const title = page_ui.title("Playlists");
    gtk.gtk_label_set_text(title.meta, "Your playlists, smart collections, and everything in between.");
    const create = albums.pill("New Playlist", "list-add-symbolic", true);
    _ = gtk.signalConnect(create, "clicked", gtk.callback(newClicked), self);
    title.add(create);
    const smart = gtk.gtk_button_new_with_label("New Smart Playlist");
    _ = gtk.signalConnect(smart, "clicked", gtk.callback(newSmartClicked), self);
    const import = gtk.gtk_button_new_with_label("Import…");
    _ = gtk.signalConnect(import, "clicked", gtk.callback(importClicked), self);
    title.add(smart);
    title.add(import);

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 20);
    gtk.gtk_widget_add_css_class(sections, "playlist-sections");
    gtk.gtk_box_append(gtk.cast(gtk.Box, sections), buildPinned(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, sections), buildListed(self));
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_EXTERNAL, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), sections);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "changed",
        gtk.callback(overviewResized),
        self,
    );

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), newTabs(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), scroller);
    syncControls(self);
    return page_ui.withTitle(title, column);
}

fn buildPlaylistPage(self: *App) *adw.NavigationPage {
    const list = song_table.build(&self.playlists.songs, self, .{ .multiple = false, .sortable = false, .playlist = true });
    const scroller = gtk.gtk_scrolled_window_new();
    self.playlists.scroller = scroller;
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    const empty = statusPage("media-playlist-consecutive-symbolic", "No songs yet", "Right-click a song or an album and choose Add to Playlist.");
    const body = gtk.gtk_stack_new();
    self.playlists.body = gtk.cast(gtk.Stack, body);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    gtk.gtk_widget_add_css_class(body, "playlist-tracks");
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, empty, "empty");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 32);
    gtk.gtk_widget_add_css_class(hero, "album-hero");
    gtk.gtk_widget_add_css_class(hero, "playlist-hero");
    self.playlists.hero = hero;
    const hero_art = gtk.gtk_stack_new();
    gtk.gtk_widget_set_halign(hero_art, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(hero_art, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(hero_art, "hero-cover");
    self.playlists.hero_art = gtk.cast(gtk.Stack, hero_art);
    const mosaic = newMosaic(self, hero_pixels);
    self.playlists.mosaic = mosaic;
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, hero_art), mosaic, "mosaic");
    const smart_tile = newSmartTile(@divTrunc(hero_pixels, 3));
    gtk.gtk_widget_set_size_request(smart_tile, hero_pixels, hero_pixels);
    gtk.gtk_widget_add_css_class(smart_tile, "playlist-mosaic");
    self.playlists.smart_tile = smart_tile;
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, hero_art), smart_tile, "smart");
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), hero_art);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const eyebrow = gtk.gtk_label_new("PLAYLIST");
    self.playlists.eyebrow = gtk.cast(gtk.Label, eyebrow);
    gtk.gtk_widget_add_css_class(eyebrow, "album-kind");
    const title = gtk.gtk_label_new("");
    self.playlists.title = gtk.cast(gtk.Label, title);
    gtk.gtk_widget_add_css_class(title, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
    gtk.gtk_widget_add_css_class(title, "playlist-hero-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, title), gtk.WRAP_WORD_CHAR);
    const meta = gtk.gtk_label_new("");
    self.playlists.meta = gtk.cast(gtk.Label, meta);
    gtk.gtk_widget_add_css_class(meta, "album-meta");
    gtk.gtk_widget_add_css_class(meta, "numeric");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, meta), gtk.true_);
    const description = gtk.gtk_label_new("");
    self.playlists.description = gtk.cast(gtk.Label, description);
    gtk.gtk_widget_add_css_class(description, "playlist-description");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, description), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, description), gtk.WRAP_WORD_CHAR);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, description), 3);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, description), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, description), 72);
    for ([_]*gtk.Widget{ eyebrow, title, meta, description }) |text| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, text), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), text);
    }
    const actions = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, actions), 12);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, actions), 8);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    const play_button = albums.pill("Play", "media-playback-start-symbolic", true);
    const shuffle_button = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    self.playlists.play_button = play_button;
    self.playlists.shuffle_button = shuffle_button;
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(shuffle_button, "clicked", gtk.callback(shuffleClicked), self);
    const heart = feedback.newAlbumButton(gtk.callback(loveClicked), self);
    self.playlists.love_button = heart;
    const rules = albums.pill("Edit Rules", "document-edit-symbolic", false);
    self.playlists.rules_button = rules;
    gtk.gtk_widget_set_visible(rules, gtk.false_);
    _ = gtk.signalConnect(rules, "clicked", gtk.callback(rulesClicked), self);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "Playlist Menu");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(pageMoreClicked), self);
    for ([_]*gtk.Widget{ play_button, shuffle_button, heart, rules, more }) |button| adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    setNarrow(self);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), hero);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), body);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_widget_set_vexpand(layers, gtk.true_);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), albums.newBackdrop(part(mosaic, "orca-single").?));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), column);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), column, gtk.true_);

    const placed = details.besideContent(self, layers, .{ .selection = self.playlists.songs.selection.? });
    self.playlists.details = placed.panel;
    const page = adw.adw_navigation_page_new(placed.widget, "Playlist");
    adw.adw_navigation_page_set_tag(page, page_tag);
    return page;
}

pub fn build(self: *App) *gtk.Widget {
    const navigation = adw.adw_navigation_view_new();
    self.playlists.navigation = gtk.cast(adw.NavigationView, navigation);
    const root = adw.adw_navigation_page_new(buildOverview(self), "Playlists");
    adw.adw_navigation_page_set_tag(root, overview_tag);
    adw.adw_navigation_view_add(self.playlists.navigation.?, root);
    const page = buildPlaylistPage(self);
    self.playlists.page = page;
    adw.adw_navigation_view_add(self.playlists.navigation.?, page);
    refresh(self);
    return navigation;
}

/// Adds the Tracks' recordings to the end of the playlist.
pub fn addTracks(self: *App, playlist_id: i64, track_ids: []const i64) void {
    const library = self.library orelse return;
    if (track_ids.len == 0) return;
    var added: u32 = 0;
    var start: usize = 0;
    while (start < track_ids.len) : (start += insert_batch) {
        const end = @min(start + insert_batch, track_ids.len);
        const insertion = self.runtime.libraryPlaylistInsert(library, playlist_id, track_ids[start..end], null) catch |err| {
            self.toast(switch (err) {
                error.PlaylistFull => "That playlist is full",
                error.PlaylistIsSmart => "A smart playlist's rules choose its songs",
                else => "Could not add to that playlist",
            });
            break;
        };
        added += insertion.added;
    }
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
    if (added == 0) return;
    var buffer: [640]u8 = undefined;
    var name_buffer: [512]u8 = undefined;
    const name = nameOf(self, playlist_id, &name_buffer);
    self.toast(strings.printZ(&buffer, "Added {d} {s} to “{s}”", .{ added, plural(added, "song", "songs"), name }) catch "Added to the playlist");
}

pub fn removeAt(self: *App, playlist_id: i64, position: u32) void {
    const library = self.library orelse return;
    _ = self.runtime.libraryPlaylistRemove(library, playlist_id, &.{position}) catch
        return self.toast("Could not remove that song");
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

pub fn move(self: *App, playlist_id: i64, from: u32, to: u32) void {
    const library = self.library orelse return;
    self.runtime.libraryPlaylistMove(library, playlist_id, from, to) catch
        return self.toast("Could not move that song");
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

const Purpose = enum { create, create_and_add, rename };

const NameRequest = struct {
    self: *App,
    purpose: Purpose,
    entry: *gtk.Widget,
    playlist_id: ?i64,
    track_ids: []i64,
};

fn nameError(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.PlaylistNameTaken => "A playlist with that name already exists",
        error.InvalidPlaylistName => "A playlist needs a name",
        else => "Could not save that playlist",
    };
}

/// Asks for a new playlist's name, then creates it: and adds `track_ids` to it
/// when there are any, or opens it when there are none.
pub fn askNew(self: *App, track_ids: []const i64) void {
    if (self.library == null) return self.toast("No library is open");
    askName(self, if (track_ids.len == 0) .create else .create_and_add, null, "", track_ids);
}

fn askName(self: *App, purpose: Purpose, playlist_id: ?i64, initial: [:0]const u8, track_ids: []const i64) void {
    const owned_ids = self.allocator.dupe(i64, track_ids) catch return self.toast("Out of memory");
    const request = self.allocator.create(NameRequest) catch {
        self.allocator.free(owned_ids);
        return self.toast("Out of memory");
    };
    const entry = gtk.gtk_entry_new();
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), initial.ptr);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), "Name");
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, entry), gtk.true_);
    request.* = .{ .self = self, .purpose = purpose, .entry = entry, .playlist_id = playlist_id, .track_ids = owned_ids };

    const renaming = purpose == .rename;
    const dialog = adw.adw_alert_dialog_new(if (renaming) "Rename Playlist" else "New Playlist", null);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, entry);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "save", if (renaming) "Rename" else "Create");
    adw.adw_alert_dialog_set_response_appearance(alert, "save", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "save");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(nameResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
    _ = gtk.g_idle_add(focusLater, gtk.g_object_ref(entry));
}

// A menu that opened the dialog hands focus back to its parent on idle, after the dialog took it.
fn focusLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const entry = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(entry);
    if (gtk.gtk_widget_get_root(entry) != null) _ = gtk.gtk_widget_grab_focus(entry);
    return gtk.SOURCE_REMOVE;
}

fn nameResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *NameRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer {
        self.allocator.free(request.track_ids);
        self.allocator.destroy(request);
    }
    if (!std.mem.eql(u8, std.mem.span(response), "save")) return;
    const library = self.library orelse return;
    const name = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.entry)));
    switch (request.purpose) {
        .create, .create_and_add => {
            const playlist_id = self.runtime.libraryCreatePlaylist(library, name) catch |err| return self.toast(nameError(err));
            refresh(self);
            if (request.purpose == .create) return open(self, playlist_id);
            addTracks(self, playlist_id, request.track_ids);
        },
        .rename => {
            const playlist_id = request.playlist_id orelse return;
            self.runtime.libraryRenamePlaylist(library, playlist_id, name) catch |err| return self.toast(nameError(err));
            refresh(self);
            if (self.playlists.open_id == playlist_id) reloadPage(self, true);
        },
    }
}

pub fn askRename(self: *App, playlist_id: i64) void {
    var buffer: [512]u8 = undefined;
    askName(self, .rename, playlist_id, nameOf(self, playlist_id, &buffer), &.{});
}

const DetailsRequest = struct {
    self: *App,
    playlist_id: i64,
    description: *gtk.Widget,
    tags: *gtk.Widget,
};

pub fn askDetails(self: *App, playlist_id: i64) void {
    const library = self.library orelse return self.toast("No library is open");
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch return self.toast("Could not read that playlist");
    defer summary.deinit(self.runtime.allocator);
    const request = self.allocator.create(DetailsRequest) catch return self.toast("Out of memory");

    const description = gtk.gtk_entry_new();
    var buffer: [4100]u8 = undefined;
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, description), strings.terminated(&buffer, summary.description).ptr);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, description), "Description");
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, description), gtk.true_);
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (summary.tags, 0..) |tag, index| {
        if (index != 0) writer.writeAll(", ") catch break;
        writer.writeAll(tag) catch break;
    }
    buffer[writer.end] = 0;
    const tags = gtk.gtk_entry_new();
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, tags), buffer[0..writer.end :0].ptr);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, tags), "Tags, separated by commas");
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, tags), gtk.true_);
    const fields = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, fields), description);
    gtk.gtk_box_append(gtk.cast(gtk.Box, fields), tags);
    request.* = .{ .self = self, .playlist_id = playlist_id, .description = description, .tags = tags };

    var heading_buffer: [600]u8 = undefined;
    const heading = strings.printZ(&heading_buffer, "Edit “{s}”", .{summary.name}) catch "Edit Details";
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "At most 8 tags.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, fields);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "save", "Save");
    adw.adw_alert_dialog_set_response_appearance(alert, "save", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "save");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(detailsResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
    _ = gtk.g_idle_add(focusLater, gtk.g_object_ref(description));
}

fn detailsResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *DetailsRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "save")) return;
    const description = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.description)));
    const typed = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.tags)));
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(self.allocator);
    var pieces = std.mem.splitScalar(u8, typed, ',');
    while (pieces.next()) |piece| {
        if (std.mem.trim(u8, piece, " \t").len == 0) continue;
        tags.append(self.allocator, piece) catch return self.toast("Out of memory");
    }
    update(self, request.playlist_id, .{ .description = description, .tags = tags.items });
}

const PlaylistRequest = struct {
    self: *App,
    playlist_id: i64,
};

pub fn confirmDelete(self: *App, playlist_id: i64) void {
    var buffer: [640]u8 = undefined;
    var name_buffer: [512]u8 = undefined;
    const heading = strings.printZ(&buffer, "Delete “{s}”?", .{nameOf(self, playlist_id, &name_buffer)}) catch "Delete this playlist?";
    const request = self.allocator.create(PlaylistRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .playlist_id = playlist_id };
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Its songs stay in your library.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "delete", "Delete");
    adw.adw_alert_dialog_set_response_appearance(alert, "delete", adw.RESPONSE_DESTRUCTIVE);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(deleteResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn deleteResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *PlaylistRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "delete")) return;
    const library = self.library orelse return;
    self.runtime.libraryDeletePlaylist(library, request.playlist_id) catch return self.toast("Could not delete that playlist");
    refresh(self);
}

pub fn chooseExport(self: *App, playlist_id: i64) void {
    const request = self.allocator.create(PlaylistRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .playlist_id = playlist_id };
    var source_buffer: [512]u8 = undefined;
    const source = nameOf(self, playlist_id, &source_buffer);
    var name_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&name_buffer);
    for (if (source.len != 0) source else "Playlist") |byte| writer.writeByte(if (byte == '/') '-' else byte) catch break;
    var buffer: [600]u8 = undefined;
    const initial = strings.printZ(&buffer, "{s}.m3u8", .{name_buffer[0..writer.end]}) catch "Playlist.m3u8";
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Export Playlist");
    gtk.gtk_file_dialog_set_initial_name(dialog, initial.ptr);
    gtk.gtk_file_dialog_save(dialog, self.window, null, exportChosen, request);
    gtk.g_object_unref(dialog);
}

fn exportChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const request: *PlaylistRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_save_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    const library = self.library orelse return;
    const exported = self.runtime.libraryExportPlaylist(library, self.io, request.playlist_id, std.mem.span(path_pointer), .{
        .paths = .absolute,
        .replace = true,
    }) catch return self.toast("Could not export that playlist");
    var buffer: [128]u8 = undefined;
    self.toast(if (exported.skipped != 0)
        strings.printZ(&buffer, "Exported {d} {s}, {d} not in your library", .{ exported.written, plural(exported.written, "song", "songs"), exported.skipped }) catch "Exported"
    else
        strings.printZ(&buffer, "Exported {d} {s}", .{ exported.written, plural(exported.written, "song", "songs") }) catch "Exported");
}

pub fn chooseImport(self: *App) void {
    if (self.library == null) return self.toast("No library is open");
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Import Playlist");
    const filter = gtk.gtk_file_filter_new();
    gtk.gtk_file_filter_set_name(filter, "Playlists (M3U)");
    gtk.gtk_file_filter_add_suffix(filter, "m3u");
    gtk.gtk_file_filter_add_suffix(filter, "m3u8");
    if (gtk.g_list_store_new(gtk.gtk_file_filter_get_type())) |filters| {
        gtk.g_list_store_append(filters, filter);
        gtk.gtk_file_dialog_set_filters(dialog, gtk.cast(gtk.ListModel, filters));
        gtk.g_object_unref(filters);
    }
    gtk.gtk_file_dialog_set_default_filter(dialog, filter);
    gtk.g_object_unref(filter);
    gtk.gtk_file_dialog_open(dialog, self.window, null, importChosen, self);
    gtk.g_object_unref(dialog);
}

fn importChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_open_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    importFile(self, std.mem.span(path_pointer));
}

fn importFile(self: *App, path: []const u8) void {
    const library = self.library orelse return;
    const imported = self.runtime.libraryImportPlaylist(library, self.io, path, null) catch |err| return self.toast(switch (err) {
        error.PlaylistEmpty => "That playlist has no entries",
        error.PlaylistTooLarge => "That playlist is too large to import",
        else => "Could not import that playlist",
    });
    defer imported.deinit();
    self.playlists.clearUnmatched(self.allocator);
    for (imported.unmatched_lines) |line| {
        const copy = self.allocator.dupeZ(u8, line) catch break;
        self.playlists.unmatched.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            break;
        };
    }
    self.playlists.unmatched_total = imported.unmatched;
    refresh(self);
    open(self, imported.playlist_id);

    const matched = imported.matched_by_path + imported.matched_by_info;
    var buffer: [128]u8 = undefined;
    const text = if (imported.unmatched != 0)
        strings.printZ(&buffer, "Imported {d} {s}, {d} not found", .{ matched, plural(matched, "song", "songs"), imported.unmatched }) catch "Imported"
    else
        strings.printZ(&buffer, "Imported {d} {s}", .{ matched, plural(matched, "song", "songs") }) catch "Imported";
    const overlay = self.toasts orelse return;
    const toast = adw.adw_toast_new(text.ptr);
    if (imported.unmatched != 0) {
        adw.adw_toast_set_timeout(toast, 8);
        adw.adw_toast_set_button_label(toast, "Details");
        _ = gtk.signalConnect(toast, "button-clicked", gtk.callback(detailsClicked), self);
    } else adw.adw_toast_set_timeout(toast, 3);
    adw.adw_toast_overlay_add_toast(overlay, toast);
}

fn detailsClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showUnmatched(state(data));
}

fn showUnmatched(self: *App) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.allocator);
    const lines = self.playlists.unmatched.items;
    for (lines, 0..) |line, index| {
        if (index != 0) text.append(self.allocator, '\n') catch return;
        text.appendSlice(self.allocator, line) catch return;
    }
    const hidden = self.playlists.unmatched_total -| @as(u32, @intCast(lines.len));
    if (hidden != 0) text.print(self.allocator, "\n…and {d} more", .{hidden}) catch return;
    text.append(self.allocator, 0) catch return;

    const text_label = gtk.gtk_label_new(@ptrCast(text.items.ptr));
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, text_label), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, text_label), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, text_label), gtk.WRAP_WORD_CHAR);
    gtk.gtk_widget_add_css_class(text_label, "monospace");
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 320);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), text_label);

    const dialog = adw.adw_alert_dialog_new("Not Found", "No song in your library matches these entries.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, scroller);
    adw.adw_alert_dialog_add_response(alert, "close", "Close");
    adw.adw_alert_dialog_set_close_response(alert, "close");
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
