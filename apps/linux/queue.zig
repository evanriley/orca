//! The Queue page: what the Player will play, resolved by the engine, with the
//! audible entry marked.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const track_model = @import("track_model.zig");
const art = @import("art.zig");
const nowplaying = @import("nowplaying.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const ratings = @import("ratings.zig");
const page_ui = @import("page.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const thumb_pixels: c_int = 40;

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "queue-row");
    const marker = gtk.gtk_stack_new();
    gtk.gtk_widget_set_size_request(marker, 28, -1);
    const number = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_widget_add_css_class(number, "queue-number");
    const playing = gtk.gtk_image_new_from_icon_name("media-playback-start-symbolic");
    gtk.gtk_widget_add_css_class(playing, "accent");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, marker), number, "number");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, marker), playing, "playing");

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title = gtk.gtk_label_new(null);
    const artist = gtk.gtk_label_new(null);
    for ([_]*gtk.Widget{ title, artist }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), artist);
    gtk.gtk_widget_add_css_class(title, "queue-title");
    gtk.gtk_widget_add_css_class(artist, "queue-artist");

    const heart = feedback.newRowButton(gtk.callback(heartClicked), self);
    gtk.g_object_set_data(heart, "orca-list-item", item);
    const stars = ratings.newRowStars(gtk.callback(starClicked), self);
    gtk.g_object_set_data(stars, "orca-list-item", item);

    const duration = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(duration, "numeric");
    gtk.gtk_widget_add_css_class(duration, "queue-duration");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration), 1.0);
    gtk.gtk_widget_set_size_request(duration, 44, -1);

    const cover = art.newCover(self, art.iconPlaceholder(thumb_pixels), thumb_pixels);
    gtk.gtk_widget_add_css_class(cover, "queue-cover");
    const remove = gtk.gtk_button_new_from_icon_name("list-remove-symbolic");
    gtk.gtk_widget_set_tooltip_text(remove, "Remove from queue");
    gtk.gtk_widget_add_css_class(remove, "flat");
    gtk.gtk_widget_add_css_class(remove, "circular");
    gtk.gtk_widget_add_css_class(remove, "queue-remove");
    gtk.gtk_widget_set_valign(remove, gtk.ALIGN_CENTER);
    gtk.g_object_set_data(remove, "orca-list-item", item);
    _ = gtk.signalConnect(remove, "clicked", gtk.callback(removeClicked), self);

    for ([_]*gtk.Widget{ marker, cover, labels, heart, stars, duration, remove }) |part|
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), part);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, rowMenu, self);
}

fn heartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const item = gtk.g_object_get_data(button.?, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    feedback.toggle(self, .{ .track_id = track.id(), .recording_id = track.recordingId(), .feedback = track.feedback() });
}

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const stars = ratings.starsOf(button) orelse return;
    const item = gtk.g_object_get_data(stars, "orca-list-item") orelse return;
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    ratings.change(self, &.{.{ .track_id = track.id(), .recording_id = track.recordingId(), .feedback = track.feedback() }}, ratings.chosen(button));
}

fn removeClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const item = gtk.g_object_get_data(button.?, "orca-list-item") orelse return;
    self.context.reset(.queue);
    self.context.queue_position = gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item));
    menu.remove(self);
}

fn rowMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return;
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    self.context.reset(.queue);
    self.context.queue_position = gtk.gtk_list_item_get_position(list_item);
    self.context.addTrack(self.allocator, track.id(), track.recordingId(), track.feedback()) catch return;
    self.context.release_id = track.releaseId();
    self.context.artist_id = track.artistId();
    menu.popup(self, row, x, y);
}

fn rowActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.playerQueueJump(self.player, position) catch return;
    self.mpris.notify();
    self.requestTick();
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const track: *TrackObject = @ptrCast(@alignCast(object));
    const row = gtk.gtk_list_item_get_child(list_item) orelse return;
    const marker = gtk.gtk_widget_get_first_child(row) orelse return;
    const cover = gtk.gtk_widget_get_next_sibling(marker) orelse return;
    const labels = gtk.gtk_widget_get_next_sibling(cover) orelse return;
    const heart = gtk.gtk_widget_get_next_sibling(labels) orelse return;
    const stars = gtk.gtk_widget_get_next_sibling(heart) orelse return;
    const duration = gtk.gtk_widget_get_next_sibling(stars) orelse return;
    const title = gtk.gtk_widget_get_first_child(labels) orelse return;
    const artist = gtk.gtk_widget_get_next_sibling(title) orelse return;
    const number = gtk.gtk_widget_get_first_child(marker) orelse return;

    const position = gtk.gtk_list_item_get_position(list_item);
    var buffer: [32]u8 = undefined;
    const number_text: [:0]const u8 = strings.printZ(&buffer, "{d}", .{position + 1}) catch "";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, number), number_text.ptr);
    const current = position == self.shown_queue_index;
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, marker), if (current) "playing" else "number");
    if (gtk.gtk_widget_get_next_sibling(duration)) |remove|
        gtk.gtk_widget_set_visible(remove, if (current) gtk.false_ else gtk.true_);
    if (current)
        gtk.gtk_widget_add_css_class(row, "now-playing")
    else
        gtk.gtk_widget_remove_css_class(row, "now-playing");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), track.title().ptr);
    feedback.showRowButton(heart, track.feedback());
    ratings.show(stars, track.rating());
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), track.artist().ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, duration), track.durationText(&buffer).ptr);
    art.show(self, cover, if (track.releaseId()) |release| art.Key.release(release, .thumb) else art.Key.track(track.id(), .thumb));
}

fn unbindRow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    const marker = gtk.gtk_widget_get_first_child(row) orelse return;
    const cover = gtk.gtk_widget_get_next_sibling(marker) orelse return;
    art.forget(state(data), cover);
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.playerClearQueue(self.player) catch return;
    self.mpris.notify();
    self.requestTick();
}

pub fn build(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(track_model.getType()).?;
    self.queue_store = store;
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupRow), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindRow), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindRow), self);
    const list = gtk.gtk_list_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(list, "queue-list");
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, list), gtk.LIST_TAB_ITEM);
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, list), gtk.true_);
    _ = gtk.signalConnect(list, "activate", gtk.callback(rowActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);

    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "view-list-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "Nothing queued");
    adw.adw_status_page_set_description(
        gtk.cast(adw.StatusPage, empty),
        "Play a song, or select several and press Enter.",
    );

    const body = gtk.gtk_stack_new();
    self.queue_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.queue_body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(self.queue_body.?, empty, "empty");
    gtk.gtk_stack_set_visible_child_name(self.queue_body.?, "empty");

    const title = page_ui.title("Queue");
    self.queue_meta = title.meta;
    const clear = gtk.gtk_button_new_from_icon_name("edit-clear-all-symbolic");
    gtk.gtk_widget_set_tooltip_text(clear, "Clear the queue");
    _ = gtk.signalConnect(clear, "clicked", gtk.callback(clearClicked), self);
    gtk.gtk_widget_add_css_class(clear, "flat");
    title.add(clear);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), page_ui.header());
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), page_ui.withTitle(title, body));
    return view;
}

/// Rebuilds the page from the engine. Bounded by one page, which is as much of
/// a queue as anyone scrolls through.
fn refill(self: *App, status: liborca.PlayerStatus) void {
    const store = self.queue_store orelse return;
    gtk.g_list_store_remove_all(store);
    var page = self.runtime.playerQueueTracks(self.player, self.allocator, 0, app.page_size) catch {
        if (self.queue_body) |body| gtk.gtk_stack_set_visible_child_name(body, "empty");
        return;
    };
    defer page.deinit();
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    for (page.items) |item| {
        const row = track_model.new(item) orelse continue;
        additions.append(self.allocator, row) catch {
            gtk.g_object_unref(row);
            break;
        };
    }
    if (additions.items.len != 0) {
        gtk.g_list_store_splice(store, 0, 0, additions.items.ptr, @intCast(additions.items.len));
        for (additions.items) |row| gtk.g_object_unref(row);
    }
    if (self.queue_body) |body|
        gtk.gtk_stack_set_visible_child_name(body, if (additions.items.len == 0) "empty" else "list");
    if (self.queue_meta) |meta| {
        var total_ms: i64 = 0;
        for (page.items) |item| total_ms += item.duration_ms orelse 0;
        var buffer: [96]u8 = undefined;
        var duration_buffer: [32]u8 = undefined;
        const songs: []const u8 = if (status.queue_length == 1) "song" else "songs";
        const subtitle = if (status.queue_length == 0)
            ""
        else if (page.items.len < status.queue_length)
            strings.format(&buffer, "{d} {s}", .{ status.queue_length, songs })
        else
            strings.format(&buffer, "{d} {s} • {s}", .{ status.queue_length, songs, strings.totalDuration(&duration_buffer, total_ms) });
        gtk.gtk_label_set_text(meta, subtitle.ptr);
    }
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const store = self.queue_store orelse return;
    _ = feedback.replaceRows(store, changed, change);
}

/// Forces the next tick to rebuild the page, for when it becomes visible.
pub fn invalidate(self: *App) void {
    self.shown_queue_length = std.math.maxInt(u32);
    self.shown_queue_index = std.math.maxInt(u32);
    self.shown_queue_shuffle = null;
    self.shown_queue_serial = std.math.maxInt(u32);
}

pub fn tick(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;
    if (self.queue_count) |label| {
        var buffer: [16]u8 = undefined;
        const text = if (status.queue_length == 0)
            ""
        else
            strings.printZ(&buffer, "{d}", .{status.queue_length}) catch "";
        gtk.gtk_label_set_text(label, text.ptr);
    }
    if (status.queue_length == self.shown_queue_length and
        status.queue_index == self.shown_queue_index and
        status.shuffle == self.shown_queue_shuffle and
        status.entry_serial == self.shown_queue_serial) return;
    self.shown_queue_length = status.queue_length;
    self.shown_queue_index = status.queue_index;
    self.shown_queue_shuffle = status.shuffle;
    self.shown_queue_serial = status.entry_serial;
    if (self.queue_visible) refill(self, status);
    nowplaying.refreshUpNext(self);
}
