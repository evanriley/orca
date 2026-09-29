//! The Now Playing page: the audible track's cover, large, on a wash of its
//! own colour, with what comes next.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const mpris = @import("mpris.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");

const App = app.App;

const cover_pixels: c_int = 400;
const up_next_rows = 5;

var up_next_targets: [up_next_rows]feedback.Target = undefined;
var up_next_hearts: [up_next_rows]*gtk.Widget = undefined;
var up_next_shown: usize = 0;

pub fn build(self: *App) *gtk.Widget {
    const cover = art.newCover(self, art.iconPlaceholder(cover_pixels), cover_pixels);
    self.now_cover = cover;
    gtk.gtk_widget_add_css_class(cover, "now-cover");
    menu.onSecondaryClick(cover, menu.playingMenu, self);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const title = gtk.gtk_label_new("Nothing playing");
    const artist = gtk.gtk_label_new("");
    const album = gtk.gtk_label_new("");
    self.now_title = gtk.cast(gtk.Label, title);
    self.now_artist = gtk.cast(gtk.Label, artist);
    self.now_album = gtk.cast(gtk.Label, album);
    gtk.gtk_widget_add_css_class(title, "now-page-title");
    menu.onSecondaryClick(title, menu.playingMenu, self);
    gtk.gtk_widget_add_css_class(artist, "now-page-artist");
    gtk.gtk_widget_add_css_class(album, "now-page-album");
    for ([_]*gtk.Widget{ title, artist, album }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
        gtk.gtk_label_set_lines(gtk.cast(gtk.Label, label), 3);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    }
    const title_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_row), feedback.newNowPlayingButton(self, gtk.callback(loveClicked)));
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), title_row);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), artist);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), album);

    const up_next = gtk.gtk_label_new("Up next");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, up_next), 0.0);
    gtk.gtk_widget_add_css_class(up_next, "now-up-next");
    gtk.gtk_widget_set_margin_top(up_next, 28);
    self.now_up_next_heading = up_next;
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), up_next);
    const next = gtk.gtk_list_box_new();
    self.now_up_next = gtk.cast(gtk.ListBox, next);
    gtk.gtk_list_box_set_selection_mode(self.now_up_next.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(next, "now-up-next-list");
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), next);

    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 48);
    gtk.gtk_widget_set_valign(row, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(row, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), cover);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), facts);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 1000);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), row);
    gtk.gtk_widget_set_margin_start(clamp, 32);
    gtk.gtk_widget_set_margin_end(clamp, 32);

    const header = adw.adw_header_bar_new();
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), adw.adw_window_title_new("", ""));
    const view = adw.adw_toolbar_view_new();
    gtk.gtk_widget_add_css_class(view, "now-playing-page");
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), clamp);

    const provider = gtk.gtk_css_provider_new();
    self.tint_provider = provider;
    if (gtk.gdk_display_get_default()) |display| gtk.gtk_style_context_add_provider_for_display(
        display,
        provider,
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    self.art.on_ready = coverReady;
    return view;
}

fn loveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    feedback.toggleLoveOfPlaying(@ptrCast(@alignCast(data.?)));
}

fn upNextHeartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-position"));
    if (marked == 0 or marked > up_next_shown) return;
    feedback.toggle(self, up_next_targets[marked - 1]);
}

pub fn repaintFeedback(changed: *const feedback.Recordings, value: liborca.Feedback) void {
    for (up_next_targets[0..up_next_shown], up_next_hearts[0..up_next_shown]) |*target, heart| {
        const recording = target.recording_id orelse continue;
        if (!changed.contains(recording)) continue;
        target.feedback = value;
        feedback.showRowButton(heart, value);
    }
}

fn setText(label: ?*gtk.Label, text: []const u8) void {
    const target = label orelse return;
    var buffer: [512]u8 = undefined;
    const terminated = strings.printZ(&buffer, "{s}", .{text}) catch "";
    gtk.gtk_label_set_text(target, terminated.ptr);
}

/// Called when the audible track changes.
pub fn update(self: *App, track_id: ?i64) void {
    const cover = self.now_cover orelse return;
    const id = track_id orelse {
        setText(self.now_title, "Nothing playing");
        setText(self.now_artist, "");
        setText(self.now_album, "");
        art.forget(self, cover);
        const stack = gtk.cast(gtk.Stack, cover);
        gtk.gtk_stack_set_visible_child_name(stack, "placeholder");
        applyTint(self, null);
        refreshUpNext(self);
        return;
    };
    if (mpris.nowPlaying(self.runtime, self.player)) |current| {
        defer current.deinit();
        const summary = current.summary;
        setText(self.now_title, if (summary.title.len != 0) summary.title else "Unknown title");
        setText(self.now_artist, if (summary.artist.len != 0) summary.artist else summary.album_artist);
        setText(self.now_album, summary.album);
    }
    const key = art.Key.track(id, .large);
    art.show(self, cover, key);
    applyTint(self, art.tintOf(self, key));
    refreshUpNext(self);
}

fn coverReady(self: *App, key: art.Key) void {
    const status = self.runtime.playerStatus(self.player) catch return;
    const id = status.track_id orelse return;
    if (!std.meta.eql(key, art.Key.track(id, .large))) return;
    applyTint(self, art.tintOf(self, key));
}

/// Washes the page in the cover's colour, softened so text stays readable in
/// light and dark themes alike.
fn applyTint(self: *App, tint: ?art.Tint) void {
    const provider = self.tint_provider orelse return;
    const colour = tint orelse {
        gtk.gtk_css_provider_load_from_string(provider, ".now-playing-page { background-image: none; }");
        return;
    };
    var buffer: [320]u8 = undefined;
    const css = strings.printZ(
        &buffer,
        ".now-playing-page {{ background-image: linear-gradient(160deg, rgb({d} {d} {d} / 0.55), rgb({d} {d} {d} / 0.18) 55%, transparent); }}",
        .{ colour.red, colour.green, colour.blue, colour.red, colour.green, colour.blue },
    ) catch return;
    gtk.gtk_css_provider_load_from_string(provider, css.ptr);
}

pub fn refreshUpNext(self: *App) void {
    const list = self.now_up_next orelse return;
    gtk.gtk_list_box_remove_all(list);
    up_next_shown = 0;
    const status = self.runtime.playerStatus(self.player) catch return;
    const start = status.queue_index + 1;
    var shown: usize = 0;
    if (status.queue_length > start) {
        if (self.runtime.playerQueueTracks(self.player, self.allocator, start, up_next_rows)) |page_value| {
            var page = page_value;
            defer page.deinit();
            for (page.items) |item| {
                var buffer: [640]u8 = undefined;
                const artist = if (item.artist.len != 0) item.artist else item.album_artist;
                const text = if (artist.len != 0)
                    strings.printZ(&buffer, "{s}  ·  {s}", .{ item.title, artist }) catch continue
                else
                    strings.printZ(&buffer, "{s}", .{item.title}) catch continue;
                const label = gtk.gtk_label_new(text.ptr);
                gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
                gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
                gtk.gtk_widget_add_css_class(label, "now-up-next-row");
                const heart = feedback.newRowButton(gtk.callback(upNextHeartClicked), self);
                feedback.showRowButton(heart, item.feedback);
                gtk.g_object_set_data(heart, "orca-position", @ptrFromInt(shown + 1));
                const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
                gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
                const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
                gtk.gtk_box_append(gtk.cast(gtk.Box, row), label);
                gtk.gtk_box_append(gtk.cast(gtk.Box, row), heart);
                gtk.gtk_box_append(gtk.cast(gtk.Box, row), spacer);
                gtk.gtk_list_box_append(list, row);
                up_next_targets[shown] = .{ .track_id = item.id, .recording_id = item.recording_id, .feedback = item.feedback };
                up_next_hearts[shown] = heart;
                shown += 1;
            }
        } else |_| {}
    }
    up_next_shown = shown;
    if (self.now_up_next_heading) |heading| gtk.gtk_widget_set_visible(heading, if (shown != 0) gtk.true_ else gtk.false_);
}
