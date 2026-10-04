//! Playlists: the overview of every playlist, the page that lists one
//! playlist's tracks, and the dialogs that create, rename, describe, delete,
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
const track_table = @import("track_table.zig");
const smart_playlist_editor = @import("smart_playlist_editor.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;
const TrackObject = track_model.TrackObject;

const insert_batch = 512;
const max_playlists = 4 * app.page_size;
const pinned_tile = Tiling{ .min = 196, .gap = 24 };
const listed_tile = Tiling{ .min = 150, .gap = 20 };
const tile_icon_pixels: c_int = 34;
const row_art_pixels: c_int = 48;
const row_icon_pixels: c_int = 20;
const hero_pixels: c_int = 232;
const handle_width: c_int = 26;
const album_width: c_int = 324;
const meta_separator = "  <span fgalpha=\"43%\">·</span>  ";
const overview_tag = "playlists";
pub const page_tag = "playlist";

pub const Tab = enum { all, mine, smart };

const tab_labels = std.enums.EnumArray(Tab, [*:0]const u8).init(.{
    .all = "All",
    .mine = "Created by Me",
    .smart = "Smart",
});

const sorts = [_]struct { label: [*:0]const u8, sort: liborca.PlaylistSort }{
    .{ .label = "Recently updated", .sort = .recently_updated },
    .{ .label = "Name", .sort = .name },
    .{ .label = "Recently created", .sort = .created },
    .{ .label = "Most tracks", .sort = .entries },
};

const cell_keys = [_][*:0]const u8{ "orca-cell-0", "orca-cell-1", "orca-cell-2", "orca-cell-3" };

const smart_icon = "orca-sparkle-symbolic";

const Look = enum { loved, quality, other };

const looks = std.enums.EnumArray(Look, [*:0]const u8).init(.{
    .loved = "orca-loved-symbolic",
    .quality = "orca-signal-symbolic",
    .other = smart_icon,
});

const Tiling = struct {
    min: f64,
    gap: f64,

    fn columns(self: Tiling, width: f64) c_uint {
        const fitting = @floor((width + self.gap) / (self.min + self.gap));
        if (!(fitting > 1)) return 1;
        return @intFromFloat(@min(fitting, 16));
    }

    fn pixels(self: Tiling, width: f64, columns_: c_uint) c_int {
        const cell = (width + self.gap) / @as(f64, @floatFromInt(columns_));
        return @intFromFloat(@max(@floor(cell - self.gap), 64));
    }
};

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
    covers: [cell_keys.len]i64 = undefined,
    cover_count: u8 = 0,
    covers_loaded: bool = false,
    look: Look = .other,
    rules: [160]u8 = undefined,
    rules_len: usize = 0,
    rules_loaded: bool = false,

    fn releaseCovers(self: *const Card) []const i64 {
        return self.covers[0..self.cover_count];
    }

    fn rulesText(self: *const Card) [:0]const u8 {
        return self.rules[0..self.rules_len :0];
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
    sort: liborca.PlaylistSort = .recently_updated,
    layout: albums.Layout = .grid,
    query: ?[:0]u8 = null,
    syncing: bool = false,
    tabs: [std.enums.values(Tab).len]?*gtk.ToggleButton = @splat(null),
    layout_toggles: [2]?*gtk.ToggleButton = .{ null, null },
    sort_control: ?*gtk.DropDown = null,
    pinned_section: ?*gtk.Widget = null,
    all_controls: ?*gtk.Widget = null,
    overview_body: ?*gtk.Stack = null,
    pinned_grid: ?*gtk.GridView = null,
    listed_grid: ?*gtk.GridView = null,
    pinned_columns: c_uint = 0,
    listed_columns: c_uint = 0,
    pinned_pixels: c_int = @intFromFloat(pinned_tile.min),
    listed_pixels: c_int = @intFromFloat(listed_tile.min),
    columns_idle: c_uint = 0,
    open_id: ?i64 = null,
    open_kind: liborca.PlaylistKind = .manual,
    open_pinned: bool = false,
    open_loved: bool = false,
    open_name: ?[:0]u8 = null,
    tracks: track_table.Table = .{},
    hero: ?*gtk.Widget = null,
    hero_art: ?*gtk.Stack = null,
    mosaic: ?*gtk.Widget = null,
    backdrop: ?*gtk.Widget = null,
    smart_tile: ?*gtk.Widget = null,
    eyebrow: ?*gtk.Label = null,
    title: ?*gtk.Label = null,
    meta: ?*gtk.Label = null,
    description: ?*gtk.Label = null,
    body: ?*gtk.Stack = null,
    scroller: ?*gtk.Widget = null,
    play_button: ?*gtk.Widget = null,
    shuffle_button: ?*gtk.Widget = null,
    edit_button: ?*gtk.Widget = null,
    reorder_button: ?*gtk.ToggleButton = null,
    handle_column: ?*gtk.ColumnViewColumn = null,
    dragging: bool = false,
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
    return .{
        .filter = if (playlists.query) |text| text else "",
        .kind = if (playlists.tab == .smart) .smart else null,
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
    if (self.library) |library| {
        readChoices(self, library);
        total = self.runtime.libraryPlaylistCount(library, .{}) catch 0;
        const pinned_query = playlistQuery(self, true, app.page_size, 0);
        const listed_query = playlistQuery(self, false, app.page_size, 0);
        if (!readPlaylists(self, library, pinned_query, max_playlists, &pinned) or
            !readPlaylists(self, library, listed_query, max_playlists, &listed))
            self.toast("Could not read your playlists");
    }
    if (playlists.open_id) |id| if (!exists(self, id)) {
        playlists.open_id = null;
        if (playlists.navigation) |navigation| window.popToTag(self, navigation, overview_tag);
        reloadPage(self, false);
    };
    splice(playlists.pinned_store, pinned.items);
    splice(playlists.all_store, listed.items);

    if (playlists.pinned_section) |section|
        gtk.gtk_widget_set_visible(section, @intFromBool(pinned.items.len != 0));
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
        return strings.printZ(buffer, "{d} {s} · {s} · {d} unavailable", .{ card.entries, tracks, duration, missing }) catch "";
    return strings.printZ(buffer, "{d} {s} · {s}", .{ card.entries, tracks, duration }) catch "";
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
    const days: u64 = @intCast(@max(2, @divTrunc(elapsed, std.time.us_per_day)));
    if (days < 7) return strings.printZ(buffer, "Updated {d} days ago", .{days}) catch "";
    if (days < 14) return "Updated last week";
    if (days < 30) return strings.printZ(buffer, "Updated {d} weeks ago", .{days / 7}) catch "";
    if (days < 60) return "Updated last month";
    if (days < 365) return strings.printZ(buffer, "Updated {d} months ago", .{days / 30}) catch "";
    const date = formatted(updated, "%-d %b %Y") orelse return "";
    defer gtk.g_free(date);
    return strings.printZ(buffer, "Updated {s}", .{std.mem.span(date)}) catch "";
}

fn kindText(kind: liborca.PlaylistKind, creator: liborca.PlaylistCreator) [:0]const u8 {
    if (kind == .smart) return "Smart playlist";
    return if (creator == .imported) "Imported" else "By you";
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

fn objectOf(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |found| found,
        else => null,
    };
}

fn arrayOf(value: ?std.json.Value) ?[]const std.json.Value {
    return switch (value orelse return null) {
        .array => |found| found.items,
        else => null,
    };
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |found| found,
        else => null,
    };
}

fn integerOf(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |found| found,
        else => null,
    };
}

fn matchesAny(group: std.json.ObjectMap) bool {
    const match = stringOf(group.get("match")) orelse return false;
    return std.mem.eql(u8, match, "any");
}

fn firstField(value: std.json.Value) ?[]const u8 {
    const object = objectOf(value) orelse return null;
    if (object.get("op") != null) return stringOf(object.get("field"));
    for (arrayOf(object.get("rules")) orelse return null) |item| if (firstField(item)) |name| return name;
    return null;
}

fn parseRules(self: *App, playlist_id: i64) ?std.json.Parsed(std.json.Value) {
    const library = self.library orelse return null;
    const rules = (self.runtime.librarySmartPlaylistRules(library, playlist_id) catch return null) orelse return null;
    defer self.runtime.allocator.free(rules);
    return std.json.parseFromSlice(std.json.Value, self.allocator, rules, .{ .allocate = .alloc_always }) catch null;
}

fn lookFrom(rules: std.json.Value) Look {
    const field = firstField(rules) orelse return .other;
    if (std.mem.eql(u8, field, "loved")) return .loved;
    for ([_][]const u8{ "sample_rate", "bit_depth", "lossless", "codec" }) |quality| {
        if (std.mem.eql(u8, field, quality)) return .quality;
    }
    return .other;
}

fn lookOf(self: *App, playlist_id: i64) Look {
    const parsed = parseRules(self, playlist_id) orelse return .other;
    defer parsed.deinit();
    return lookFrom(parsed.value);
}

fn loadRules(self: *App, card: *Card) void {
    if (card.rules_loaded or card.kind != .smart) return;
    card.rules_loaded = true;
    card.rules_len = 0;
    card.rules[0] = 0;
    const parsed = parseRules(self, card.id) orelse return;
    defer parsed.deinit();
    card.look = lookFrom(parsed.value);
    card.rules_len = ruleSummary(self, &card.rules, parsed.value).len;
}

const RuleError = error{Unphrased} || std.Io.Writer.Error;

const Flag = struct { yes: []const u8, no: []const u8 };

const flag_fields = std.StaticStringMap(Flag).initComptime(.{
    .{ "loved", Flag{ .yes = "loved", .no = "not loved" } },
    .{ "lossless", Flag{ .yes = "lossless", .no = "lossy" } },
    .{ "explicit", Flag{ .yes = "explicit", .no = "not explicit" } },
    .{ "has_artwork", Flag{ .yes = "has artwork", .no = "no artwork" } },
});

const text_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "title", "title" },
    .{ "artist", "artist" },
    .{ "album", "album" },
    .{ "album_artist", "album artist" },
    .{ "genre", "genre" },
    .{ "codec", "codec" },
    .{ "release_type", "release type" },
});

const Unit = enum { year, rating, duration, sample_rate, bit_depth };

const number_fields = std.StaticStringMap(Unit).initComptime(.{
    .{ "year", .year },
    .{ "rating", .rating },
    .{ "duration_ms", .duration },
    .{ "sample_rate", .sample_rate },
    .{ "bit_depth", .bit_depth },
});

const unit_names = std.enums.EnumArray(Unit, []const u8).init(.{
    .year = "year",
    .rating = "rating",
    .duration = "length",
    .sample_rate = "sample rate",
    .bit_depth = "bit depth",
});

const comparisons = std.StaticStringMap([]const u8).initComptime(.{
    .{ "is", "is" },
    .{ "is_not", "is not" },
    .{ "gt", "above" },
    .{ "gte", "at least" },
    .{ "lt", "below" },
    .{ "lte", "at most" },
});

const year_comparisons = std.StaticStringMap([2][]const u8).initComptime(.{
    .{ "is", [2][]const u8{ "released in ", "" } },
    .{ "is_not", [2][]const u8{ "not released in ", "" } },
    .{ "gt", [2][]const u8{ "released after ", "" } },
    .{ "gte", [2][]const u8{ "released in ", " or later" } },
    .{ "lt", [2][]const u8{ "released before ", "" } },
    .{ "lte", [2][]const u8{ "released in ", " or earlier" } },
});

const date_comparisons = std.StaticStringMap([]const u8).initComptime(.{
    .{ "gt", "after" },
    .{ "gte", "since" },
    .{ "lt", "before" },
    .{ "lte", "on or before" },
});

fn ruleSummary(self: *App, buffer: []u8, rules: std.json.Value) [:0]const u8 {
    const group = objectOf(rules) orelse return strings.terminated(buffer, "");
    const nodes = arrayOf(group.get("rules")) orelse return strings.terminated(buffer, "");
    if (nodes.len == 0) return strings.terminated(buffer, "Every track");
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeRules(self, &writer, nodes, matchesAny(group)) catch |err| switch (err) {
        error.Unphrased => return strings.format(buffer, "{d} {s}", .{ nodes.len, plural(nodes.len, "rule", "rules") }),
        error.WriteFailed => {},
    };
    var length = writer.end;
    while (length > 0 and !std.unicode.utf8ValidateSlice(buffer[0..length])) length -= 1;
    buffer[length] = 0;
    if (length != 0) buffer[0] = std.ascii.toUpper(buffer[0]);
    return buffer[0..length :0];
}

fn writeRules(self: *App, writer: *std.Io.Writer, nodes: []const std.json.Value, any: bool) RuleError!void {
    const shown = @min(nodes.len, 2);
    for (nodes[0..shown], 0..) |node, index| {
        if (index != 0) try writer.writeAll(if (any) " or " else ", ");
        try writeRule(self, writer, node);
    }
    if (nodes.len > shown) try writer.print(" + {d} more", .{nodes.len - shown});
}

fn writeRule(self: *App, writer: *std.Io.Writer, node: std.json.Value) RuleError!void {
    const rule = objectOf(node) orelse return error.Unphrased;
    if (arrayOf(rule.get("rules"))) |nested| {
        if (nested.len == 1) return writeRule(self, writer, nested[0]);
        return writer.print("{s} of {d} rules", .{ if (matchesAny(rule)) "any" else "all", nested.len });
    }
    const field = stringOf(rule.get("field")) orelse return error.Unphrased;
    const op = stringOf(rule.get("op")) orelse return error.Unphrased;
    const value = rule.get("value");
    if (flag_fields.get(field)) |flag| {
        const wanted = switch (value orelse return error.Unphrased) {
            .bool => |found| found,
            else => return error.Unphrased,
        };
        const positive = if (std.mem.eql(u8, op, "is")) wanted else if (std.mem.eql(u8, op, "is_not")) !wanted else return error.Unphrased;
        return writer.writeAll(if (positive) flag.yes else flag.no);
    }
    if (std.mem.eql(u8, field, "play_count")) return writePlays(writer, op, value);
    if (std.mem.eql(u8, field, "added_at")) return writeDate(writer, .added, op, value);
    if (std.mem.eql(u8, field, "last_played_at")) return writeDate(writer, .played, op, value);
    if (std.mem.eql(u8, field, "in_playlist")) {
        const negated = if (std.mem.eql(u8, op, "is_not")) true else if (std.mem.eql(u8, op, "is")) false else return error.Unphrased;
        var name_buffer: [512]u8 = undefined;
        const name = nameOf(self, integerOf(value) orelse return error.Unphrased, &name_buffer);
        return writer.print("{s}in {s}", .{ if (negated) "not " else "", if (name.len == 0) "a playlist" else name });
    }
    if (text_fields.get(field)) |name| {
        if (std.mem.eql(u8, op, "is_set")) return writer.print("has {s} {s}", .{ article(name), name });
        if (std.mem.eql(u8, op, "is_not_set")) return writer.print("no {s}", .{name});
        const text = stringOf(value) orelse return error.Unphrased;
        const verb = if (std.mem.eql(u8, op, "contains"))
            "contains"
        else if (std.mem.eql(u8, op, "starts_with"))
            "starts with"
        else
            comparisons.get(op) orelse return error.Unphrased;
        if (!std.mem.eql(u8, op, "is") and !std.mem.eql(u8, op, "is_not") and comparisons.get(op) != null) return error.Unphrased;
        return writer.print("{s} {s} {s}", .{ name, verb, text });
    }
    if (number_fields.get(field)) |unit| return writeNumber(writer, unit, op, value);
    return error.Unphrased;
}

fn article(noun: []const u8) []const u8 {
    return if (noun.len != 0 and std.mem.indexOfScalar(u8, "aeiou", noun[0]) != null) "an" else "a";
}

fn bounds(value: ?std.json.Value) ?[2]i64 {
    const pair = arrayOf(value) orelse return null;
    if (pair.len != 2) return null;
    return .{ integerOf(pair[0]) orelse return null, integerOf(pair[1]) orelse return null };
}

fn writePlays(writer: *std.Io.Writer, op: []const u8, value: ?std.json.Value) RuleError!void {
    if (std.mem.eql(u8, op, "is_set")) return writer.writeAll("played before");
    if (std.mem.eql(u8, op, "is_not_set")) return writer.writeAll("never played");
    if (std.mem.eql(u8, op, "between")) {
        const range = bounds(value) orelse return error.Unphrased;
        return writer.print("played {d}–{d} times", .{ range[0], range[1] });
    }
    const count = integerOf(value) orelse return error.Unphrased;
    const times = plural(@intCast(@max(count, 0)), "time", "times");
    if (std.mem.eql(u8, op, "is")) {
        if (count == 0) return writer.writeAll("never played");
        if (count == 1) return writer.writeAll("played once");
        return writer.print("played {d} times", .{count});
    }
    if (std.mem.eql(u8, op, "is_not")) {
        if (count == 0) return writer.writeAll("played before");
        return writer.print("not played {d} {s}", .{ count, times });
    }
    if (std.mem.eql(u8, op, "gt")) {
        if (count <= 0) return writer.writeAll("played before");
        return writer.print("played more than {d} {s}", .{ count, times });
    }
    if (std.mem.eql(u8, op, "gte")) {
        if (count <= 1) return writer.writeAll("played before");
        return writer.print("played at least {d} {s}", .{ count, times });
    }
    if (std.mem.eql(u8, op, "lt")) {
        if (count <= 1) return writer.writeAll("never played");
        return writer.print("played fewer than {d} {s}", .{ count, times });
    }
    if (std.mem.eql(u8, op, "lte")) {
        if (count <= 0) return writer.writeAll("never played");
        return writer.print("played at most {d} {s}", .{ count, times });
    }
    return error.Unphrased;
}

const DateField = enum { added, played };

fn writePeriod(writer: *std.Io.Writer, days: i64, with_article: bool) RuleError!void {
    if (days <= 0) return error.Unphrased;
    const lengths = [_]struct { days: i64, one: []const u8, many: []const u8 }{
        .{ .days = 365, .one = "year", .many = "years" },
        .{ .days = 7, .one = "week", .many = "weeks" },
        .{ .days = 1, .one = "day", .many = "days" },
    };
    for (lengths) |length| {
        if (@mod(days, length.days) != 0 or (length.days == 7 and days > 7 * 8)) continue;
        const count = @divExact(days, length.days);
        if (count == 1) return writer.print("{s}{s}", .{ if (with_article) "a " else "", length.one });
        return writer.print("{d} {s}", .{ count, length.many });
    }
    unreachable;
}

fn writeDay(writer: *std.Io.Writer, unix_seconds: i64) RuleError!void {
    const moment = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return error.Unphrased;
    defer gtk.g_date_time_unref(moment);
    const date = formatted(moment, "%-d %b %Y") orelse return error.Unphrased;
    defer gtk.g_free(date);
    try writer.writeAll(std.mem.span(date));
}

fn writeDate(writer: *std.Io.Writer, field: DateField, op: []const u8, value: ?std.json.Value) RuleError!void {
    const played = field == .played;
    if (std.mem.eql(u8, op, "is_set")) return writer.writeAll(if (played) "played before" else "has an added date");
    if (std.mem.eql(u8, op, "is_not_set")) return writer.writeAll(if (played) "never played" else "no added date");
    const verb = if (played) "last played" else "added";
    if (std.mem.eql(u8, op, "between")) {
        const range = bounds(value) orelse return error.Unphrased;
        try writer.print("{s} between ", .{verb});
        try writeDay(writer, range[0]);
        try writer.writeAll(" and ");
        return writeDay(writer, range[1]);
    }
    const amount = integerOf(value) orelse return error.Unphrased;
    if (std.mem.eql(u8, op, "in_last_days")) {
        try writer.print("{s} in the last ", .{if (played) "played" else "added"});
        return writePeriod(writer, amount, false);
    }
    if (std.mem.eql(u8, op, "not_in_last_days")) {
        try writer.print("{s} over ", .{verb});
        try writePeriod(writer, amount, true);
        return writer.writeAll(" ago");
    }
    const relation = date_comparisons.get(op) orelse return error.Unphrased;
    try writer.print("{s} {s} ", .{ verb, relation });
    return writeDay(writer, amount);
}

fn writeAmount(writer: *std.Io.Writer, unit: Unit, amount: i64) RuleError!void {
    const magnitude: u64 = @intCast(@max(amount, 0));
    switch (unit) {
        .year => try writer.print("{d}", .{amount}),
        .rating => if (magnitude % 20 == 0)
            try writer.print("{d}", .{magnitude / 20})
        else
            try writer.print("{d}/100", .{magnitude}),
        .duration => {
            const seconds = magnitude / 1000;
            if (seconds % 60 == 0) return writer.print("{d} min", .{seconds / 60});
            try writer.print("{d}:{d:0>2}", .{ seconds / 60, seconds % 60 });
        },
        .sample_rate => {
            try writer.print("{d}", .{magnitude / 1000});
            var fraction: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&fraction, "{d:0>3}", .{magnitude % 1000}) catch unreachable;
            const digits = std.mem.trimEnd(u8, &fraction, "0");
            if (digits.len != 0) try writer.print(".{s}", .{digits});
            try writer.writeAll(" kHz");
        },
        .bit_depth => try writer.print("{d}-bit", .{magnitude}),
    }
}

fn writeNumber(writer: *std.Io.Writer, unit: Unit, op: []const u8, value: ?std.json.Value) RuleError!void {
    const name = unit_names.get(unit);
    if (std.mem.eql(u8, op, "is_set")) return writer.print("has {s} {s}", .{ article(name), name });
    if (std.mem.eql(u8, op, "is_not_set")) return writer.print("no {s}", .{name});
    if (std.mem.eql(u8, op, "between")) {
        const range = bounds(value) orelse return error.Unphrased;
        try writer.writeAll(if (unit == .year) "released " else name);
        if (unit != .year) try writer.writeAll(" between ");
        try writeAmount(writer, unit, range[0]);
        try writer.writeAll(if (unit == .year) "–" else " and ");
        return writeAmount(writer, unit, range[1]);
    }
    const amount = integerOf(value) orelse return error.Unphrased;
    if (unit == .year) {
        const words = year_comparisons.get(op) orelse return error.Unphrased;
        try writer.writeAll(words[0]);
        try writeAmount(writer, unit, amount);
        return writer.writeAll(words[1]);
    }
    try writer.print("{s} {s} ", .{ name, comparisons.get(op) orelse return error.Unphrased });
    return writeAmount(writer, unit, amount);
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
    if (part(tile, "orca-icon")) |icon| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, icon), looks.get(look));
}

fn emptyArt(pixels: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, "playlist-art-empty");
    const icon = gtk.gtk_image_new_from_icon_name("orca-playlists-symbolic");
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

fn newArt(self: *App, pixels: c_int, icon_pixels: c_int) *gtk.Widget {
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "playlist-art");
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_halign(frame, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(frame, gtk.ALIGN_START);
    const sizer = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(sizer, pixels, pixels);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), sizer);

    const stack = gtk.gtk_stack_new();
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), emptyArt(icon_pixels), "none");
    const smart = newSmartTile(icon_pixels);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), smart, "smart");
    const one = fillingCover(self, icon_pixels);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), one, "one");
    const grid = homogeneous(gtk.ORIENTATION_VERTICAL);
    for (0..2) |row_index| {
        const row = homogeneous(gtk.ORIENTATION_HORIZONTAL);
        for (0..2) |column| {
            const cell = fillingCover(self, @divTrunc(icon_pixels, 2));
            gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell);
            gtk.g_object_set_data(frame, cell_keys[row_index * 2 + column], cell);
        }
        gtk.gtk_box_append(gtk.cast(gtk.Box, grid), row);
    }
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), grid, "grid");
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), stack);

    gtk.g_object_set_data(frame, "orca-art-sizer", sizer);
    gtk.g_object_set_data(frame, "orca-art-stack", stack);
    gtk.g_object_set_data(frame, "orca-art-smart", smart);
    gtk.g_object_set_data(frame, "orca-art-one", one);
    return frame;
}

fn sizeArt(frame: *gtk.Widget, pixels: c_int) void {
    if (part(frame, "orca-art-sizer")) |sizer| gtk.gtk_widget_set_size_request(sizer, pixels, pixels);
}

fn forgetArt(self: *App, frame: *gtk.Widget) void {
    if (part(frame, "orca-art-one")) |one| art.forget(self, one);
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
    if (covers.len < cell_keys.len) {
        art.show(self, part(frame, "orca-art-one") orelse return, art.Key.release(covers[0], .tile));
        return gtk.gtk_stack_set_visible_child_name(stack, "one");
    }
    for (cell_keys, 0..) |key, index| art.show(self, part(frame, key) orelse continue, art.Key.release(covers[index], .tile));
    gtk.gtk_stack_set_visible_child_name(stack, "grid");
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

fn showMosaicBackdrop(self: *App, backdrop: *gtk.Widget, mosaic: *gtk.Widget, cover_count: usize) void {
    if (cover_count == 0) return art.showBackdrop(self, backdrop, &.{});
    if (cover_count < cell_keys.len) return art.showBackdrop(self, backdrop, &.{part(mosaic, "orca-single") orelse return});
    var cells: [cell_keys.len]*gtk.Widget = undefined;
    for (cell_keys, &cells) |key, *cell| cell.* = part(mosaic, key) orelse return;
    art.showBackdrop(self, backdrop, &cells);
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
    const pin = gtk.gtk_image_new_from_icon_name("orca-pin-symbolic");
    gtk.gtk_widget_add_css_class(pin, "playlist-pin");
    gtk.gtk_widget_set_tooltip_text(pin, "Pinned");
    gtk.gtk_widget_set_valign(pin, gtk.ALIGN_CENTER);
    return pin;
}

const Tile = enum { pinned, listed };

fn tilePixels(self: *App, tile: Tile) c_int {
    return switch (tile) {
        .pinned => self.playlists.pinned_pixels,
        .listed => self.playlists.listed_pixels,
    };
}

fn setupTile(self: *App, item: ?*anyopaque, kind: Tile) void {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "playlist-tile");
    gtk.gtk_widget_add_css_class(tile, switch (kind) {
        .pinned => "playlist-tile-pinned",
        .listed => "playlist-tile-listed",
    });

    const frame = newArt(self, tilePixels(self, kind), tile_icon_pixels);
    const play_button = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    for ([_][*:0]const u8{ "tile-play", "tile-action", "circular" }) |class| gtk.gtk_widget_add_css_class(play_button, class);
    gtk.gtk_widget_set_halign(play_button, gtk.ALIGN_END);
    gtk.gtk_widget_set_valign(play_button, gtk.ALIGN_END);
    gtk.gtk_widget_set_tooltip_text(play_button, "Play Playlist");
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(cardPlayClicked), self);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(layers, "playlist-cover-frame");
    gtk.gtk_widget_set_halign(layers, gtk.ALIGN_START);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), frame);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), play_button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), layers);

    const title = label("playlist-tile-title");
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), title);
    gtk.g_object_set_data(tile, "orca-title", title);
    switch (kind) {
        .pinned => {
            const meta = label("playlist-tile-meta");
            gtk.gtk_widget_add_css_class(meta, "numeric");
            gtk.gtk_box_append(gtk.cast(gtk.Box, tile), meta);
            gtk.g_object_set_data(tile, "orca-tracks", meta);
        },
        .listed => {
            const owner = label("playlist-tile-kind");
            const detail = label("playlist-tile-detail");
            gtk.gtk_box_append(gtk.cast(gtk.Box, tile), owner);
            gtk.gtk_box_append(gtk.cast(gtk.Box, tile), detail);
            gtk.g_object_set_data(tile, "orca-kind", owner);
            gtk.g_object_set_data(tile, "orca-detail", detail);
        },
    }

    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), tile);
    for ([_]*gtk.Widget{ tile, play_button }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(tile, "orca-art", frame);
    menu.onSecondaryClick(tile, cardMenu, self);
}

fn setupPinnedTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setupTile(state(data), item, .pinned);
}

fn setupListedTile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setupTile(state(data), item, .listed);
}

fn setLabel(widget: *gtk.Widget, key: [*:0]const u8, text: [*:0]const u8) void {
    if (part(widget, key)) |found| gtk.gtk_label_set_text(gtk.cast(gtk.Label, found), text);
}

fn showKind(widget: *gtk.Widget, card: *const Card) void {
    const kind = part(widget, "orca-kind") orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, kind), kindText(card.kind, card.creator).ptr);
    if (card.kind == .smart) gtk.gtk_widget_add_css_class(kind, "smart") else gtk.gtk_widget_remove_css_class(kind, "smart");
}

fn detailText(buffer: []u8, card: *const Card) [:0]const u8 {
    if (card.kind == .smart and card.rules_len != 0) return card.rulesText();
    return updatedText(buffer, card.updated_at);
}

fn showCard(self: *App, widget: *gtk.Widget, card: *Card) void {
    loadCovers(self, card);
    loadRules(self, card);
    var buffer: [128]u8 = undefined;
    setLabel(widget, "orca-title", card.name.ptr);
    if (part(widget, "orca-pin")) |pin| gtk.gtk_widget_set_visible(pin, @intFromBool(card.pinned));
    showKind(widget, card);
    setLabel(widget, "orca-tracks", summaryText(&buffer, card).ptr);
    setLabel(widget, "orca-detail", detailText(&buffer, card).ptr);
    if (part(widget, "orca-art")) |frame| showArt(self, frame, card);
}

fn bindCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const card = findCard(self, cardId(tile) orelse return) orelse return;
    sizeTile(self, tile);
    showCard(self, tile, card);
}

fn sizeTile(self: *App, tile: *gtk.Widget) void {
    const kind: Tile = if (gtk.gtk_widget_has_css_class(tile, "playlist-tile-pinned") != 0) .pinned else .listed;
    sizeArt(part(tile, "orca-art") orelse return, tilePixels(self, kind));
}

fn unbindCard(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const tile = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    forgetArt(state(data), part(tile, "orca-art") orelse return);
}

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(row, "album-list-row");
    gtk.gtk_widget_add_css_class(row, "playlist-list-row");
    const frame = newArt(self, row_art_pixels, row_icon_pixels);
    gtk.gtk_widget_set_valign(frame, gtk.ALIGN_CENTER);
    const title = label("playlist-tile-title");
    const pin = pinIcon();
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), pin);
    const owner = label("playlist-tile-kind");
    const detail = label("playlist-tile-detail");
    const names = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(names, gtk.true_);
    gtk.gtk_widget_set_valign(names, gtk.ALIGN_CENTER);
    for ([_]*gtk.Widget{ heading, owner, detail }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, names), child);
    const tracks = label("album-list-detail");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, tracks), 1);
    gtk.gtk_widget_add_css_class(tracks, "numeric");
    const more = moreButton(self);
    gtk.gtk_widget_add_css_class(more, "row-more");
    for ([_]*gtk.Widget{ frame, names, tracks, more }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, row), child);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    for ([_]*gtk.Widget{ row, more }) |widget| gtk.g_object_set_data(widget, "orca-list-item", item);
    gtk.g_object_set_data(row, "orca-art", frame);
    gtk.g_object_set_data(row, "orca-title", title);
    gtk.g_object_set_data(row, "orca-pin", pin);
    gtk.g_object_set_data(row, "orca-kind", owner);
    gtk.g_object_set_data(row, "orca-detail", detail);
    gtk.g_object_set_data(row, "orca-tracks", tracks);
    menu.onSecondaryClick(row, cardMenu, self);
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const card = findCard(self, cardId(row) orelse return) orelse return;
    showCard(self, row, card);
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
    const playlist_id = playlists.open_id orelse return;
    const model = actionMenu(playlist_id, .{
        .kind = playlists.open_kind,
        .pinned = playlists.open_pinned,
        .loved = playlists.open_loved,
    }, false);
    defer gtk.g_object_unref(model);
    if (playlists.open_kind == .smart and sortsRandomly(self, playlist_id)) {
        const section = gtk.g_menu_new();
        gtk.g_menu_append(section, "Shuffle Again", "playlist.reshuffle");
        gtk.g_menu_insert_section(model, 0, null, gtk.cast(gtk.GMenuModel, section));
        gtk.g_object_unref(section);
    }
    const widget = gtk.cast(gtk.Widget, button.?);
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popupModel(widget, gtk.cast(gtk.GMenuModel, model), x, y);
}

pub fn open(self: *App, playlist_id: i64) void {
    if (self.playlists.open_id != playlist_id) if (self.playlists.reorder_button) |button|
        gtk.gtk_toggle_button_set_active(button, gtk.false_);
    self.playlists.open_id = playlist_id;
    reloadPage(self, false);
    window.showPage(self, .playlists);
    const navigation = self.playlists.navigation orelse return;
    const visible = adw.adw_navigation_view_get_visible_page_tag(navigation);
    if (visible != null and std.mem.eql(u8, std.mem.span(visible.?), page_tag)) return;
    window.popToTag(self, navigation, overview_tag);
    adw.adw_navigation_view_push_by_tag(navigation, page_tag);
}

/// `By you · 12 tracks · 52 min · Updated today`, as markup.
fn heroMeta(buffer: []u8, summary: *const liborca.PlaylistSummary) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeMeta(&writer, summary) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn writeMeta(writer: *std.Io.Writer, summary: *const liborca.PlaylistSummary) std.Io.Writer.Error!void {
    try writer.writeAll(kindText(summary.kind, summary.creator));
    try writer.print("{s}{d} {s}", .{ meta_separator, summary.entries, plural(summary.entries, "track", "tracks") });
    if (summary.entries != 0) {
        var duration_buffer: [32]u8 = undefined;
        try writer.print("{s}{s}", .{ meta_separator, strings.totalDuration(&duration_buffer, summary.duration_ms) });
    }
    const missing = summary.entries -| summary.available;
    if (missing != 0) try writer.print("{s}{d} unavailable", .{ meta_separator, missing });
    if (summary.updated_at > 0) {
        var updated_buffer: [64]u8 = undefined;
        try writer.print("{s}{s}", .{ meta_separator, updatedText(&updated_buffer, summary.updated_at) });
    }
}

fn showHero(self: *App, summary: ?*const liborca.PlaylistSummary, covers: []const i64) void {
    const playlists = &self.playlists;
    var name_buffer: [512]u8 = undefined;
    const name: [:0]const u8 = if (summary) |found| strings.terminated(&name_buffer, found.name) else "Playlist";
    playlists.setOpenName(self.allocator, name);
    playlists.open_kind = if (summary) |found| found.kind else .manual;
    playlists.open_pinned = if (summary) |found| found.pinned else false;
    playlists.open_loved = if (summary) |found| found.loved else false;
    const smart = playlists.open_kind == .smart;

    if (playlists.page) |page| adw.adw_navigation_page_set_title(page, name.ptr);
    page_ui.refresh(self);
    if (playlists.title) |title| gtk.gtk_label_set_text(title, name.ptr);
    if (playlists.eyebrow) |eyebrow| gtk.gtk_label_set_text(eyebrow, if (smart) "SMART PLAYLIST" else "PLAYLIST");
    if (playlists.meta) |meta| {
        var buffer: [512]u8 = undefined;
        gtk.gtk_label_set_markup(meta, if (summary) |found| heroMeta(&buffer, found).ptr else "");
    }
    if (playlists.description) |description| {
        var buffer: [4100]u8 = undefined;
        const text: []const u8 = if (summary) |found| found.description else "";
        gtk.gtk_label_set_text(description, strings.terminated(&buffer, text).ptr);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, description), @intFromBool(text.len != 0));
    }
    if (playlists.edit_button) |button| gtk.gtk_widget_set_tooltip_text(button, if (smart) "Edit Rules" else "Edit Details");
    if (playlists.reorder_button) |button| {
        if (smart) gtk.gtk_toggle_button_set_active(button, gtk.false_);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, button), @intFromBool(!smart));
    }
    if (playlists.hero_art) |hero_art| {
        gtk.gtk_stack_set_visible_child_name(hero_art, if (smart) "smart" else "mosaic");
        if (smart) {
            if (playlists.smart_tile) |tile| showSmartTile(tile, lookOf(self, playlists.open_id orelse 0));
        }
    }
    if (playlists.mosaic) |mosaic| {
        const shown: []const i64 = if (smart) &.{} else covers;
        showMosaic(self, mosaic, shown);
        if (playlists.backdrop) |backdrop| showMosaicBackdrop(self, backdrop, mosaic, shown.len);
    }
}

/// Rereads the open playlist. `keep_scroll` holds the list where it was, for
/// an edit to the rows the user is looking at.
pub fn reloadPage(self: *App, keep_scroll: bool) void {
    const store = self.playlists.tracks.store orelse return;
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
    window.syncInspector(self);
    details.playlistChanged(self, playlist_id);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    track_table.repaint(&self.playlists.tracks, changed, change);
}

fn rowAt(self: *App, position: u32) ?*TrackObject {
    const store = self.playlists.tracks.store orelse return null;
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
    if (!row.inLibrary()) return self.toast("That track is not in your library");
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

fn editClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const playlist_id = self.playlists.open_id orelse return;
    if (self.playlists.open_kind == .smart) editRules(self, playlist_id) else askDetails(self, playlist_id);
}

fn reorderToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const column = self.playlists.handle_column orelse return;
    gtk.gtk_column_view_column_set_visible(column, gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)));
}

fn reshuffleActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.libraryReshufflePlaylists();
    refresh(self);
    reloadPage(self, false);
}

/// Whether the smart playlist's rules sort it at random.
fn sortsRandomly(self: *App, playlist_id: i64) bool {
    const parsed = parseRules(self, playlist_id) orelse return false;
    defer parsed.deinit();
    const rules = objectOf(parsed.value) orelse return false;
    const sort = objectOf(rules.get("sort")) orelse return false;
    const field = stringOf(sort.get("field")) orelse return false;
    return std.mem.eql(u8, field, "random");
}

fn countRules(value: std.json.Value) usize {
    const object = objectOf(value) orelse return 0;
    if (object.get("op") != null) return 1;
    var count: usize = 0;
    for (arrayOf(object.get("rules")) orelse return 0) |item| count += countRules(item);
    return count;
}

/// The smart playlist's conditions, nested groups counted by their rules.
pub fn ruleCount(self: *App, playlist_id: i64) ?usize {
    const parsed = parseRules(self, playlist_id) orelse return null;
    defer parsed.deinit();
    return countRules(parsed.value);
}

/// Opens the smart playlist editor on one rule: in this playlist.
pub fn duplicateAsSmart(self: *App, playlist_id: i64) void {
    const library = self.library orelse return;
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch return self.toast("Could not read that playlist");
    defer summary.deinit(self.runtime.allocator);
    if (summary.kind == .smart) return self.toast("Only a playlist in your own order can be duplicated");
    var rules_buffer: [200]u8 = undefined;
    const rules = std.fmt.bufPrint(&rules_buffer, "{{\"v\":1,\"match\":\"all\",\"rules\":[{{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":{d}}}],\"sort\":{{\"field\":\"playlist_position\",\"playlist\":{d}}}}}", .{ playlist_id, playlist_id }) catch return;
    var name_buffer: [600]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "{s} (smart)", .{summary.name}) catch summary.name;
    smart_playlist_editor.presentRules(self, name, rules);
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
    gtk.gtk_widget_add_css_class(box, "segmented");
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    const choices_ = [_]struct { layout: albums.Layout, icon: [*:0]const u8, tooltip: [*:0]const u8 }{
        .{ .layout = .grid, .icon = "orca-grid-symbolic", .tooltip = "Grid view" },
        .{ .layout = .list, .icon = "orca-list-symbolic", .tooltip = "List view" },
    };
    var group: ?*gtk.ToggleButton = null;
    for (choices_) |choice| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), choice.icon);
        gtk.gtk_widget_set_tooltip_text(button, choice.tooltip);
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, button), gtk.ACCESSIBLE_PROPERTY_LABEL, choice.tooltip, @as(c_int, -1));
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
    const smart = albums.pill("New Smart Playlist", smart_icon, false);
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

fn sectionTitle(text: [*:0]const u8) *gtk.Widget {
    const title = label("playlist-section-title");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), text);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_NONE);
    return title;
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

fn resizeTiles(grid: *gtk.GridView, self: *App) void {
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, grid));
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) sizeTile(self, gtk.gtk_widget_get_first_child(cell) orelse continue);
}

fn applyColumns(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const playlists = &self.playlists;
    playlists.columns_idle = 0;
    for ([_]?*gtk.GridView{ playlists.pinned_grid, playlists.listed_grid }, [_]c_uint{ playlists.pinned_columns, playlists.listed_columns }) |maybe, columns| {
        const grid = maybe orelse continue;
        gtk.gtk_grid_view_set_min_columns(grid, columns);
        gtk.gtk_grid_view_set_max_columns(grid, columns);
        resizeTiles(grid, self);
    }
    return gtk.SOURCE_REMOVE;
}

fn cardGridDestroyed(grid: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const playlists = &state(data).playlists;
    if (playlists.columns_idle != 0) _ = gtk.g_source_remove(playlists.columns_idle);
    playlists.columns_idle = 0;
    if (@as(?*anyopaque, playlists.pinned_grid) == grid) playlists.pinned_grid = null;
    if (@as(?*anyopaque, playlists.listed_grid) == grid) playlists.listed_grid = null;
}

fn overviewResized(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const playlists = &self.playlists;
    const page_width = gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment));
    const width = page_width - @as(f64, if (self.window_narrow) 32 else 64);
    if (!(width > 0)) return;
    const pinned = pinned_tile.columns(width);
    const listed = listed_tile.columns(width);
    const pinned_pixels = pinned_tile.pixels(width, pinned);
    const listed_pixels = listed_tile.pixels(width, listed);
    if (pinned == playlists.pinned_columns and listed == playlists.listed_columns and
        pinned_pixels == playlists.pinned_pixels and listed_pixels == playlists.listed_pixels) return;
    playlists.pinned_columns = pinned;
    playlists.listed_columns = listed;
    playlists.pinned_pixels = pinned_pixels;
    playlists.listed_pixels = listed_pixels;
    if (playlists.columns_idle == 0) playlists.columns_idle = gtk.g_idle_add(applyColumns, self);
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
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(section, "playlist-section");
    self.playlists.pinned_section = section;
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const icon = gtk.gtk_image_new_from_icon_name("orca-pin-symbolic");
    gtk.gtk_widget_add_css_class(icon, "playlist-section-icon");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), sectionTitle("Pinned"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), heading);
    const grid = newCardGrid(self, store, gtk.callback(setupPinnedTile), gtk.callback(pinnedActivated));
    gtk.gtk_widget_add_css_class(grid, "playlist-grid-pinned");
    self.playlists.pinned_grid = gtk.cast(gtk.GridView, grid);
    _ = gtk.signalConnect(grid, "destroy", gtk.callback(cardGridDestroyed), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), grid);
    return section;
}

fn buildListed(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.playlists.all_store = store;
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(section, "playlist-section");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    const words = sectionTitle("All Playlists");
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    const controls = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_valign(controls, gtk.ALIGN_CENTER);
    self.playlists.all_controls = controls;
    var sort_labels: [sorts.len + 1]?[*:0]const u8 = undefined;
    for (sorts, 0..) |entry, index| sort_labels[index] = entry.label;
    sort_labels[sorts.len] = null;
    const sort = gtk.gtk_drop_down_new_from_strings(&sort_labels);
    gtk.gtk_widget_set_tooltip_text(sort, "Sort playlists");
    gtk.gtk_widget_add_css_class(sort, "btn-dropdown");
    gtk.gtk_widget_set_valign(sort, gtk.ALIGN_CENTER);
    self.playlists.sort_control = gtk.cast(gtk.DropDown, sort);
    _ = gtk.signalConnect(sort, "notify::selected", gtk.callback(sortChanged), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, controls), sort);
    gtk.gtk_box_append(gtk.cast(gtk.Box, controls), newLayoutSwitch(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), words);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), controls);

    const empty = statusPage("media-playlist-consecutive-symbolic", "No playlists yet", "Make one, let rules choose its tracks, or import an M3U file.");
    adw.adw_status_page_set_child(gtk.cast(adw.StatusPage, empty), creationButtons(self));
    const no_results = statusPage("edit-find-symbolic", "No playlists found", "Try a different search or tab.");
    const body = gtk.gtk_stack_new();
    gtk.gtk_stack_set_vhomogeneous(gtk.cast(gtk.Stack, body), gtk.false_);
    self.playlists.overview_body = gtk.cast(gtk.Stack, body);
    const grid = newCardGrid(self, store, gtk.callback(setupListedTile), gtk.callback(listedActivated));
    gtk.gtk_widget_add_css_class(grid, "playlist-grid-listed");
    self.playlists.listed_grid = gtk.cast(gtk.GridView, grid);
    _ = gtk.signalConnect(grid, "destroy", gtk.callback(cardGridDestroyed), self);
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, grid, "grid");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, newRowList(self, store), "list");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, empty, "empty");
    _ = gtk.gtk_stack_add_named(self.playlists.overview_body.?, no_results, "no-results");
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), body);
    return section;
}

fn headerButton(text: [*:0]const u8, icon: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const image = gtk.gtk_image_new_from_icon_name(icon);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), 16);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), image);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(text));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, class);
    gtk.gtk_widget_add_css_class(button, "playlist-header-button");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_END);
    return button;
}

fn buildOverview(self: *App) *gtk.Widget {
    const title = page_ui.title("Playlists");
    gtk.gtk_label_set_text(title.meta, "Your playlists and smart collections.");
    const smart = headerButton("New Smart Playlist", smart_icon, "btn-secondary");
    _ = gtk.signalConnect(smart, "clicked", gtk.callback(newSmartClicked), self);
    const create = headerButton("New Playlist", "orca-plus-symbolic", "btn-primary");
    _ = gtk.signalConnect(create, "clicked", gtk.callback(newClicked), self);
    title.add(smart);
    title.add(create);

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 22);
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

const page_columns = track_table.ColumnSet.initMany(&.{ .number, .album, .duration });

fn entryRow(item: ?*anyopaque) ?*TrackObject {
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item.?)) orelse return null;
    return @ptrCast(@alignCast(object));
}

fn rowWidget(child: *gtk.Widget) ?*gtk.Widget {
    const cell = gtk.gtk_widget_get_parent(child) orelse return null;
    return gtk.gtk_widget_get_parent(cell);
}

fn setupTitle(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    for ([_][*:0]const u8{ "track-title", "playlist-track-artist" }) |class| {
        const text = gtk.gtk_label_new(null);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, text), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, text), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_add_css_class(text, class);
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), text);
    }
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item.?), box);
    gtk.g_object_set_data(box, "orca-list-item", item);
    menu.onSecondaryClick(box, titleMenu, data);
}

fn bindTitle(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = entryRow(item) orelse return;
    const box = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item.?)) orelse return;
    const title = gtk.gtk_widget_get_first_child(box) orelse return;
    const artist = gtk.gtk_widget_get_next_sibling(title) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), row.title().ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), row.artist().ptr);
    if (row.hasFile())
        gtk.gtk_widget_remove_css_class(box, "dim-label")
    else
        gtk.gtk_widget_add_css_class(box, "dim-label");
    const row_widget = rowWidget(box) orelse return;
    gtk.g_object_set_data(row_widget, "orca-playlist-item", item);
    if (gtk.g_object_get_data(row_widget, "orca-playlist-drop") != null) return;
    const target = gtk.gtk_drop_target_new(gtk.G_TYPE_UINT, gtk.ACTION_MOVE);
    _ = gtk.signalConnect(target, "drop", gtk.callback(dropped), data);
    gtk.gtk_widget_add_controller(row_widget, target);
    gtk.g_object_set_data(row_widget, "orca-playlist-drop", row_widget);
}

/// The menu a track table row opens, for the cells this page draws itself.
fn titleMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return;
    const list_item = gtk.cast(gtk.ListItem, item);
    const clicked = entryRow(item) orelse return;
    if (track_model.isPlaceholder(clicked)) return;
    const selection = self.playlists.tracks.selection orelse return;
    const position = gtk.gtk_list_item_get_position(list_item);
    if (gtk.gtk_selection_model_is_selected(selection, position) == 0)
        _ = gtk.gtk_selection_model_select_item(selection, position, gtk.true_);
    self.context.reset(.playlist);
    self.context.playlist_id = self.playlists.open_id orelse return;
    self.context.playlist_position = position;
    self.context.playlist_length = gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, selection));
    if (clicked.inLibrary() and clicked.hasFile()) {
        self.context.addTrack(self.allocator, clicked.id(), clicked.recordingId(), clicked.feedback()) catch return;
        self.context.release_id = clicked.releaseId();
        self.context.artist_id = clicked.artistId();
    }
    menu.popup(self, widget, x, y);
}

fn setupHandle(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const handle = gtk.gtk_image_new_from_icon_name("orca-grip-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, handle), 16);
    gtk.gtk_widget_add_css_class(handle, "playlist-handle");
    gtk.gtk_widget_set_halign(handle, gtk.ALIGN_START);
    gtk.gtk_widget_set_cursor_from_name(handle, "grab");
    gtk.gtk_widget_set_tooltip_text(handle, "Drag to Reorder");
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item.?), handle);
    gtk.g_object_set_data(handle, "orca-list-item", item);
    const source = gtk.gtk_drag_source_new();
    gtk.gtk_drag_source_set_actions(source, gtk.ACTION_MOVE);
    _ = gtk.signalConnect(source, "prepare", gtk.callback(dragPrepare), data);
    _ = gtk.signalConnect(source, "drag-begin", gtk.callback(dragBegin), data);
    _ = gtk.signalConnect(source, "drag-end", gtk.callback(dragEnd), data);
    gtk.gtk_widget_add_controller(handle, source);
}

fn dragPrepare(source: ?*anyopaque, _: f64, _: f64, data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self = state(data);
    if (self.playlists.open_kind == .smart) return null;
    const handle = menu.gestureWidget(source);
    const item = gtk.g_object_get_data(handle, "orca-list-item") orelse return null;
    var value: gtk.GValue = .{};
    _ = gtk.g_value_init(&value, gtk.G_TYPE_UINT);
    defer gtk.g_value_unset(&value);
    gtk.g_value_set_uint(&value, gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item)));
    return gtk.gdk_content_provider_new_for_value(&value);
}

fn dragBegin(source: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    state(data).playlists.dragging = true;
    const row = rowWidget(menu.gestureWidget(source)) orelse return;
    const paintable = gtk.gtk_widget_paintable_new(row);
    defer gtk.g_object_unref(paintable);
    gtk.gtk_drag_source_set_icon(gtk.cast(gtk.EventController, source.?), paintable, 12, 22);
}

fn dragEnd(_: ?*anyopaque, _: ?*anyopaque, _: gtk.gboolean, data: ?*anyopaque) callconv(.c) void {
    state(data).playlists.dragging = false;
}

fn dropped(target: ?*anyopaque, value: *const gtk.GValue, _: f64, _: f64, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    if (!self.playlists.dragging) return gtk.false_;
    const playlist_id = self.playlists.open_id orelse return gtk.false_;
    const row = menu.gestureWidget(target);
    const item = gtk.g_object_get_data(row, "orca-playlist-item") orelse return gtk.false_;
    const from = gtk.g_value_get_uint(value);
    const to = gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item));
    if (from != to) move(self, playlist_id, from, to);
    return gtk.true_;
}

fn addColumn(view: *gtk.ColumnView, index: c_uint, title: [*:0]const u8, setup: gtk.GCallback, bind: ?gtk.GCallback, self: *App) *gtk.ColumnViewColumn {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", setup, self);
    if (bind) |handler| _ = gtk.signalConnect(factory, "bind", handler, self);
    const column = gtk.gtk_column_view_column_new(title, factory);
    gtk.gtk_column_view_column_set_resizable(column, gtk.false_);
    gtk.gtk_column_view_insert_column(view, index, column);
    gtk.g_object_unref(column);
    return column;
}

fn arrangeColumns(self: *App) void {
    const view = self.playlists.tracks.view orelse return;
    const title = addColumn(view, 1, "Title", gtk.callback(setupTitle), gtk.callback(bindTitle), self);
    gtk.gtk_column_view_column_set_expand(title, gtk.true_);
    if (self.playlists.tracks.header(.album)) |album| {
        gtk.gtk_column_view_column_set_expand(album, gtk.false_);
        gtk.gtk_column_view_column_set_fixed_width(album, album_width);
    }
    const handle = addColumn(view, 0, "", gtk.callback(setupHandle), null, self);
    gtk.gtk_column_view_column_set_fixed_width(handle, handle_width);
    gtk.gtk_column_view_column_set_visible(handle, gtk.false_);
    self.playlists.handle_column = handle;
}

fn roundButton(icon: [*:0]const u8, tooltip: [*:0]const u8, toggle: bool) *gtk.Widget {
    const button = if (toggle) gtk.gtk_toggle_button_new() else gtk.gtk_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, button), icon);
    gtk.gtk_widget_add_css_class(button, "album-more");
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

fn buildPlaylistPage(self: *App) *adw.NavigationPage {
    const list = track_table.build(&self.playlists.tracks, self, .{
        .multiple = false,
        .sortable = false,
        .playlist = true,
        .columns = page_columns,
        .duration_icon = true,
    });
    gtk.gtk_widget_add_css_class(list, "playlist-table");
    arrangeColumns(self);
    const scroller = gtk.gtk_scrolled_window_new();
    self.playlists.scroller = scroller;
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    const empty = statusPage("media-playlist-consecutive-symbolic", "No tracks yet", "Right-click a track or an album and choose Add to Playlist.");
    const body = gtk.gtk_stack_new();
    self.playlists.body = gtk.cast(gtk.Stack, body);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    gtk.gtk_widget_add_css_class(body, "playlist-tracks");
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, empty, "empty");

    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 36);
    gtk.gtk_widget_add_css_class(hero, "album-hero");
    gtk.gtk_widget_add_css_class(hero, "playlist-hero");
    gtk.gtk_widget_set_vexpand(hero, gtk.false_);
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

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const eyebrow = gtk.gtk_label_new("PLAYLIST");
    self.playlists.eyebrow = gtk.cast(gtk.Label, eyebrow);
    gtk.gtk_widget_add_css_class(eyebrow, "album-kind");
    const title = gtk.gtk_label_new("");
    self.playlists.title = gtk.cast(gtk.Label, title);
    gtk.gtk_widget_add_css_class(title, "display-hero");
    gtk.gtk_widget_add_css_class(title, "album-hero-title");
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
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, description), 64);
    for ([_]*gtk.Widget{ eyebrow, title, meta, description }) |text| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, text), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), text);
    }
    const actions = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, actions), 10);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, actions), 8);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "artist-actions");
    gtk.gtk_widget_add_css_class(actions, "playlist-actions");
    const play_button = albums.pill("Play", "orca-play-symbolic", true);
    const shuffle_button = albums.pill("Shuffle", "orca-shuffle-symbolic", false);
    self.playlists.play_button = play_button;
    self.playlists.shuffle_button = shuffle_button;
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(shuffle_button, "clicked", gtk.callback(shuffleClicked), self);
    const reorder = roundButton("orca-grip-symbolic", "Reorder", true);
    gtk.gtk_widget_add_css_class(reorder, "playlist-reorder");
    self.playlists.reorder_button = gtk.cast(gtk.ToggleButton, reorder);
    _ = gtk.signalConnect(reorder, "toggled", gtk.callback(reorderToggled), self);
    const edit = roundButton("document-edit-symbolic", "Edit Details", false);
    self.playlists.edit_button = edit;
    _ = gtk.signalConnect(edit, "clicked", gtk.callback(editClicked), self);
    const more = roundButton("orca-more-symbolic", "Playlist Menu", false);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(pageMoreClicked), self);
    for ([_]*gtk.Widget{ play_button, shuffle_button, reorder, edit, more }) |button| adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    setNarrow(self);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "playlist-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), hero);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), body);
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_widget_set_vexpand(layers, gtk.true_);
    const backdrop = art.newBackdrop(self, .header);
    gtk.gtk_widget_add_css_class(backdrop, "playlist-backdrop");
    self.playlists.backdrop = backdrop;
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), backdrop);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), column);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), column, gtk.true_);
    page_ui.extendUnderBar(self, layers, null);

    const group = gtk.g_simple_action_group_new();
    const reshuffle = gtk.g_simple_action_new("reshuffle", null).?;
    _ = gtk.signalConnect(reshuffle, "activate", gtk.callback(reshuffleActivated), self);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, reshuffle));
    gtk.g_object_unref(reshuffle);
    gtk.gtk_widget_insert_action_group(layers, "playlist", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);

    const page = adw.adw_navigation_page_new(layers, "Playlist");
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
                error.PlaylistIsSmart => "A smart playlist's rules choose its tracks",
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
    self.toast(strings.printZ(&buffer, "Added {d} {s} to “{s}”", .{ added, plural(added, "track", "tracks"), name }) catch "Added to the playlist");
}

pub fn removeAt(self: *App, playlist_id: i64, position: u32) void {
    const library = self.library orelse return;
    _ = self.runtime.libraryPlaylistRemove(library, playlist_id, &.{position}) catch
        return self.toast("Could not remove that track");
    refresh(self);
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

pub fn move(self: *App, playlist_id: i64, from: u32, to: u32) void {
    const library = self.library orelse return;
    self.runtime.libraryPlaylistMove(library, playlist_id, from, to) catch
        return self.toast("Could not move that track");
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
    if (purpose == .create) adw.adw_alert_dialog_add_response(alert, "import", "Import…");
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
    if (std.mem.eql(u8, std.mem.span(response), "import")) return chooseImport(self);
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
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Its tracks stay in your library.");
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
        strings.printZ(&buffer, "Exported {d} {s}, {d} not in your library", .{ exported.written, plural(exported.written, "track", "tracks"), exported.skipped }) catch "Exported"
    else
        strings.printZ(&buffer, "Exported {d} {s}", .{ exported.written, plural(exported.written, "track", "tracks") }) catch "Exported");
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
        strings.printZ(&buffer, "Imported {d} {s}, {d} not found", .{ matched, plural(matched, "track", "tracks"), imported.unmatched }) catch "Imported"
    else
        strings.printZ(&buffer, "Imported {d} {s}", .{ matched, plural(matched, "track", "tracks") }) catch "Imported";
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

    const dialog = adw.adw_alert_dialog_new("Not Found", "No track in your library matches these entries.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, scroller);
    adw.adw_alert_dialog_add_response(alert, "close", "Close");
    adw.adw_alert_dialog_set_close_response(alert, "close");
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
