//! Playlists: the sidebar's Playlists section, the page that lists one
//! playlist's songs, and the dialogs that create, rename, delete, import and
//! export them.
//!
//! liborca keeps the playlists, resolves their entries and plays them; this
//! asks and shows the answer.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const track_model = @import("track_model.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const ratings = @import("ratings.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;

const insert_batch = 512;

pub const State = struct {
    section: ?*adw.SidebarSection = null,
    /// The sidebar's playlists, in its order.
    ids: std.ArrayList(i64) = .empty,
    names: std.ArrayList([:0]u8) = .empty,
    open_id: ?i64 = null,
    store: ?*gtk.ListStore = null,
    title: ?*adw.WindowTitle = null,
    body: ?*gtk.Stack = null,
    scroller: ?*gtk.Widget = null,
    play_button: ?*gtk.Widget = null,
    shuffle_button: ?*gtk.Widget = null,
    /// The last import's unmatched lines, for its toast's Details.
    unmatched: std.ArrayList([:0]u8) = .empty,
    unmatched_total: u32 = 0,

    fn clearNames(self: *State, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| allocator.free(name);
        self.names.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
    }

    fn clearUnmatched(self: *State, allocator: std.mem.Allocator) void {
        for (self.unmatched.items) |line| allocator.free(line);
        self.unmatched.clearRetainingCapacity();
        self.unmatched_total = 0;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearNames(allocator);
        self.names.deinit(allocator);
        self.ids.deinit(allocator);
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

/// Rereads the playlists and rebuilds the sidebar section from them.
pub fn fillSidebar(self: *App) void {
    const section = self.playlists.section orelse return;
    self.playlists.clearNames(self.allocator);
    if (self.library) |library| {
        if (self.runtime.libraryPlaylists(library, app.page_size, 0)) |page| {
            defer page.deinit();
            for (page.items) |summary| {
                const name = self.allocator.dupeZ(u8, summary.name) catch break;
                self.playlists.names.append(self.allocator, name) catch {
                    self.allocator.free(name);
                    break;
                };
                self.playlists.ids.append(self.allocator, summary.id) catch {
                    _ = self.playlists.names.pop();
                    self.allocator.free(name);
                    break;
                };
            }
        } else |_| self.toast("Could not read your playlists");
    }
    adw.adw_sidebar_section_remove_all(section);
    sidebarItem(section, "New Playlist…", "list-add-symbolic");
    sidebarItem(section, "Import Playlist…", "document-open-symbolic");
    for (self.playlists.names.items) |name| sidebarItem(section, name.ptr, "media-playlist-consecutive-symbolic");
}

fn sidebarItem(section: *adw.SidebarSection, title: [*:0]const u8, icon: [*:0]const u8) void {
    const item = adw.adw_sidebar_item_new(title);
    adw.adw_sidebar_item_set_icon_name(item, icon);
    adw.adw_sidebar_section_append(section, item);
}

/// Rebuilds the sidebar after a playlist was created, renamed or deleted, and
/// leaves the open playlist's page if it no longer exists.
pub fn refreshSidebar(self: *App) void {
    fillSidebar(self);
    if (self.playlists.open_id) |id| {
        if (indexOf(self, id) == null) {
            self.playlists.open_id = null;
            return window.closePlaylistPage(self);
        }
    }
    window.syncSidebarSelection(self);
}

fn indexOf(self: *App, playlist_id: i64) ?usize {
    return std.mem.indexOfScalar(i64, self.playlists.ids.items, playlist_id);
}

pub fn sidebarPosition(self: *App) ?c_uint {
    const id = self.playlists.open_id orelse return null;
    return @intCast(indexOf(self, id) orelse return null);
}

pub fn idAt(self: *App, position: c_uint) ?i64 {
    if (position >= self.playlists.ids.items.len) return null;
    return self.playlists.ids.items[position];
}

fn nameOf(self: *App, playlist_id: i64) ?[:0]const u8 {
    return self.playlists.names.items[indexOf(self, playlist_id) orelse return null];
}

pub fn openName(self: *App) [*:0]const u8 {
    return (nameOf(self, self.playlists.open_id orelse return "Playlist") orelse return "Playlist").ptr;
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

pub fn names(self: *App) []const [:0]u8 {
    return self.playlists.names.items;
}

pub fn ids(self: *App) []const i64 {
    return self.playlists.ids.items;
}

pub fn open(self: *App, playlist_id: i64) void {
    self.playlists.open_id = playlist_id;
    reloadPage(self, false);
    window.showPage(self, .playlist);
}

/// Rereads the open playlist. `keep_scroll` holds the list where it was, for
/// an edit to the rows the user is looking at.
pub fn reloadPage(self: *App, keep_scroll: bool) void {
    const store = self.playlists.store orelse return;
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
    var available: u32 = 0;
    var offset: u32 = 0;
    while (offset < liborca.max_playlist_entries) : (offset += app.page_size) {
        const page = self.runtime.libraryPlaylistEntries(library, playlist_id, app.page_size, offset) catch {
            self.toast("Could not read that playlist");
            break;
        };
        defer page.deinit();
        for (page.items) |entry| {
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

    const count = additions.items.len;
    if (self.playlists.title) |title| {
        adw.adw_window_title_set_title(title, openName(self));
        var buffer: [96]u8 = undefined;
        const missing = count - available;
        const subtitle = if (missing != 0)
            strings.printZ(&buffer, "{d} {s} · {d} not in your library", .{ count, plural(count, "song", "songs"), missing }) catch ""
        else
            strings.printZ(&buffer, "{d} {s}", .{ count, plural(count, "song", "songs") }) catch "";
        adw.adw_window_title_set_subtitle(title, subtitle.ptr);
    }
    if (self.content_page) |content| if (self.current_page == .playlist)
        adw.adw_navigation_page_set_title(content, openName(self));
    if (self.playlists.body) |body| gtk.gtk_stack_set_visible_child_name(body, if (count == 0) "empty" else "list");
    for ([_]?*gtk.Widget{ self.playlists.play_button, self.playlists.shuffle_button }) |maybe| {
        const button = maybe orelse continue;
        gtk.gtk_widget_set_sensitive(button, if (available != 0) gtk.true_ else gtk.false_);
    }
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const store = self.playlists.store orelse return;
    _ = feedback.replaceRows(store, changed, change);
}

fn rowAt(self: *App, position: u32) ?*TrackObject {
    const store = self.playlists.store orelse return null;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), position) orelse return null;
    gtk.g_object_unref(item);
    return @ptrCast(@alignCast(item));
}

fn length(self: *App) u32 {
    const store = self.playlists.store orelse return 0;
    return gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store));
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

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playAll(state(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playAll(state(data), true);
}

fn playAll(self: *App, shuffled: bool) void {
    const playlist_id = self.playlists.open_id orelse return;
    const library = self.library orelse return;
    self.runtime.playerSetShuffle(self.player, shuffled) catch {};
    play(self, playlist_id, library, 0);
}

fn rowActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    playFrom(state(data), position);
}

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "playlist-row");
    const number = gtk.gtk_label_new(null);
    gtk.gtk_widget_set_size_request(number, 28, -1);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 1.0);
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_widget_add_css_class(number, "dim-label");

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title = gtk.gtk_label_new(null);
    const detail = gtk.gtk_label_new(null);
    for ([_]*gtk.Widget{ title, detail }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    }
    gtk.gtk_widget_add_css_class(detail, "caption");
    gtk.gtk_widget_add_css_class(detail, "dim-label");
    const heart = feedback.newRowButton(gtk.callback(heartClicked), self);
    gtk.g_object_set_data(heart, "orca-list-item", item);
    const stars = ratings.newRowStars(gtk.callback(starClicked), self);
    gtk.g_object_set_data(stars, "orca-list-item", item);
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const title_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    for ([_]*gtk.Widget{ title, heart, stars, spacer }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title_row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);

    const duration = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(duration, "numeric");
    gtk.gtk_widget_add_css_class(duration, "dim-label");

    for ([_]*gtk.Widget{ number, labels, duration }) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, row), widget);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, rowMenu, self);
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    const row = gtk.gtk_list_item_get_child(list_item) orelse return;
    const number = gtk.gtk_widget_get_first_child(row) orelse return;
    const labels = gtk.gtk_widget_get_next_sibling(number) orelse return;
    const duration = gtk.gtk_widget_get_next_sibling(labels) orelse return;
    const title_row = gtk.gtk_widget_get_first_child(labels) orelse return;
    const detail = gtk.gtk_widget_get_next_sibling(title_row) orelse return;
    const title = gtk.gtk_widget_get_first_child(title_row) orelse return;
    const heart = gtk.gtk_widget_get_next_sibling(title) orelse return;
    const stars = gtk.gtk_widget_get_next_sibling(heart) orelse return;

    var buffer: [512]u8 = undefined;
    const position = gtk.gtk_list_item_get_position(list_item);
    const number_text: [:0]const u8 = strings.printZ(&buffer, "{d}", .{position + 1}) catch "";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, number), number_text.ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), track.title().ptr);
    const in_library = track.inLibrary();
    gtk.gtk_widget_set_visible(heart, if (in_library) gtk.true_ else gtk.false_);
    gtk.gtk_widget_set_visible(stars, if (in_library) gtk.true_ else gtk.false_);
    feedback.showRowButton(heart, track.feedback());
    ratings.show(stars, track.rating());
    const detail_text: [:0]const u8 = if (!in_library)
        "Its recording has no track in the library"
    else if (track.artist().len != 0 and track.album().len != 0)
        strings.printZ(&buffer, "{s} · {s}", .{ track.artist(), track.album() }) catch ""
    else
        strings.printZ(&buffer, "{s}{s}", .{ track.artist(), track.album() }) catch "";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), detail_text.ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, duration), track.durationText(&buffer).ptr);
    if (in_library and track.hasFile())
        gtk.gtk_widget_remove_css_class(row, "dim-label")
    else
        gtk.gtk_widget_add_css_class(row, "dim-label");
}

fn listItemTrack(widget: ?*anyopaque) ?*TrackObject {
    const item = gtk.g_object_get_data(widget orelse return null, "orca-list-item") orelse return null;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    return @ptrCast(@alignCast(object));
}

fn heartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const track = listItemTrack(button) orelse return;
    feedback.toggle(state(data), .{ .track_id = track.id(), .recording_id = track.recordingId(), .feedback = track.feedback() });
}

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const track = listItemTrack(ratings.starsOf(button)) orelse return;
    ratings.change(state(data), &.{.{ .track_id = track.id(), .recording_id = track.recordingId(), .feedback = track.feedback() }}, ratings.chosen(button));
}

fn rowMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return;
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    self.context.reset(.playlist);
    self.context.playlist_id = self.playlists.open_id orelse return;
    self.context.playlist_position = gtk.gtk_list_item_get_position(list_item);
    self.context.playlist_length = length(self);
    if (track.inLibrary() and track.hasFile()) {
        self.context.addTrack(self.allocator, track.id(), track.recordingId(), track.feedback()) catch return;
        self.context.release_id = track.releaseId();
        self.context.artist_id = track.artistId();
    }
    menu.popup(self, row, x, y);
}

pub fn build(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(track_model.getType()).?;
    self.playlists.store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindRow), self);
    const list = gtk.gtk_list_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(list, "playlist-list");
    _ = gtk.signalConnect(list, "activate", gtk.callback(rowActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    self.playlists.scroller = scroller;
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "playlist-actions");
    const play_button = albums.pill("Play", "media-playback-start-symbolic", true);
    const shuffle_button = albums.pill("Shuffle", "media-playlist-shuffle-symbolic", false);
    self.playlists.play_button = play_button;
    self.playlists.shuffle_button = shuffle_button;
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), self);
    _ = gtk.signalConnect(shuffle_button, "clicked", gtk.callback(shuffleClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), play_button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), shuffle_button);
    const listing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, listing), scroller);

    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "media-playlist-consecutive-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "No songs yet");
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, empty), "Right-click a song or an album and choose Add to Playlist.");
    const body = gtk.gtk_stack_new();
    self.playlists.body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, listing, "list");
    _ = gtk.gtk_stack_add_named(self.playlists.body.?, empty, "empty");

    const header = adw.adw_header_bar_new();
    const title = adw.adw_window_title_new("Playlist", "");
    self.playlists.title = gtk.cast(adw.WindowTitle, title);
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), title);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), playlistMenu());

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

fn playlistMenu() *gtk.Widget {
    const model = gtk.g_menu_new();
    gtk.g_menu_append(model, "Rename…", "app.playlist-rename");
    gtk.g_menu_append(model, "Export…", "app.playlist-export");
    gtk.g_menu_append(model, "Delete…", "app.playlist-delete");
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_icon_name(gtk.cast(gtk.MenuButton, button), "view-more-symbolic");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, button), gtk.cast(gtk.GMenuModel, model));
    gtk.gtk_widget_set_tooltip_text(button, "Playlist Menu");
    gtk.g_object_unref(model);
    return button;
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
                else => "Could not add to that playlist",
            });
            break;
        };
        added += insertion.added;
    }
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
    if (added == 0) return;
    var buffer: [640]u8 = undefined;
    const name = nameOf(self, playlist_id) orelse "the playlist";
    self.toast(strings.printZ(&buffer, "Added {d} {s} to “{s}”", .{ added, plural(added, "song", "songs"), name }) catch "Added to the playlist");
}

pub fn removeAt(self: *App, playlist_id: i64, position: u32) void {
    const library = self.library orelse return;
    _ = self.runtime.libraryPlaylistRemove(library, playlist_id, &.{position}) catch
        return self.toast("Could not remove that song");
    if (self.playlists.open_id == playlist_id) reloadPage(self, true);
}

pub fn move(self: *App, playlist_id: i64, from: u32, to: u32) void {
    const library = self.library orelse return;
    self.runtime.libraryPlaylistMove(library, playlist_id, from, to) catch
        return self.toast("Could not move that song");
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
            refreshSidebar(self);
            if (request.purpose == .create) return open(self, playlist_id);
            addTracks(self, playlist_id, request.track_ids);
        },
        .rename => {
            const playlist_id = request.playlist_id orelse return;
            self.runtime.libraryRenamePlaylist(library, playlist_id, name) catch |err| return self.toast(nameError(err));
            refreshSidebar(self);
            if (self.playlists.open_id == playlist_id) reloadPage(self, true);
        },
    }
}

pub fn askRename(self: *App) void {
    const playlist_id = self.playlists.open_id orelse return;
    askName(self, .rename, playlist_id, nameOf(self, playlist_id) orelse "", &.{});
}

const PlaylistRequest = struct {
    self: *App,
    playlist_id: i64,
};

pub fn confirmDelete(self: *App) void {
    const playlist_id = self.playlists.open_id orelse return;
    var buffer: [640]u8 = undefined;
    const heading = strings.printZ(&buffer, "Delete “{s}”?", .{nameOf(self, playlist_id) orelse ""}) catch "Delete this playlist?";
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
    refreshSidebar(self);
}

pub fn chooseExport(self: *App) void {
    const playlist_id = self.playlists.open_id orelse return;
    const request = self.allocator.create(PlaylistRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .playlist_id = playlist_id };
    var name_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&name_buffer);
    for (nameOf(self, playlist_id) orelse "Playlist") |byte| writer.writeByte(if (byte == '/') '-' else byte) catch break;
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
    refreshSidebar(self);
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

    const label = gtk.gtk_label_new(@ptrCast(text.items.ptr));
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, label), gtk.WRAP_WORD_CHAR);
    gtk.gtk_widget_add_css_class(label, "monospace");
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 320);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), label);

    const dialog = adw.adw_alert_dialog_new("Not Found", "No song in your library matches these entries.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, scroller);
    adw.adw_alert_dialog_add_response(alert, "close", "Close");
    adw.adw_alert_dialog_set_close_response(alert, "close");
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}
