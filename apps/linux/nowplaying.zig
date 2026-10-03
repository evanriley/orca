//! The Now Playing page: the audible track's cover over a blurred backdrop of
//! itself, the transport, the lyric lines around the one being heard, and
//! beside it what comes next and the track's facts.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const albums = @import("albums.zig");
const mpris = @import("mpris.zig");
const menu = @import("menu.zig");
const feedback = @import("feedback.zig");
const lyrics = @import("lyrics.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");
const track_model = @import("track_model.zig");
const page_ui = @import("page.zig");
const inspector = @import("details.zig");
const signal_path = @import("signal_path.zig");

const App = app.App;

const cover_pixels: c_int = 380;
const up_next_rows = 5;
const panel_width: c_int = 340;
const info_key_width: c_int = 110;
const lyrics_width: c_int = 640;

const InfoRow = enum { title, artist, album, date, genre, track, disc, format };

pub const State = struct {
    content: ?*gtk.Stack = null,
    host: ?*gtk.Widget = null,
    cover: ?*gtk.Stack = null,
    picture: ?*gtk.Widget = null,
    title: ?*gtk.Label = null,
    artist: ?*gtk.Label = null,
    album: ?*gtk.Label = null,
    panel: ?*gtk.Widget = null,
    up_next: ?*gtk.ListBox = null,
    up_next_empty: ?*gtk.Widget = null,
    up_next_start: u32 = 0,
    info_rows: std.EnumArray(InfoRow, ?*gtk.Widget) = .initFill(null),
    info_values: std.EnumArray(InfoRow, ?*gtk.Label) = .initFill(null),
    artist_id: ?i64 = null,
    release_id: ?i64 = null,
};

var up_next_targets: [up_next_rows]feedback.Target = undefined;
var up_next_hearts: [up_next_rows]*gtk.Widget = undefined;
var up_next_shown: usize = 0;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    return widget;
}

fn append(box: *gtk.Widget, child: *gtk.Widget) void {
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

pub fn build(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const host = art.newCover(self, art.iconPlaceholder(cover_pixels), cover_pixels);
    gtk.gtk_widget_set_visible(host, gtk.false_);
    page.host = host;

    const content = gtk.gtk_stack_new();
    page.content = gtk.cast(gtk.Stack, content);
    gtk.gtk_stack_set_transition_type(page.content.?, gtk.STACK_TRANSITION_CROSSFADE);
    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "audio-x-generic-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "Nothing playing");
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, empty), "Pick an album or press Play");
    gtk.gtk_widget_add_css_class(empty, "now-empty");
    gtk.gtk_widget_set_can_focus(empty, gtk.false_);
    _ = gtk.gtk_stack_add_named(page.content.?, empty, "empty");

    const playing = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    append(playing, buildCentre(self));
    append(playing, buildPanel(self));
    append(playing, host);
    _ = gtk.gtk_stack_add_named(page.content.?, playing, "playing");
    gtk.gtk_stack_set_visible_child_name(page.content.?, "empty");

    const layers = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), albums.newBackdropLayers(host));
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), content);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), content, gtk.true_);

    const header = page_ui.header(self);
    const view = adw.adw_toolbar_view_new();
    gtk.gtk_widget_add_css_class(view, "now-playing-page");
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header.bar);
    adw.adw_toolbar_view_set_extend_content_to_top_edge(gtk.cast(adw.ToolbarView, view), gtk.true_);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), inspector.besideContent(self, header, layers, .playing).widget);
    placePanel(self);
    return view;
}

fn buildCentre(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "now-centre");
    gtk.gtk_widget_set_hexpand(column, gtk.true_);

    const eyebrow = label("Now Playing", "now-eyebrow");
    gtk.gtk_widget_set_halign(eyebrow, gtk.ALIGN_START);
    append(column, eyebrow);
    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    gtk.gtk_widget_set_valign(body, gtk.ALIGN_CENTER);
    append(column, body);

    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, picture), gtk.CONTENT_FIT_COVER);
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, picture), gtk.true_);
    page.picture = picture;
    const placeholder = art.iconPlaceholder(96);
    const cover = gtk.gtk_stack_new();
    page.cover = gtk.cast(gtk.Stack, cover);
    gtk.gtk_widget_add_css_class(cover, "cover");
    gtk.gtk_widget_add_css_class(cover, "now-cover");
    gtk.gtk_widget_set_overflow(cover, gtk.OVERFLOW_HIDDEN);
    _ = gtk.gtk_stack_add_named(page.cover.?, placeholder, "placeholder");
    _ = gtk.gtk_stack_add_named(page.cover.?, picture, "art");
    gtk.gtk_stack_set_transition_type(page.cover.?, gtk.STACK_TRANSITION_CROSSFADE);
    menu.onSecondaryClick(cover, menu.playingMenu, self);
    if (gtk.gtk_stack_get_child_by_name(gtk.cast(gtk.Stack, page.host.?), "art")) |image| {
        _ = gtk.signalConnect(image, "notify::paintable", gtk.callback(coverPainted), self);
    }
    const frame = gtk.gtk_aspect_frame_new(0.5, 0.5, 1.0, gtk.false_);
    gtk.gtk_aspect_frame_set_child(gtk.cast(gtk.AspectFrame, frame), cover);
    const cover_clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, cover_clamp), cover_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, cover_clamp), cover_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, cover_clamp), frame);
    gtk.gtk_widget_set_margin_top(cover_clamp, 12);
    gtk.gtk_widget_set_margin_bottom(cover_clamp, 24);
    append(body, cover_clamp);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    const title = label("", "display-hero");
    gtk.gtk_widget_add_css_class(title, "now-title-hero");
    page.title = gtk.cast(gtk.Label, title);
    gtk.gtk_label_set_justify(page.title.?, gtk.JUSTIFY_CENTER);
    gtk.gtk_label_set_wrap(page.title.?, gtk.true_);
    gtk.gtk_label_set_lines(page.title.?, 2);
    gtk.gtk_label_set_ellipsize(page.title.?, gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(page.title.?, 28);
    menu.onSecondaryClick(title, menu.playingMenu, self);
    gtk.gtk_widget_set_cursor_from_name(title, "pointer");
    const title_click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(title_click, "released", gtk.callback(titleClicked), self);
    gtk.gtk_widget_add_controller(title, title_click);
    append(facts, title);
    page.artist = linkLabel(facts, "now-artist", artistClicked, self);
    page.album = linkLabel(facts, "now-album", albumClicked, self);
    letterSpace(gtk.cast(gtk.Widget, page.album.?), 1.4);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(actions, "now-actions");
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_CENTER);
    append(actions, feedback.newNowPlayingButton(self, gtk.callback(loveClicked)));
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "circular");
    gtk.gtk_widget_add_css_class(more, "now-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    append(actions, more);
    append(facts, actions);
    append(body, facts);

    const seek = transport.newSeek(self, .now_playing);
    gtk.gtk_widget_add_css_class(seek, "now-seek");
    const seek_clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, seek_clamp), 560);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, seek_clamp), seek);
    append(body, seek_clamp);

    const buttons = transport.newButtons(self, .now_playing);
    gtk.gtk_widget_add_css_class(buttons, "now-transport");
    gtk.gtk_widget_set_halign(buttons, gtk.ALIGN_CENTER);
    append(body, buttons);

    append(body, buildLyrics(self));
    return column;
}

/// The slot stays mapped while the page is shown, so that `lyrics.zig` looks
/// the Track's lyrics up; only the lines inside it are hidden without lyrics.
fn buildLyrics(self: *App) *gtk.Widget {
    const lines = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_add_css_class(lines, "now-lyrics");
    gtk.gtk_widget_set_tooltip_text(lines, "Show Lyrics");
    gtk.gtk_widget_set_cursor_from_name(lines, "pointer");
    const click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(click, "released", gtk.callback(lyricsClicked), self);
    gtk.gtk_widget_add_controller(lines, click);
    var labels: [3]*gtk.Widget = undefined;
    for (&labels, [_][*:0]const u8{ "now-lyric-previous", "now-lyric-current", "now-lyric-next" }) |*line, class| {
        line.* = label("", "now-lyric");
        gtk.gtk_widget_add_css_class(line.*, class);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, line.*), gtk.ELLIPSIZE_END);
        append(lines, line.*);
    }
    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), lyrics_width);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), lines);
    const slot = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(slot, clamp);
    lyrics.watchQuote(self, slot, lines, labels);
    return slot;
}

fn linkLabel(parent: *gtk.Widget, class: [*:0]const u8, handler: anytype, self: *App) *gtk.Label {
    const text = gtk.gtk_label_new("");
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), text);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "now-link");
    gtk.gtk_widget_add_css_class(button, class);
    gtk.gtk_widget_set_halign(button, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(handler), self);
    append(parent, button);
    return gtk.cast(gtk.Label, text);
}

fn buildPanel(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const panel = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(panel, "now-panel");

    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "now-panel-heading");
    const up_next = label("Up Next", "now-panel-title");
    gtk.gtk_widget_set_hexpand(up_next, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, up_next), 0.0);
    append(heading, up_next);
    const clear = gtk.gtk_button_new_with_label("Clear");
    gtk.gtk_widget_add_css_class(clear, "flat");
    gtk.gtk_widget_add_css_class(clear, "now-panel-action");
    _ = gtk.signalConnect(clear, "clicked", gtk.callback(clearClicked), self);
    append(heading, clear);
    append(panel, heading);

    const list = gtk.gtk_list_box_new();
    page.up_next = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(page.up_next.?, gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_activate_on_single_click(page.up_next.?, gtk.false_);
    gtk.gtk_widget_add_css_class(list, "now-up-next-list");
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(upNextActivated), self);
    append(panel, list);
    const nothing = label("Nothing queued after this song", "now-up-next-empty");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, nothing), 0.0);
    page.up_next_empty = nothing;
    append(panel, nothing);

    const full_label = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_set_halign(full_label, gtk.ALIGN_CENTER);
    append(full_label, gtk.gtk_label_new("View Full Queue"));
    append(full_label, gtk.gtk_image_new_from_icon_name("go-next-symbolic"));
    const full = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, full), full_label);
    gtk.gtk_widget_add_css_class(full, "flat");
    gtk.gtk_widget_add_css_class(full, "now-full-queue");
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, full), "app.show-queue");
    append(panel, full);

    const info_heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(info_heading, "now-info-title");
    const info_title = label("Track Info", "now-panel-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, info_title), 0.0);
    gtk.gtk_widget_set_hexpand(info_title, gtk.true_);
    append(info_heading, info_title);
    const info_more = gtk.gtk_button_new_from_icon_name("view-more-horizontal-symbolic");
    gtk.gtk_widget_add_css_class(info_more, "flat");
    gtk.gtk_widget_add_css_class(info_more, "now-panel-action");
    gtk.gtk_widget_set_tooltip_text(info_more, "Track Inspector");
    _ = gtk.signalConnect(info_more, "clicked", gtk.callback(inspectorClicked), self);
    append(info_heading, info_more);
    append(panel, info_heading);
    const names = std.EnumArray(InfoRow, [*:0]const u8).init(.{
        .title = "Title",
        .artist = "Artist",
        .album = "Album",
        .date = "Date",
        .genre = "Genre",
        .track = "Track number",
        .disc = "Disc number",
        .format = "Format",
    });
    for (std.enums.values(InfoRow)) |row| {
        const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_add_css_class(line, "now-info-row");
        const key = label(names.get(row), "now-info-key");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, key), 0.0);
        gtk.gtk_widget_set_size_request(key, info_key_width, -1);
        const value = label("", "now-info-value");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, value), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_set_hexpand(value, gtk.true_);
        append(line, key);
        append(line, value);
        append(panel, line);
        page.info_rows.set(row, line);
        page.info_values.set(row, gtk.cast(gtk.Label, value));
    }

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), panel);
    gtk.gtk_widget_set_size_request(scroller, panel_width, -1);
    gtk.gtk_widget_set_hexpand(scroller, gtk.false_);
    gtk.gtk_widget_set_focusable(scroller, gtk.false_);
    gtk.gtk_widget_add_css_class(scroller, "now-panel-scroller");
    page.panel = scroller;
    return scroller;
}

pub fn placePanel(self: *App) void {
    const panel = self.now_playing.panel orelse return;
    const shown = !self.header_compact and inspector.shownMode(self) == .hidden;
    gtk.gtk_widget_set_visible(panel, boolean(shown));
}

fn coverPainted(image: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = &state(data).now_playing;
    const paintable = gtk.gtk_image_get_paintable(gtk.cast(gtk.Image, image.?));
    gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, page.picture.?), paintable);
    gtk.gtk_stack_set_visible_child_name(page.cover.?, if (paintable != null) "art" else "placeholder");
}

fn loveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    feedback.toggleLoveOfPlaying(state(data));
}

fn moreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const current = mpris.nowPlaying(self.runtime, self.player) orelse return;
    defer current.deinit();
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, current.summary.id, current.summary.recording_id, current.summary.feedback) catch return;
    self.context.release_id = current.summary.release_id;
    self.context.artist_id = current.summary.artist_id;
    albums.popupBelow(self, gtk.cast(gtk.Widget, button.?));
}

fn titleClicked(_: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    window.showAlbum(self, self.now_playing.release_id orelse return);
}

fn lyricsClicked(_: ?*anyopaque, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    inspector.showSidebar(state(data), .lyrics);
}

fn inspectorClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    inspector.showSidebar(state(data), .details);
}

fn artistClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    window.showArtist(self, self.now_playing.artist_id orelse return);
}

fn albumClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    window.showAlbum(self, self.now_playing.release_id orelse return);
}

fn clearClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.playerClearQueue(self.player) catch return;
    self.mpris.notify();
    self.requestTick();
}

fn upNextActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row.?));
    if (index < 0) return;
    const position = self.now_playing.up_next_start + @as(u32, @intCast(index));
    self.runtime.playerQueueJump(self.player, position) catch return;
    self.mpris.notify();
    self.requestTick();
}

fn upNextHeartClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-position"));
    if (marked == 0 or marked > up_next_shown) return;
    feedback.toggle(state(data), up_next_targets[marked - 1]);
}

pub fn repaint(changed: *const feedback.Recordings, change: track_model.Change) void {
    const value = switch (change) {
        .feedback => |value| value,
        .rating => return,
    };
    for (up_next_targets[0..up_next_shown], up_next_hearts[0..up_next_shown]) |*target, heart| {
        const recording = target.recording_id orelse continue;
        if (!changed.contains(recording)) continue;
        target.feedback = value;
        feedback.showRowButton(heart, value);
    }
}

fn setText(target: ?*gtk.Label, text: []const u8) void {
    var buffer: [512]u8 = undefined;
    gtk.gtk_label_set_text(target orelse return, strings.terminated(&buffer, text).ptr);
}

fn letterSpace(target: *gtk.Widget, pixels: f32) void {
    const attributes = gtk.pango_attr_list_new();
    defer gtk.pango_attr_list_unref(attributes);
    gtk.pango_attr_list_insert(attributes, gtk.pango_attr_letter_spacing_new(@intFromFloat(pixels * 1024)));
    gtk.gtk_label_set_attributes(gtk.cast(gtk.Label, target), attributes);
}

fn setUppercase(target: *gtk.Label, text: []const u8) void {
    const upper = gtk.g_utf8_strup(text.ptr, @intCast(text.len)) orelse return gtk.gtk_label_set_text(target, "");
    defer gtk.g_free(upper);
    gtk.gtk_label_set_text(target, upper);
}

fn setInfo(page: *State, row: InfoRow, text: []const u8) void {
    setText(page.info_values.get(row), text);
    if (page.info_rows.get(row)) |line| gtk.gtk_widget_set_visible(line, boolean(text.len != 0));
}

/// Called when the audible track changes.
pub fn update(self: *App, track_id: ?i64) void {
    const page = &self.now_playing;
    const content = page.content orelse return;
    const host = page.host orelse return;
    const id = track_id orelse {
        page.artist_id = null;
        page.release_id = null;
        art.clear(self, host);
        gtk.gtk_stack_set_visible_child_name(content, "empty");
        refreshUpNext(self);
        return;
    };
    gtk.gtk_stack_set_visible_child_name(content, "playing");
    if (mpris.nowPlaying(self.runtime, self.player)) |current| {
        defer current.deinit();
        showFacts(self, current.summary);
    }
    art.show(self, host, art.Key.track(id, .large));
    refreshUpNext(self);
}

fn showFacts(self: *App, summary: liborca.TrackSummary) void {
    const page = &self.now_playing;
    page.artist_id = summary.artist_id;
    page.release_id = summary.release_id;
    const artist = if (summary.artist.len != 0) summary.artist else summary.album_artist;
    setText(page.title, if (summary.title.len != 0) summary.title else "Unknown title");
    setText(page.artist, artist);

    const details = if (self.library) |library| (self.runtime.libraryTrackDetails(library, summary.id) catch null) else null;
    defer if (details) |value| value.deinit();
    const date: []const u8 = if (details) |value| value.date orelse "" else "";
    const year = date[0..@min(date.len, 4)];
    var buffer: [512]u8 = undefined;
    const album_line = if (summary.album.len != 0 and year.len != 0)
        strings.format(&buffer, "{s} · {s}", .{ summary.album, year })
    else if (summary.album.len != 0) summary.album else year;
    setUppercase(page.album.?, album_line);

    setInfo(page, .title, summary.title);
    setInfo(page, .artist, artist);
    setInfo(page, .album, summary.album);
    setInfo(page, .date, date);
    var genre_buffer: [512]u8 = undefined;
    setInfo(page, .genre, if (details) |value| inspector.genresText(&genre_buffer, value.genres) orelse "" else "");
    var number_buffer: [48]u8 = undefined;
    const track_total = if (details) |value| value.track_total else null;
    setInfo(page, .track, ofText(&number_buffer, summary.track_number, track_total));
    const disc_total = if (details) |value| value.disc_total orelse 0 else 0;
    setInfo(page, .disc, if (disc_total > 1) ofText(&number_buffer, summary.disc_number, disc_total) else "");
    var format_buffer: [64]u8 = undefined;
    setInfo(page, .format, if (details) |value| formatText(&format_buffer, value) else "");
}

fn ofText(buffer: []u8, number: ?i64, total: ?i64) []const u8 {
    const value = number orelse return "";
    if (total) |count| return strings.format(buffer, "{d} of {d}", .{ value, count });
    return strings.format(buffer, "{d}", .{value});
}

fn formatText(buffer: []u8, details: liborca.TrackDetails) []const u8 {
    if (details.codec.len == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    signal_path.writeCodecName(&writer, details.codec) catch {};
    if (!details.lossy) if (details.bit_depth) |depth| writer.print(" {d}-bit", .{depth}) catch {};
    if (details.sample_rate) |rate| {
        writer.writeAll(" / ") catch {};
        signal_path.writeRate(&writer, rate) catch {};
    }
    return writer.buffered();
}

pub fn refreshUpNext(self: *App) void {
    const page = &self.now_playing;
    const list = page.up_next orelse return;
    gtk.gtk_list_box_remove_all(list);
    up_next_shown = 0;
    const status = self.runtime.playerStatus(self.player) catch return;
    const start = status.queue_index;
    page.up_next_start = start;
    var shown: usize = 0;
    if (status.track_id != null and status.queue_length > start) {
        if (self.runtime.playerQueueTracks(self.player, self.allocator, start, up_next_rows)) |page_value| {
            var tracks = page_value;
            defer tracks.deinit();
            for (tracks.items, 0..) |item, offset| {
                const row = upNextRow(self, item, start + @as(u32, @intCast(offset)), offset == 0, shown);
                gtk.gtk_list_box_append(list, row);
                shown += 1;
            }
        } else |_| {}
    }
    up_next_shown = shown;
    if (page.up_next_empty) |empty| gtk.gtk_widget_set_visible(empty, boolean(shown <= 1));
}

fn upNextRow(self: *App, item: liborca.TrackSummary, position: u32, current: bool, slot: usize) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(row, "now-up-next-row");
    if (current) gtk.gtk_widget_add_css_class(row, "now-playing");

    const marker = if (current) blk: {
        const icon = gtk.gtk_image_new_from_icon_name("media-playback-start-symbolic");
        gtk.gtk_widget_add_css_class(icon, "accent");
        break :blk icon;
    } else label(strings.format(&buffer, "{d}", .{position + 1}).ptr, "numeric");
    gtk.gtk_widget_add_css_class(marker, "now-up-next-number");
    gtk.gtk_widget_set_size_request(marker, 24, -1);
    append(row, marker);

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title_line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    const title = label(strings.terminated(&buffer, if (item.title.len != 0) item.title else "Unknown title").ptr, "now-up-next-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    append(title_line, title);
    const heart = feedback.newRowButton(gtk.callback(upNextHeartClicked), self);
    feedback.showRowButton(heart, item.feedback);
    gtk.g_object_set_data(heart, "orca-position", @ptrFromInt(slot + 1));
    append(title_line, heart);
    append(labels, title_line);
    const artist = label(strings.terminated(&buffer, if (item.artist.len != 0) item.artist else item.album_artist).ptr, "now-up-next-artist");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, artist), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, artist), gtk.ELLIPSIZE_END);
    append(labels, artist);
    append(row, labels);

    const duration = label(if (item.duration_ms) |ms| strings.formatMs(&buffer, @intCast(@max(ms, 0))).ptr else "", "numeric");
    gtk.gtk_widget_add_css_class(duration, "now-up-next-duration");
    append(row, duration);

    up_next_targets[slot] = .{ .track_id = item.id, .recording_id = item.recording_id, .feedback = item.feedback };
    up_next_hearts[slot] = heart;
    return row;
}
