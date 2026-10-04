//! The Now Playing page: the audible track's cover over a blurred backdrop of
//! itself, its love and rating, the lyric lines around the one being heard,
//! and beside it what comes next and the track's facts, or its full lyrics.

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
const ratings = @import("ratings.zig");
const lyrics = @import("lyrics.zig");
const window = @import("window.zig");
const track_model = @import("track_model.zig");
const inspector = @import("details.zig");
const signal_path = @import("signal_path.zig");
const page_ui = @import("page.zig");
const transport = @import("transport.zig");

const App = app.App;

const cover_pixels: c_int = 340;
const lyrics_cover_pixels: c_int = 380;
const up_next_rows = 10;
const panel_width: c_int = 340;
const tabbed_panel_width: c_int = 380;
const info_key_width: c_int = 96;
const quote_width: c_int = 520;
const star_pixels: c_int = 17;

const InfoRow = enum { album, date, genre, track, source };

/// What the right panel shows. `up_next` is the untabbed queue and Track
/// Info; asking for the lyrics turns the panel into tabs.
const Tab = enum { up_next, lyrics, info };

pub const State = struct {
    content: ?*gtk.Stack = null,
    host: ?*gtk.Widget = null,
    cover: ?*gtk.Stack = null,
    cover_clamp: ?*adw.Clamp = null,
    picture: ?*gtk.Widget = null,
    title: ?*gtk.Label = null,
    artist: ?*gtk.Label = null,
    album: ?*gtk.Label = null,
    quote_slot: ?*gtk.Widget = null,
    panel: ?*gtk.Widget = null,
    tabs: ?*gtk.Widget = null,
    tab_buttons: std.EnumArray(Tab, ?*gtk.Widget) = .initFill(null),
    tab: Tab = .up_next,
    panel_pages: ?*gtk.Stack = null,
    queue_section: ?*gtk.Widget = null,
    up_next: ?*gtk.ListBox = null,
    up_next_empty: ?*gtk.Widget = null,
    up_next_start: u32 = 0,
    full_album: ?*gtk.Widget = null,
    info_rows: std.EnumArray(InfoRow, ?*gtk.Widget) = .initFill(null),
    info_values: std.EnumArray(InfoRow, ?*gtk.Label) = .initFill(null),
    lyrics: lyrics.View = undefined,
    artist_id: ?i64 = null,
    release_id: ?i64 = null,
};

var up_next_targets: [up_next_rows]feedback.Target = undefined;
var up_next_hearts: [up_next_rows]*gtk.Widget = undefined;
var up_next_shown: usize = 0;
var stars: ?*gtk.Widget = null;
var stars_recording: ?i64 = null;

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
    const host = art.newCover(self, art.iconPlaceholder(lyrics_cover_pixels), lyrics_cover_pixels);
    gtk.gtk_widget_set_visible(host, gtk.false_);
    art.paintWhileUnmapped(host);
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

    const centre = gtk.gtk_overlay_new();
    gtk.gtk_widget_set_hexpand(centre, gtk.true_);
    const backdrop = art.newBackdrop(self, .full);
    art.showBackdrop(self, backdrop, &.{host});
    const column = buildCentre(self);
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, centre), backdrop);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, centre), column);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, centre), column, gtk.true_);

    const playing = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    append(playing, centre);
    append(playing, buildPanel(self));
    append(playing, host);
    _ = gtk.gtk_stack_add_named(page.content.?, playing, "playing");
    gtk.gtk_stack_set_visible_child_name(page.content.?, "empty");

    gtk.gtk_widget_add_css_class(content, "now-playing-page");
    _ = gtk.signalConnect(content, "destroy", gtk.callback(destroyed), self);
    showTab(self, .up_next);
    placePanel(self);
    return content;
}

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.now_playing.lyrics.deinit();
    stars = null;
}

fn buildCentre(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "now-centre");

    const eyebrow = label("", "now-eyebrow");
    gtk.gtk_widget_set_valign(eyebrow, gtk.ALIGN_CENTER);
    setUppercase(gtk.cast(gtk.Label, eyebrow), "Now Playing");
    letterSpace(eyebrow, 2.5);
    page_ui.addTrail(self, .now_playing, eyebrow);
    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "now-body");
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
    page.cover_clamp = gtk.cast(adw.Clamp, cover_clamp);
    adw.adw_clamp_set_child(page.cover_clamp.?, frame);
    gtk.gtk_widget_add_css_class(cover_clamp, "now-cover-clamp");
    append(body, cover_clamp);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(facts, "now-facts");
    const title = label("", "display-hero");
    gtk.gtk_widget_add_css_class(title, "now-title-hero");
    page.title = gtk.cast(gtk.Label, title);
    gtk.gtk_label_set_justify(page.title.?, gtk.JUSTIFY_CENTER);
    gtk.gtk_label_set_wrap(page.title.?, gtk.true_);
    gtk.gtk_label_set_lines(page.title.?, 2);
    gtk.gtk_label_set_ellipsize(page.title.?, gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(page.title.?, 24);
    menu.onSecondaryClick(title, menu.playingMenu, self);
    gtk.gtk_widget_set_cursor_from_name(title, "pointer");
    const title_click = gtk.gtk_gesture_click_new();
    _ = gtk.signalConnect(title_click, "released", gtk.callback(titleClicked), self);
    gtk.gtk_widget_add_controller(title, title_click);
    append(facts, title);
    page.artist = linkLabel(facts, "now-artist", artistClicked, self);
    page.album = linkLabel(facts, "now-album", albumClicked, self);
    letterSpace(gtk.cast(gtk.Widget, page.album.?), 2.2);
    append(body, facts);

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(actions, "now-actions");
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_CENTER);
    const heart = feedback.newNowPlayingButton(self, gtk.callback(loveClicked));
    gtk.gtk_widget_add_css_class(heart, "now-round");
    append(actions, heart);
    const rating = ratings.newStars(gtk.callback(starClicked), self);
    ratings.setStarSize(rating, star_pixels);
    gtk.gtk_widget_add_css_class(rating, "now-stars");
    stars = rating;
    append(actions, rating);
    const more = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "circular");
    gtk.gtk_widget_add_css_class(more, "now-round");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    append(actions, more);
    append(body, actions);

    append(body, buildQuote(self));
    return column;
}

/// The slot stays mapped while the page shows it, so that `lyrics.zig` looks
/// the Track's lyrics up; only the lines inside it are hidden without lyrics.
fn buildQuote(self: *App) *gtk.Widget {
    const quote = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(quote, "now-lyrics");
    var labels: [3]*gtk.Widget = undefined;
    for (&labels, [_][*:0]const u8{ "now-lyric-previous", "now-lyric-current", "now-lyric-next" }) |*line, class| {
        line.* = label("", "now-lyric");
        gtk.gtk_widget_add_css_class(line.*, class);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, line.*), gtk.ELLIPSIZE_END);
        gtk.gtk_label_set_justify(gtk.cast(gtk.Label, line.*), gtk.JUSTIFY_CENTER);
        append(quote, line.*);
    }
    const show_all = gtk.gtk_button_new_with_label("Show all lyrics");
    gtk.gtk_widget_add_css_class(show_all, "flat");
    gtk.gtk_widget_add_css_class(show_all, "now-show-lyrics");
    gtk.gtk_widget_set_halign(show_all, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(show_all, "clicked", gtk.callback(showAllClicked), self);
    append(quote, show_all);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), quote_width);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), quote);
    const slot = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(slot, clamp);
    self.now_playing.quote_slot = slot;
    lyrics.watchQuote(self, slot, quote, labels);
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

fn sectionTitle(text: [*:0]const u8) *gtk.Widget {
    const title = label(text, "now-panel-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    setUppercase(gtk.cast(gtk.Label, title), std.mem.span(text));
    letterSpace(title, 2.5);
    return title;
}

fn buildPanel(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const panel = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(panel, "now-panel");
    gtk.gtk_widget_set_hexpand(panel, gtk.false_);
    page.panel = panel;

    const tabs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(tabs, "now-tabs");
    page.tabs = tabs;
    var group: ?*gtk.ToggleButton = null;
    const names = std.EnumArray(Tab, [*:0]const u8).init(.{ .up_next = "Up Next", .lyrics = "Lyrics", .info = "Info" });
    for (std.enums.values(Tab)) |tab| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), names.get(tab));
        gtk.gtk_widget_add_css_class(button, "flat");
        gtk.gtk_widget_add_css_class(button, "now-tab");
        gtk.gtk_widget_set_focus_on_click(button, gtk.false_);
        gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, button), group);
        group = gtk.cast(gtk.ToggleButton, button);
        gtk.g_object_set_data(button, "orca-tab", @ptrFromInt(@intFromEnum(tab) + 1));
        _ = gtk.signalConnect(button, "toggled", gtk.callback(tabToggled), self);
        append(tabs, button);
        page.tab_buttons.set(tab, button);
    }
    append(panel, tabs);

    const pages = gtk.gtk_stack_new();
    page.panel_pages = gtk.cast(gtk.Stack, pages);
    gtk.gtk_widget_set_vexpand(pages, gtk.true_);
    gtk.gtk_stack_set_hhomogeneous(page.panel_pages.?, gtk.false_);

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(facts, "now-panel-facts");
    append(facts, buildQueueSection(self));
    append(facts, buildInfoSection(self));
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), facts);
    gtk.gtk_widget_set_focusable(scroller, gtk.false_);
    _ = gtk.gtk_stack_add_named(page.panel_pages.?, scroller, "facts");

    page.lyrics.initNowPlaying(self);
    _ = gtk.gtk_stack_add_named(page.panel_pages.?, page.lyrics.root, "lyrics");
    append(panel, pages);
    return panel;
}

fn buildQueueSection(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(section, "now-queue-section");
    page.queue_section = section;

    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "now-panel-heading");
    append(heading, sectionTitle("Up Next"));
    const clear = gtk.gtk_button_new_with_label("Clear");
    gtk.gtk_widget_add_css_class(clear, "flat");
    gtk.gtk_widget_add_css_class(clear, "now-panel-action");
    _ = gtk.signalConnect(clear, "clicked", gtk.callback(clearClicked), self);
    append(heading, clear);
    append(section, heading);

    const list = gtk.gtk_list_box_new();
    page.up_next = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(page.up_next.?, gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_activate_on_single_click(page.up_next.?, gtk.false_);
    gtk.gtk_widget_add_css_class(list, "now-up-next-list");
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(upNextActivated), self);
    append(section, list);
    const nothing = label("Nothing queued after this track", "now-up-next-empty");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, nothing), 0.0);
    page.up_next_empty = nothing;
    append(section, nothing);

    const full_label = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(full_label, gtk.ALIGN_CENTER);
    append(full_label, gtk.gtk_label_new("View Full Album"));
    append(full_label, gtk.gtk_image_new_from_icon_name("orca-forward-symbolic"));
    const full = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, full), full_label);
    gtk.gtk_widget_add_css_class(full, "now-full-album");
    _ = gtk.signalConnect(full, "clicked", gtk.callback(albumClicked), self);
    page.full_album = full;
    append(section, full);
    return section;
}

fn buildInfoSection(self: *App) *gtk.Widget {
    const page = &self.now_playing;
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(section, "now-info-section");
    const heading = sectionTitle("Track Info");
    gtk.gtk_widget_add_css_class(heading, "now-info-title");
    append(section, heading);
    const names = std.EnumArray(InfoRow, [*:0]const u8).init(.{
        .album = "Album",
        .date = "Date",
        .genre = "Genre",
        .track = "Track",
        .source = "Source",
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
        append(section, line);
        page.info_rows.set(row, line);
        page.info_values.set(row, gtk.cast(gtk.Label, value));
    }
    return section;
}

pub fn placePanel(self: *App) void {
    const panel = self.now_playing.panel orelse return;
    const shown = !self.header_compact and inspector.shownMode(self) == .hidden;
    gtk.gtk_widget_set_visible(panel, boolean(shown));
    page_ui.fitToPage(self);
}

pub fn panelWidth(self: *App) c_int {
    const page = &self.now_playing;
    const panel = page.panel orelse return 0;
    const content = page.content orelse return 0;
    if (gtk.gtk_widget_get_visible(panel) == 0) return 0;
    const shown = gtk.gtk_stack_get_visible_child_name(content) orelse return 0;
    if (!std.mem.eql(u8, std.mem.span(shown), "playing")) return 0;
    return if (page.tab == .up_next) panel_width else tabbed_panel_width;
}

fn showTab(self: *App, tab: Tab) void {
    const page = &self.now_playing;
    page.tab = tab;
    const tabbed = tab != .up_next;
    if (page.tab_buttons.get(tab)) |button| gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, button), gtk.true_);
    if (page.tabs) |tabs| gtk.gtk_widget_set_visible(tabs, boolean(tabbed));
    if (page.panel) |panel| gtk.gtk_widget_set_size_request(panel, if (tabbed) tabbed_panel_width else panel_width, -1);
    if (page.panel_pages) |pages| gtk.gtk_stack_set_visible_child_name(pages, if (tab == .lyrics) "lyrics" else "facts");
    if (page.queue_section) |section| gtk.gtk_widget_set_visible(section, boolean(tab == .up_next));
    if (page.quote_slot) |slot| gtk.gtk_widget_set_visible(slot, boolean(tab != .lyrics));
    const size = if (tab == .lyrics) lyrics_cover_pixels else cover_pixels;
    if (page.cover_clamp) |clamp| {
        adw.adw_clamp_set_maximum_size(clamp, size);
        adw.adw_clamp_set_tightening_threshold(clamp, size);
    }
    page_ui.fitToPage(self);
}

fn tabToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) == 0) return;
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-tab"));
    if (marked == 0 or marked > std.enums.values(Tab).len) return;
    const tab: Tab = @enumFromInt(@as(std.meta.Tag(Tab), @intCast(marked - 1)));
    const self = state(data);
    if (tab != self.now_playing.tab) showTab(self, tab);
}

fn showAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showTab(state(data), .lyrics);
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

fn starClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const target = feedback.playingTarget(self) orelse return;
    ratings.change(self, &.{target}, ratings.chosen(button));
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
    if (!transport.ensureOutput(self)) return self.toast("No audio output is available");
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
    switch (change) {
        .feedback => |value| for (up_next_targets[0..up_next_shown], up_next_hearts[0..up_next_shown]) |*target, heart| {
            const recording = target.recording_id orelse continue;
            if (!changed.contains(recording)) continue;
            target.feedback = value;
            feedback.showRowButton(heart, value);
        },
        .rating => |value| {
            const recording = stars_recording orelse return;
            if (changed.contains(recording)) ratings.show(stars orelse return, value);
        },
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
        stars_recording = null;
        art.clear(self, host);
        gtk.gtk_stack_set_visible_child_name(content, "empty");
        page_ui.fitToPage(self);
        refreshUpNext(self);
        return;
    };
    gtk.gtk_stack_set_visible_child_name(content, "playing");
    page_ui.fitToPage(self);
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
    stars_recording = summary.recording_id;
    if (stars) |rating| ratings.show(rating, summary.rating);
    if (page.full_album) |full| gtk.gtk_widget_set_sensitive(full, boolean(summary.release_id != null));

    const details = if (self.library) |library| (self.runtime.libraryTrackDetails(library, summary.id) catch null) else null;
    defer if (details) |value| value.deinit();
    const date: []const u8 = if (details) |value| value.date orelse "" else "";
    const year = date[0..@min(date.len, 4)];
    var buffer: [512]u8 = undefined;
    const album_line = if (summary.album.len != 0 and year.len != 0)
        strings.format(&buffer, "{s} · {s}", .{ summary.album, year })
    else if (summary.album.len != 0) summary.album else year;
    setUppercase(page.album.?, album_line);

    setInfo(page, .album, summary.album);
    setInfo(page, .date, date);
    var genre_buffer: [512]u8 = undefined;
    setInfo(page, .genre, if (details) |value| inspector.genresText(&genre_buffer, value.genres) orelse "" else "");
    var number_buffer: [48]u8 = undefined;
    const track_total = if (details) |value| value.track_total else null;
    setInfo(page, .track, ofText(&number_buffer, summary.track_number, track_total));
    var format_buffer: [64]u8 = undefined;
    setInfo(page, .source, if (details) |value| formatText(&format_buffer, value) else "");
    if (page.info_values.get(.source)) |source| {
        var path_buffer: [4096]u8 = undefined;
        gtk.gtk_widget_set_tooltip_text(gtk.cast(gtk.Widget, source), if (summary.path.len != 0) strings.terminated(&path_buffer, summary.path).ptr else null);
    }
}

fn ofText(buffer: []u8, number: ?i64, total: ?i64) []const u8 {
    const value = number orelse return "";
    if (total) |count| return strings.format(buffer, "{d} of {d}", .{ value, count });
    return strings.format(buffer, "{d}", .{value});
}

/// "FLAC · 16-bit · 44.1 kHz": the codec, a lossless depth and the rate.
fn formatText(buffer: []u8, details: liborca.TrackDetails) []const u8 {
    if (details.codec.len == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    signal_path.writeCodecName(&writer, details.codec) catch {};
    if (!details.lossy) if (details.bit_depth) |depth| writer.print(" · {d}-bit", .{depth}) catch {};
    if (details.sample_rate) |rate| {
        writer.writeAll(" · ") catch {};
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
                if (shown == up_next_rows) break;
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

    const marker = if (current) blk: {
        const icon = gtk.gtk_image_new_from_icon_name("orca-play-symbolic");
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 12);
        break :blk icon;
    } else label(strings.format(&buffer, "{d}", .{position + 1}).ptr, "numeric");
    gtk.gtk_widget_add_css_class(marker, "now-up-next-number");
    gtk.gtk_widget_set_size_request(marker, 24, -1);
    append(row, marker);

    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title = label(strings.terminated(&buffer, if (item.title.len != 0) item.title else "Unknown title").ptr, "now-up-next-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    append(labels, title);
    const artist = label(strings.terminated(&buffer, if (item.artist.len != 0) item.artist else item.album_artist).ptr, "now-up-next-artist");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, artist), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, artist), gtk.ELLIPSIZE_END);
    append(labels, artist);
    append(row, labels);

    const heart = feedback.newRowButton(gtk.callback(upNextHeartClicked), self);
    feedback.showRowButton(heart, item.feedback);
    gtk.gtk_widget_set_valign(heart, gtk.ALIGN_CENTER);
    gtk.g_object_set_data(heart, "orca-position", @ptrFromInt(slot + 1));
    append(row, heart);
    const duration = label(if (item.duration_ms) |ms| strings.formatMs(&buffer, @intCast(@max(ms, 0))).ptr else "", "numeric");
    gtk.gtk_widget_add_css_class(duration, "now-up-next-duration");
    append(row, duration);

    const list_row = gtk.gtk_list_box_row_new();
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, list_row), row);
    gtk.gtk_widget_add_css_class(list_row, "now-up-next");
    if (current) gtk.gtk_widget_add_css_class(list_row, "now-playing");

    up_next_targets[slot] = .{ .track_id = item.id, .recording_id = item.recording_id, .feedback = item.feedback };
    up_next_hearts[slot] = heart;
    return list_row;
}
