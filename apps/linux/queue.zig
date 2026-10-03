//! The Queue page: the audible entry, what the Player plays after it and what
//! it played before, each resolved by the engine.

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
const playlists = @import("playlists.zig");
const settings = @import("settings.zig");
const page_ui = @import("page.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;

const now_cover_pixels: c_int = 48;
const row_cover_pixels: c_int = 32;
const history_capacity = liborca.queue_history_capacity;

pub const State = struct {
    now_store: ?*gtk.ListStore = null,
    next_store: ?*gtk.ListStore = null,
    history_store: ?*gtk.ListStore = null,
    meta: ?*gtk.Label = null,
    body: ?*gtk.Stack = null,
    now_section: ?*gtk.Widget = null,
    next_section: ?*gtk.Widget = null,
    next_meta: ?*gtk.Label = null,
    next_list: ?*gtk.Widget = null,
    history_section: ?*gtk.Widget = null,
    history_list: ?*gtk.Widget = null,
    history_toggle: ?*gtk.Widget = null,
    history_shown: bool = true,
    /// The queue position behind each Up Next row: `playerQueueTracks` skips
    /// entries whose Track is gone, so a row index is not a position.
    next_positions: [app.page_size]u32 = undefined,
    next_count: usize = 0,
    history_ended_ms: [history_capacity]i64 = undefined,
    history_count: usize = 0,
    shown_length: u32 = std.math.maxInt(u32),
    shown_index: u32 = std.math.maxInt(u32),
    shown_shuffle: ?bool = null,
    shown_serial: u32 = std.math.maxInt(u32),
    shown_minute: i64 = 0,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn trackOf(item: *anyopaque) ?*TrackObject {
    const object = gtk.gtk_list_item_get_item(gtk.cast(gtk.ListItem, item)) orelse return null;
    return @ptrCast(@alignCast(object));
}

fn label(css: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(widget, css);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    return widget;
}

fn durationLabel() *gtk.Widget {
    const duration = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(duration, "numeric");
    gtk.gtk_widget_add_css_class(duration, "queue-duration");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration), 1.0);
    return duration;
}

fn append(box: *gtk.Widget, parts: []const *gtk.Widget) void {
    for (parts) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, box), part);
}

fn heart(self: *App, item: ?*anyopaque) *gtk.Widget {
    const button = feedback.newRowButton(gtk.callback(heartClicked), self);
    gtk.g_object_set_data(button, "orca-list-item", item);
    return button;
}

fn titleLine() *gtk.Widget {
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(line, gtk.true_);
    gtk.gtk_widget_set_valign(line, gtk.ALIGN_CENTER);
    append(line, &.{ label("queue-title"), label("queue-artist") });
    return line;
}

fn showTitleLine(line: *gtk.Widget, track: *TrackObject) void {
    const title = gtk.gtk_widget_get_first_child(line) orelse return;
    const artist = gtk.gtk_widget_get_next_sibling(title) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), track.title().ptr);
    var buffer: [512]u8 = undefined;
    const text = if (track.artist().len == 0) "" else strings.format(&buffer, " — {s}", .{track.artist()});
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, artist), text.ptr);
}

fn showCover(self: *App, cover: *gtk.Widget, track: *TrackObject) void {
    art.show(self, cover, if (track.releaseId()) |release| art.Key.release(release, .thumb) else art.Key.track(track.id(), .thumb));
}

fn setupNow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(row, "queue-row");
    gtk.gtk_widget_add_css_class(row, "queue-now-row");
    const cover = art.newCover(self, art.iconPlaceholder(now_cover_pixels), now_cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "queue-cover");
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    append(labels, &.{ label("queue-now-title"), label("queue-now-subtitle") });
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "circular");
    gtk.gtk_widget_add_css_class(more, "queue-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.g_object_set_data(more, "orca-list-item", item);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(nowMoreClicked), self);
    append(row, &.{ cover, labels, heart(self, item), durationLabel(), more });
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, trackMenu, self);
}

fn bindNow(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const track = trackOf(item.?) orelse return;
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item.?)) orelse return;
    const cover = gtk.gtk_widget_get_first_child(row) orelse return;
    const labels = gtk.gtk_widget_get_next_sibling(cover) orelse return;
    const love = gtk.gtk_widget_get_next_sibling(labels) orelse return;
    const duration = gtk.gtk_widget_get_next_sibling(love) orelse return;
    const title = gtk.gtk_widget_get_first_child(labels) orelse return;
    const subtitle = gtk.gtk_widget_get_next_sibling(title) orelse return;
    var buffer: [1024]u8 = undefined;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, title), track.title().ptr);
    const text = if (track.album().len == 0)
        strings.format(&buffer, "{s}", .{track.artist()})
    else
        strings.format(&buffer, "{s} • {s}", .{ track.artist(), track.album() });
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, subtitle), text.ptr);
    feedback.showRowButton(love, track.feedback());
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, duration), track.durationText(&buffer).ptr);
    showCover(self, cover, track);
}

fn unbindFirstChild(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item.?)) orelse return;
    const cover = gtk.gtk_widget_get_first_child(row) orelse return;
    art.forget(state(data), cover);
}

fn setupNext(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "queue-row");
    gtk.gtk_widget_add_css_class(row, "queue-next-row");
    const handle = gtk.gtk_image_new_from_icon_name("list-drag-handle-symbolic");
    gtk.gtk_widget_add_css_class(handle, "queue-handle");
    gtk.gtk_widget_set_size_request(handle, 16, -1);
    gtk.gtk_widget_set_tooltip_text(handle, "Drag to reorder");
    const number = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_widget_add_css_class(number, "queue-number");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 1.0);
    gtk.gtk_widget_set_size_request(number, 22, -1);
    const cover = art.newCover(self, art.iconPlaceholder(row_cover_pixels), row_cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "queue-cover");
    const remove = gtk.gtk_button_new_from_icon_name("window-close-symbolic");
    gtk.gtk_widget_set_tooltip_text(remove, "Remove from queue");
    gtk.gtk_widget_add_css_class(remove, "flat");
    gtk.gtk_widget_add_css_class(remove, "circular");
    gtk.gtk_widget_add_css_class(remove, "queue-remove");
    gtk.gtk_widget_set_valign(remove, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_focus_on_click(remove, gtk.false_);
    gtk.g_object_set_data(remove, "orca-list-item", item);
    _ = gtk.signalConnect(remove, "clicked", gtk.callback(removeClicked), self);
    append(row, &.{ handle, number, cover, titleLine(), heart(self, item), durationLabel(), remove });
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, nextMenu, self);

    const source = gtk.gtk_drag_source_new();
    gtk.gtk_drag_source_set_actions(source, gtk.ACTION_MOVE);
    _ = gtk.signalConnect(source, "prepare", gtk.callback(dragPrepare), self);
    _ = gtk.signalConnect(source, "drag-begin", gtk.callback(dragBegin), self);
    gtk.gtk_widget_add_controller(row, source);
    const target = gtk.gtk_drop_target_new(gtk.G_TYPE_UINT, gtk.ACTION_MOVE);
    _ = gtk.signalConnect(target, "drop", gtk.callback(dropped), self);
    gtk.gtk_widget_add_controller(row, target);
}

fn bindNext(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const track = trackOf(item.?) orelse return;
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item.?)) orelse return;
    const handle = gtk.gtk_widget_get_first_child(row) orelse return;
    const number = gtk.gtk_widget_get_next_sibling(handle) orelse return;
    const cover = gtk.gtk_widget_get_next_sibling(number) orelse return;
    const line = gtk.gtk_widget_get_next_sibling(cover) orelse return;
    const love = gtk.gtk_widget_get_next_sibling(line) orelse return;
    const duration = gtk.gtk_widget_get_next_sibling(love) orelse return;
    var buffer: [32]u8 = undefined;
    const position = gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item.?));
    const number_text: [:0]const u8 = strings.printZ(&buffer, "{d}", .{position + 1}) catch "";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, number), number_text.ptr);
    showTitleLine(line, track);
    feedback.showRowButton(love, track.feedback());
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, duration), track.durationText(&buffer).ptr);
    showCover(self, cover, track);
}

fn unbindNext(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item.?)) orelse return;
    const handle = gtk.gtk_widget_get_first_child(row) orelse return;
    const number = gtk.gtk_widget_get_next_sibling(handle) orelse return;
    const cover = gtk.gtk_widget_get_next_sibling(number) orelse return;
    art.forget(state(data), cover);
}

fn setupHistory(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "queue-row");
    gtk.gtk_widget_add_css_class(row, "queue-history-row");
    const cover = art.newCover(self, art.iconPlaceholder(row_cover_pixels), row_cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "queue-cover");
    const played = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(played, "numeric");
    gtk.gtk_widget_add_css_class(played, "queue-played");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, played), 1.0);
    append(row, &.{ cover, titleLine(), heart(self, item), played });
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
    gtk.g_object_set_data(row, "orca-list-item", item);
    menu.onSecondaryClick(row, trackMenu, self);
}

fn bindHistory(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const track = trackOf(item.?) orelse return;
    const row = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item.?)) orelse return;
    const cover = gtk.gtk_widget_get_first_child(row) orelse return;
    const line = gtk.gtk_widget_get_next_sibling(cover) orelse return;
    const love = gtk.gtk_widget_get_next_sibling(line) orelse return;
    const played = gtk.gtk_widget_get_next_sibling(love) orelse return;
    showTitleLine(line, track);
    feedback.showRowButton(love, track.feedback());
    const position = gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item.?));
    var buffer: [48]u8 = undefined;
    const text = if (position < self.queue.history_count)
        playedText(&buffer, nowMs(self) - self.queue.history_ended_ms[position])
    else
        "";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, played), text.ptr);
    showCover(self, cover, track);
}

fn nowMs(self: *App) i64 {
    return std.Io.Clock.real.now(self.io).toMilliseconds();
}

fn playedText(buffer: []u8, elapsed_ms: i64) [:0]const u8 {
    const minutes = @divFloor(@max(elapsed_ms, 0), std.time.ms_per_min);
    if (minutes < 1) return "Played just now";
    if (minutes < 60) return strings.format(buffer, "Played {d} min ago", .{@as(u64, @intCast(minutes))});
    const hours = @divFloor(minutes, 60);
    if (hours < 24) return strings.format(buffer, "Played {d} hr ago", .{@as(u64, @intCast(hours))});
    const days: u64 = @intCast(@divFloor(hours, 24));
    return strings.format(buffer, "Played {d} {s} ago", .{ days, if (days == 1) "day" else "days" });
}

fn heartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const item = gtk.g_object_get_data(button.?, "orca-list-item") orelse return;
    const track = trackOf(item) orelse return;
    feedback.toggle(self, .{ .track_id = track.id(), .recording_id = track.recordingId(), .feedback = track.feedback() });
}

fn nextPosition(self: *App, item: *anyopaque) ?u32 {
    const row = gtk.gtk_list_item_get_position(gtk.cast(gtk.ListItem, item));
    if (row >= self.queue.next_count) return null;
    return self.queue.next_positions[row];
}

fn removeAt(self: *App, item: *anyopaque) void {
    self.context.reset(.queue);
    self.context.queue_position = nextPosition(self, item) orelse return;
    menu.remove(self);
}

fn removeClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const item = gtk.g_object_get_data(button.?, "orca-list-item") orelse return;
    removeAt(state(data), item);
}

fn setTrackContext(self: *App, kind: menu.Kind, track: *TrackObject) bool {
    self.context.reset(kind);
    self.context.addTrack(self.allocator, track.id(), track.recordingId(), track.feedback()) catch return false;
    self.context.release_id = track.releaseId();
    self.context.artist_id = track.artistId();
    return true;
}

fn trackMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return;
    const track = trackOf(item) orelse return;
    if (setTrackContext(self, .tracks, track)) menu.popup(self, row, x, y);
}

fn nowMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const item = gtk.g_object_get_data(widget, "orca-list-item") orelse return;
    const track = trackOf(item) orelse return;
    if (!setTrackContext(self, .tracks, track)) return;
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popup(self, widget, x, y);
}

fn nextMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return;
    const track = trackOf(item) orelse return;
    const position = nextPosition(self, item) orelse return;
    if (!setTrackContext(self, .queue, track)) return;
    self.context.queue_position = position;
    menu.popup(self, row, x, y);
}

fn nextActivated(_: ?*anyopaque, row: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (row >= self.queue.next_count) return;
    self.runtime.playerQueueJump(self.player, self.queue.next_positions[row]) catch return;
    self.mpris.notify();
    self.requestTick();
}

fn focusedItem(self: *App) ?*anyopaque {
    const window = self.window orelse return null;
    var widget = gtk.gtk_window_get_focus(window) orelse return null;
    const list = self.queue.next_list orelse return null;
    while (widget != list) {
        if (gtk.g_object_get_data(widget, "orca-list-item")) |item| return item;
        if (gtk.gtk_widget_get_parent(widget) == list) {
            const row = gtk.gtk_widget_get_first_child(widget) orelse return null;
            return gtk.g_object_get_data(row, "orca-list-item");
        }
        widget = gtk.gtk_widget_get_parent(widget) orelse return null;
    }
    return null;
}

fn nextKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    if (keyval != gtk.KEY_Delete and keyval != gtk.KEY_KP_Delete) return gtk.false_;
    if (modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT) != 0) return gtk.false_;
    removeAt(self, focusedItem(self) orelse return gtk.false_);
    return gtk.true_;
}

fn dragPrepare(source: ?*anyopaque, _: f64, _: f64, data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self = state(data);
    const row = menu.gestureWidget(source);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return null;
    const position = nextPosition(self, item) orelse return null;
    var value: gtk.GValue = .{};
    _ = gtk.g_value_init(&value, gtk.G_TYPE_UINT);
    defer gtk.g_value_unset(&value);
    gtk.g_value_set_uint(&value, position);
    return gtk.gdk_content_provider_new_for_value(&value);
}

fn dragBegin(source: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const row = menu.gestureWidget(source);
    const paintable = gtk.gtk_widget_paintable_new(row);
    defer gtk.g_object_unref(paintable);
    gtk.gtk_drag_source_set_icon(gtk.cast(gtk.EventController, source.?), paintable, 24, 22);
}

fn dropped(target: ?*anyopaque, value: *const gtk.GValue, _: f64, _: f64, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const row = menu.gestureWidget(target);
    const item = gtk.g_object_get_data(row, "orca-list-item") orelse return gtk.false_;
    const to = nextPosition(self, item) orelse return gtk.false_;
    move(self, gtk.g_value_get_uint(value), to);
    return gtk.true_;
}

fn move(self: *App, from: u32, to: u32) void {
    self.runtime.playerQueueMove(self.player, from, to) catch |err| self.toast(switch (err) {
        error.QueueEntryInUse => "Can't move a song that's already lined up",
        else => "Could not move that song",
    });
    invalidate(self);
    self.mpris.notify();
    self.requestTick();
}

fn playNextActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const from = self.context.queue_position orelse return;
    const snapshot = self.runtime.playerQueueSnapshot(self.player) catch return;
    const status = self.runtime.playerStatus(self.player) catch return;
    move(self, from, @max(snapshot.decode_position, status.queue_index) + 1);
}

fn playLaterActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const from = self.context.queue_position orelse return;
    const snapshot = self.runtime.playerQueueSnapshot(self.player) catch return;
    if (snapshot.entries == 0) return;
    move(self, from, snapshot.entries - 1);
}

fn saveActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    askSaveName(state(data));
}

fn saveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    askSaveName(state(data));
}

const SaveRequest = struct {
    self: *App,
    entry: *gtk.Widget,
};

pub fn askSaveName(self: *App) void {
    if (self.library == null) return self.toast("No library is open");
    const request = self.allocator.create(SaveRequest) catch return self.toast("Out of memory");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), "Name");
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, entry), gtk.true_);
    request.* = .{ .self = self, .entry = entry };
    const dialog = adw.adw_alert_dialog_new("Save Queue as Playlist", "The playing song and everything up next.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, entry);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "save", "Save");
    adw.adw_alert_dialog_set_response_appearance(alert, "save", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "save");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(saveResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
    _ = gtk.g_idle_add(focusLater, gtk.g_object_ref(entry));
}

fn focusLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const entry = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(entry);
    if (gtk.gtk_widget_get_root(entry) != null) _ = gtk.gtk_widget_grab_focus(entry);
    return gtk.SOURCE_REMOVE;
}

fn saveResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *SaveRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "save")) return;
    const library = self.library orelse return;
    const name = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.entry)));
    const playlist_id = self.runtime.playerSaveQueueAsPlaylist(self.player, library, name) catch |err|
        return self.toast(switch (err) {
            error.QueueEmpty => "Nothing is queued",
            error.PlaylistNameTaken => "A playlist with that name already exists",
            error.InvalidPlaylistName => "A playlist needs a name",
            else => "Could not save the queue",
        });
    playlists.refresh(self);
    playlists.open(self, playlist_id);
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.playerClearQueue(self.player) catch return;
    self.mpris.notify();
    self.requestTick();
}

fn clearHistoryClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.playerClearQueueHistory(self.player) catch return self.toast("Could not clear the history");
    invalidate(self);
    self.requestTick();
}

fn historyToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const shown = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) != 0;
    if (shown == self.queue.history_shown) return;
    self.queue.history_shown = shown;
    showHistoryToggle(self);
    settings.save(self);
}

fn showHistoryToggle(self: *App) void {
    const shown = self.queue.history_shown;
    if (self.queue.history_toggle) |toggle| {
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, toggle), if (shown) "Hide" else "Show");
        gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle), if (shown) gtk.true_ else gtk.false_);
    }
    if (self.queue.history_list) |list| gtk.gtk_widget_set_visible(list, if (shown) gtk.true_ else gtk.false_);
}

fn newList(
    self: *App,
    store: *gtk.ListStore,
    css: [*:0]const u8,
    setup: gtk.GCallback,
    bind: gtk.GCallback,
    unbind: gtk.GCallback,
) *gtk.Widget {
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", setup, self);
    _ = gtk.signalConnect(factory, "bind", bind, self);
    _ = gtk.signalConnect(factory, "unbind", unbind, self);
    const list = gtk.gtk_list_view_new(
        gtk.gtk_no_selection_new(gtk.cast(gtk.ListModel, gtk.g_object_ref(store))),
        factory,
    );
    gtk.gtk_widget_add_css_class(list, "queue-list");
    gtk.gtk_widget_add_css_class(list, css);
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, list), gtk.LIST_TAB_ITEM);
    return list;
}

fn heading(text: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, "queue-heading");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    return widget;
}

fn headingRow(text: [*:0]const u8) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "queue-heading-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), heading(text));
    return row;
}

fn section(row: *gtk.Widget, list: *gtk.Widget) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, "queue-section");
    append(box, &.{ row, list });
    return box;
}

fn smallButton(text: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "queue-section-button");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(button, "clicked", handler, self);
    return button;
}

fn addAction(group: *gtk.GSimpleActionGroup, name: [*:0]const u8, handler: gtk.GCallback, self: *App) void {
    const action = gtk.g_simple_action_new(name, null).?;
    _ = gtk.signalConnect(action, "activate", handler, self);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
}

pub fn build(self: *App) *gtk.Widget {
    const page = &self.queue;
    const now_store = gtk.g_list_store_new(track_model.getType()).?;
    const next_store = gtk.g_list_store_new(track_model.getType()).?;
    const history_store = gtk.g_list_store_new(track_model.getType()).?;
    page.now_store = now_store;
    page.next_store = next_store;
    page.history_store = history_store;

    const now_list = newList(self, now_store, "queue-now-list", gtk.callback(setupNow), gtk.callback(bindNow), gtk.callback(unbindFirstChild));
    const now_section = section(headingRow("Now Playing"), now_list);
    page.now_section = now_section;

    const next_list = newList(self, next_store, "queue-next-list", gtk.callback(setupNext), gtk.callback(bindNext), gtk.callback(unbindNext));
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, next_list), gtk.true_);
    _ = gtk.signalConnect(next_list, "activate", gtk.callback(nextActivated), self);
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(nextKeyPressed), self);
    gtk.gtk_widget_add_controller(next_list, keys);
    page.next_list = next_list;
    const next_heading = headingRow("Up Next");
    const next_meta = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(next_meta, "queue-heading-meta");
    gtk.gtk_widget_add_css_class(next_meta, "numeric");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, next_meta), gtk.ELLIPSIZE_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, next_heading), next_meta);
    page.next_meta = gtk.cast(gtk.Label, next_meta);
    const next_section = section(next_heading, next_list);
    page.next_section = next_section;

    const history_list = newList(self, history_store, "queue-history-list", gtk.callback(setupHistory), gtk.callback(bindHistory), gtk.callback(unbindFirstChild));
    page.history_list = history_list;
    const history_heading = headingRow("Previously Played");
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const toggle = gtk.gtk_toggle_button_new();
    gtk.gtk_widget_add_css_class(toggle, "flat");
    gtk.gtk_widget_add_css_class(toggle, "queue-section-button");
    gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(toggle, "Show what played before");
    page.history_toggle = toggle;
    append(history_heading, &.{ spacer, toggle, smallButton("Clear History", gtk.callback(clearHistoryClicked), self) });
    const history_section = section(history_heading, history_list);
    page.history_section = history_section;
    showHistoryToggle(self);
    _ = gtk.signalConnect(toggle, "toggled", gtk.callback(historyToggled), self);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "queue-page");
    append(column, &.{ now_section, next_section, history_section });
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);

    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "view-list-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "Nothing queued");
    adw.adw_status_page_set_description(
        gtk.cast(adw.StatusPage, empty),
        "Play a song, or select several and press Enter.",
    );

    const body = gtk.gtk_stack_new();
    page.body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(page.body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(page.body.?, empty, "empty");
    gtk.gtk_stack_set_visible_child_name(page.body.?, "empty");

    const title = page_ui.title("Queue");
    page.meta = title.meta;
    const save = gtk.gtk_button_new_with_label("Save as Playlist…");
    gtk.gtk_widget_add_css_class(save, "queue-header-button");
    _ = gtk.signalConnect(save, "clicked", gtk.callback(saveClicked), self);
    title.add(save);
    const clear = gtk.gtk_button_new_with_label("Clear");
    gtk.gtk_widget_set_tooltip_text(clear, "Clear the queue");
    gtk.gtk_widget_add_css_class(clear, "queue-header-button");
    _ = gtk.signalConnect(clear, "clicked", gtk.callback(clearClicked), self);
    title.add(clear);

    const view = page_ui.withTitle(title, body);

    const group = gtk.g_simple_action_group_new();
    addAction(group, "play-next", gtk.callback(playNextActivated), self);
    addAction(group, "play-later", gtk.callback(playLaterActivated), self);
    addAction(group, "save", gtk.callback(saveActivated), self);
    gtk.gtk_widget_insert_action_group(view, "queue", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    return view;
}

fn replace(self: *App, store: *gtk.ListStore, items: []const liborca.TrackSummary) void {
    gtk.g_list_store_remove_all(store);
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    for (items) |item| {
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
}

fn visible(widget: ?*gtk.Widget, shown: bool) void {
    if (widget) |value| gtk.gtk_widget_set_visible(value, if (shown) gtk.true_ else gtk.false_);
}

fn durationText(buffer: []u8, count: usize, total_ms: i64) [:0]const u8 {
    var duration_buffer: [32]u8 = undefined;
    const songs: []const u8 = if (count == 1) "song" else "songs";
    return strings.format(buffer, "{d} {s} • {s}", .{ count, songs, strings.totalDuration(&duration_buffer, total_ms) });
}

/// Rebuilds the page from the engine. Bounded by one page of the queue, which
/// is as much of one as anyone scrolls through, and the history's capacity.
fn refill(self: *App, status: liborca.PlayerStatus) void {
    const page = &self.queue;
    const now_store = page.now_store orelse return;
    const next_store = page.next_store orelse return;
    const history_store = page.history_store orelse return;

    var refs: [app.page_size + 1]liborca.TrackRef = undefined;
    const ref_count = self.runtime.playerQueuePage(self.player, status.queue_index, &refs) catch 0;
    var tracks: ?liborca.TrackPage = if (ref_count == 0)
        null
    else
        self.runtime.playerQueueTracks(self.player, self.allocator, status.queue_index, @intCast(ref_count)) catch null;
    defer if (tracks) |*value| value.deinit();
    const summaries: []const liborca.TrackSummary = if (tracks) |value| value.items else &.{};

    var now: []const liborca.TrackSummary = &.{};
    var next_start: usize = 0;
    page.next_count = 0;
    var next_ms: i64 = 0;
    var cursor: usize = 0;
    for (refs[0..ref_count], 0..) |ref, offset| {
        if (cursor >= summaries.len) break;
        if (summaries[cursor].id != ref.track_id) continue;
        if (offset == 0) {
            now = summaries[0..1];
            next_start = 1;
        } else {
            page.next_positions[page.next_count] = status.queue_index + @as(u32, @intCast(offset));
            page.next_count += 1;
            next_ms += summaries[cursor].duration_ms orelse 0;
        }
        cursor += 1;
    }
    if (status.track_id == null) now = &.{};
    replace(self, now_store, now);
    replace(self, next_store, summaries[next_start .. next_start + page.next_count]);

    var history: [history_capacity]liborca.QueueHistoryEntry = undefined;
    const history_read = self.runtime.playerQueueHistory(self.player, 0, &history) catch 0;
    var history_tracks: ?liborca.TrackPage = if (history_read == 0)
        null
    else
        self.runtime.playerQueueHistoryTracks(self.player, self.allocator, 0, @intCast(history_read)) catch null;
    defer if (history_tracks) |*value| value.deinit();
    const played: []const liborca.TrackSummary = if (history_tracks) |value| value.items else &.{};
    page.history_count = 0;
    for (history[0..history_read]) |entry| {
        if (page.history_count >= played.len) break;
        if (played[page.history_count].id != entry.track.track_id) continue;
        page.history_ended_ms[page.history_count] = entry.ended_at_ms;
        page.history_count += 1;
    }
    replace(self, history_store, played[0..page.history_count]);
    page.shown_minute = @divFloor(nowMs(self), std.time.ms_per_min);

    visible(page.now_section, now.len != 0);
    visible(page.next_section, page.next_count != 0);
    visible(page.history_section, page.history_count != 0);
    const anything = now.len != 0 or page.next_count != 0 or page.history_count != 0;
    if (page.body) |body| gtk.gtk_stack_set_visible_child_name(body, if (anything) "list" else "empty");

    var buffer: [96]u8 = undefined;
    if (page.next_meta) |meta| {
        const text = if (page.next_count == 0) "" else durationText(&buffer, page.next_count, next_ms);
        gtk.gtk_label_set_text(meta, text.ptr);
    }
    if (page.meta) |meta| {
        var total_ms = next_ms;
        if (now.len != 0) total_ms += now[0].duration_ms orelse 0;
        const upcoming = status.queue_length -| status.queue_index;
        const songs: []const u8 = if (status.queue_length == 1) "song" else "songs";
        const subtitle = if (status.queue_length == 0)
            ""
        else if (status.queue_index != 0 or upcoming > ref_count)
            strings.format(&buffer, "{d} {s}", .{ status.queue_length, songs })
        else
            durationText(&buffer, status.queue_length, total_ms);
        gtk.gtk_label_set_text(meta, subtitle.ptr);
    }
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    for ([_]?*gtk.ListStore{ self.queue.now_store, self.queue.next_store, self.queue.history_store }) |store|
        if (store) |value| {
            _ = feedback.replaceRows(value, changed, change);
        };
}

/// Forces the next tick to rebuild the page, for when it becomes visible.
pub fn invalidate(self: *App) void {
    self.queue.shown_length = std.math.maxInt(u32);
    self.queue.shown_index = std.math.maxInt(u32);
    self.queue.shown_shuffle = null;
    self.queue.shown_serial = std.math.maxInt(u32);
}

pub fn tick(self: *App) void {
    const status = self.runtime.playerStatus(self.player) catch return;
    if (self.queue_count) |count_label| {
        var buffer: [16]u8 = undefined;
        const text = if (status.queue_length == 0)
            ""
        else
            strings.printZ(&buffer, "{d}", .{status.queue_length}) catch "";
        gtk.gtk_label_set_text(count_label, text.ptr);
    }
    const page = &self.queue;
    const stale_times = self.queue_visible and page.history_shown and page.history_count != 0 and
        @divFloor(nowMs(self), std.time.ms_per_min) != page.shown_minute;
    if (status.queue_length == page.shown_length and
        status.queue_index == page.shown_index and
        status.shuffle == page.shown_shuffle and
        status.entry_serial == page.shown_serial and
        !stale_times) return;
    page.shown_length = status.queue_length;
    page.shown_index = status.queue_index;
    page.shown_shuffle = status.shuffle;
    page.shown_serial = status.entry_serial;
    if (self.queue_visible) refill(self, status);
    nowplaying.refreshUpNext(self);
}
