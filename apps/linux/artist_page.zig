//! An Artist's page: their photo, genres and biography, the tracks of theirs
//! played most, their albums and appearances, the release groups MusicBrainz
//! knows that the library has none of, and the artists related to them.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const transport = @import("transport.zig");
const menu = @import("menu.zig");
const details = @import("details.zig");
const feedback = @import("feedback.zig");
const track_model = @import("track_model.zig");
const window = @import("window.zig");
const page_ui = @import("page.zig");

const App = app.App;

const content_max_pixels = 1060;
const photo_pixels: c_int = 232;
const biography_max_pixels = 580;
const biography_lines = 3;
const read_more_uri = "orca:read-more";
const read_more_suffix = "… Read more";
const tracks_pixels: c_int = 380;
const sections_gap: c_int = 40;
const stacked_key = "orca-artist-sections-stacked";
const album_pixels: c_int = 132;
const album_columns = 3;
const own_release_limit = 9;
const appearance_limit = 6;
const elsewhere_pixels: c_int = 150;
const track_cover_pixels: c_int = 40;
const related_pixels: c_int = 88;
const related_tile_pixels: c_int = 96;
const related_limit = 7;
const top_track_limit = 5;
const queue_limit = 10_000;
const musicbrainz_artist_url = "https://musicbrainz.org/artist/";
const musicbrainz_release_group_url = "https://musicbrainz.org/release-group/";

const Track = struct {
    target: feedback.Target,
    release_id: ?i64,
    artist_id: ?i64,
    row: ?*gtk.Widget = null,
};

const Related = struct {
    library_artist_id: ?i64,
    mbid: [36]u8,
    mbid_len: u8,
};

pub const ArtistPage = struct {
    self: *App,
    navigation: *adw.NavigationView,
    artist_id: i64,
    name: [:0]u8,
    tracks: []i64,
    releases: []i64,
    elsewhere: []liborca.ElsewhereRelease = &.{},
    top_tracks: [top_track_limit]Track = undefined,
    track_ids: [top_track_limit]i64 = undefined,
    track_count: usize = 0,
    related: [related_limit]Related = undefined,
    related_count: usize = 0,
    loved: bool = false,
    biography_expanded: bool = false,
    hero: ?*gtk.Widget = null,
    sections: ?*gtk.Widget = null,
    scroller: ?*gtk.Widget = null,
    photo: ?*gtk.Widget = null,
    genres: ?*gtk.Widget = null,
    biography: ?*gtk.Widget = null,
    biography_label: ?*gtk.Widget = null,
    biography_credit: ?*gtk.Widget = null,
    biography_text: ?[:0]u8 = null,
    biography_width: c_int = 0,
    biography_truncated: bool = false,
    biography_pending: bool = false,
    elsewhere_section: ?*gtk.Widget = null,
    elsewhere_flow: ?*gtk.Widget = null,
    related_section: ?*gtk.Widget = null,
    related_flow: ?*gtk.Widget = null,
    love_button: ?*gtk.Widget = null,
    album_flows: [2]*gtk.Widget = undefined,
    album_flow_count: usize = 0,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn pageData(data: ?*anyopaque) *ArtistPage {
    return @ptrCast(@alignCast(data.?));
}

fn freeElsewhere(page: *ArtistPage) void {
    const allocator = page.self.allocator;
    for (page.elsewhere) |group| group.deinit(allocator);
    allocator.free(page.elsewhere);
    page.elsewhere = &.{};
}

fn pageDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const allocator = page.self.allocator;
    unregisterPage(page);
    details.forgetIds(page.self, page.track_ids[0..page.track_count]);
    freeElsewhere(page);
    if (page.biography_text) |text| allocator.free(text);
    allocator.free(page.name);
    allocator.free(page.tracks);
    allocator.free(page.releases);
    allocator.destroy(page);
}

/// What the inspector follows while `pushed`, an artist page, shows.
pub fn inspectorSource(self: *App, pushed: *adw.NavigationPage) ?details.Source {
    const child = adw.adw_navigation_page_get_child(pushed) orelse return null;
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        if (page.scroller != child) continue;
        return .{ .artist = .{ .ids = page.track_ids[0..page.track_count], .artist_id = page.artist_id } };
    }
    return null;
}

fn registerPage(page: *ArtistPage) void {
    const self = page.self;
    if (self.open_artist_page_count == self.open_artist_pages.len) return;
    self.open_artist_pages[self.open_artist_page_count] = page;
    self.open_artist_page_count += 1;
}

fn unregisterPage(page: *ArtistPage) void {
    const self = page.self;
    for (self.open_artist_pages[0..self.open_artist_page_count], 0..) |open, index| {
        if (open != page) continue;
        self.open_artist_page_count -= 1;
        self.open_artist_pages[index] = self.open_artist_pages[self.open_artist_page_count];
        return;
    }
}

fn layOut(page: *ArtistPage) void {
    const stacked = page.self.window_narrow or page.self.header_compact;
    const orientation: c_int = if (stacked) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL;
    if (page.hero) |hero| {
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, hero), orientation);
        if (stacked) gtk.gtk_widget_add_css_class(hero, "stacked") else gtk.gtk_widget_remove_css_class(hero, "stacked");
    }
    if (page.sections) |sections| {
        gtk.g_object_set_data(sections, stacked_key, if (stacked) sections else null);
        gtk.gtk_widget_queue_resize(sections);
    }
}

const SectionColumns = struct { tracks: ?*gtk.Widget, side: *gtk.Widget };

fn sectionColumns(sections: *gtk.Widget) ?SectionColumns {
    const first = gtk.gtk_widget_get_first_child(sections) orelse return null;
    const second = gtk.gtk_widget_get_next_sibling(first) orelse return .{ .tracks = null, .side = first };
    return .{ .tracks = first, .side = second };
}

fn sectionsStacked(sections: *gtk.Widget) bool {
    return gtk.g_object_get_data(sections, stacked_key) != null;
}

fn minimumWidth(widget: *gtk.Widget) c_int {
    var minimum: c_int = 0;
    gtk.gtk_widget_measure(widget, gtk.ORIENTATION_HORIZONTAL, -1, &minimum, null, null, null);
    return minimum;
}

fn tracksWidth(columns: SectionColumns, width: c_int) c_int {
    const tracks = columns.tracks orelse return 0;
    const tracks_minimum = minimumWidth(tracks);
    const room = width - sections_gap - minimumWidth(columns.side);
    return @max(tracks_minimum, @min(tracks_pixels, room));
}

fn measureSections(
    sections: *gtk.Widget,
    orientation: c_int,
    for_size: c_int,
    minimum: *c_int,
    natural: *c_int,
    minimum_baseline: *c_int,
    natural_baseline: *c_int,
) callconv(.c) void {
    minimum.* = 0;
    natural.* = 0;
    minimum_baseline.* = -1;
    natural_baseline.* = -1;
    const columns = sectionColumns(sections) orelse return;
    const horizontal = orientation == gtk.ORIENTATION_HORIZONTAL;
    const stacked = sectionsStacked(sections);
    var side_minimum: c_int = 0;
    var side_natural: c_int = 0;
    var tracks_minimum: c_int = 0;
    var tracks_natural: c_int = 0;
    if (horizontal or stacked or for_size < 0) {
        gtk.gtk_widget_measure(columns.side, orientation, for_size, &side_minimum, &side_natural, null, null);
        if (columns.tracks) |tracks| gtk.gtk_widget_measure(tracks, orientation, for_size, &tracks_minimum, &tracks_natural, null, null);
    } else {
        const tracks_width = tracksWidth(columns, for_size);
        const side_width = @max(minimumWidth(columns.side), for_size - tracks_width - sections_gap);
        gtk.gtk_widget_measure(columns.side, orientation, side_width, &side_minimum, &side_natural, null, null);
        if (columns.tracks) |tracks| gtk.gtk_widget_measure(tracks, orientation, tracks_width, &tracks_minimum, &tracks_natural, null, null);
    }
    if (columns.tracks == null) {
        minimum.* = side_minimum;
        natural.* = side_natural;
    } else if (horizontal and !stacked) {
        minimum.* = tracks_minimum + sections_gap + side_minimum;
        natural.* = @max(tracks_minimum, tracks_pixels) + sections_gap + side_natural;
    } else if (horizontal or !stacked) {
        minimum.* = @max(tracks_minimum, side_minimum);
        natural.* = @max(tracks_natural, side_natural);
    } else {
        minimum.* = tracks_minimum + sections_gap + side_minimum;
        natural.* = tracks_natural + sections_gap + side_natural;
    }
}

fn allocateSections(sections: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const columns = sectionColumns(sections) orelse return;
    const tracks = columns.tracks orelse
        return gtk.gtk_widget_size_allocate(columns.side, &.{ .x = 0, .y = 0, .width = width, .height = height }, -1);
    if (sectionsStacked(sections)) {
        var tracks_height: c_int = 0;
        gtk.gtk_widget_measure(tracks, gtk.ORIENTATION_VERTICAL, width, &tracks_height, null, null, null);
        gtk.gtk_widget_size_allocate(tracks, &.{ .x = 0, .y = 0, .width = width, .height = tracks_height }, -1);
        const side_y = tracks_height + sections_gap;
        gtk.gtk_widget_size_allocate(columns.side, &.{ .x = 0, .y = side_y, .width = width, .height = @max(0, height - side_y) }, -1);
        return;
    }
    const tracks_width = tracksWidth(columns, width);
    gtk.gtk_widget_size_allocate(tracks, &.{ .x = 0, .y = 0, .width = tracks_width, .height = height }, -1);
    const side_x = tracks_width + sections_gap;
    gtk.gtk_widget_size_allocate(columns.side, &.{ .x = side_x, .y = 0, .width = @max(0, width - side_x), .height = height }, -1);
}

pub fn setNarrow(self: *App) void {
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| layOut(page);
}

pub fn repaint(self: *App, changed: *const feedback.Recordings, change: track_model.Change) void {
    const value = switch (change) {
        .feedback => |value| value,
        .rating => return,
    };
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        for (page.top_tracks[0..page.track_count]) |*track| {
            const recording = track.target.recording_id orelse continue;
            if (changed.contains(recording)) track.target.feedback = value;
        }
    }
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    const playing = self.playing();
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        for (page.top_tracks[0..page.track_count]) |track| {
            const row = track.row orelse continue;
            if (track_id == track.target.track_id)
                gtk.gtk_widget_add_css_class(row, "now-playing")
            else
                gtk.gtk_widget_remove_css_class(row, "now-playing");
        }
        for (page.album_flows[0..page.album_flow_count]) |flow| {
            var child = gtk.gtk_widget_get_first_child(flow);
            while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
                const tile = gtk.gtk_widget_get_first_child(cell) orelse continue;
                const index = marked(tile) orelse continue;
                if (index >= page.releases.len) continue;
                albums.showPlaying(tile, playing.matches(.release, page.releases[index]));
            }
        }
    }
}

fn play(page: *ArtistPage, shuffle: bool) void {
    if (page.tracks.len == 0) return page.self.toast("No track of theirs has a playable file");
    page.self.runtime.playerSetShuffle(page.self.player, shuffle) catch {};
    transport.playIds(page.self, page.tracks, 0);
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    play(pageData(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    play(pageData(data), true);
}

fn setArtistLove(self: *App, artist_id: i64, artist_loved: bool) void {
    const library = self.library orelse return;
    const result = self.runtime.librarySetArtistLove(library, &.{artist_id}, artist_loved) catch
        return self.toast("Could not save that");
    if (result.skipped != 0) return self.toast("That artist is no longer in the library");
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        if (page.artist_id != artist_id) continue;
        page.loved = artist_loved;
        if (page.love_button) |button| feedback.showArtistButton(button, artist_loved);
    }
    if (self.artist_sort == .recently_loved) artists.reload(self);
}

fn loveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    setArtistLove(page.self, page.artist_id, !page.loved);
}

fn heroMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (artists.setArtistContext(page.self, page.artist_id)) menu.popup(page.self, menu.gestureWidget(gesture), x, y);
}

fn heroMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    if (artists.setArtistContext(page.self, page.artist_id)) albums.popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn biographyFits(layout: *gtk.PangoLayout, buffer: []u8, text: []const u8, suffix: []const u8) bool {
    @memcpy(buffer[0..text.len], text);
    @memcpy(buffer[text.len..][0..suffix.len], suffix);
    gtk.pango_layout_set_text(layout, buffer.ptr, @intCast(text.len + suffix.len));
    return gtk.pango_layout_is_ellipsized(layout) == 0;
}

fn biographyCut(allocator: std.mem.Allocator, label: *gtk.Widget, text: []const u8, width: c_int) !usize {
    const layout = gtk.gtk_widget_create_pango_layout(label, null);
    defer gtk.g_object_unref(layout);
    gtk.pango_layout_set_width(layout, width * gtk.PANGO_SCALE);
    gtk.pango_layout_set_height(layout, -biography_lines);
    gtk.pango_layout_set_wrap(layout, gtk.PANGO_WRAP_WORD);
    gtk.pango_layout_set_ellipsize(layout, gtk.ELLIPSIZE_END);
    const buffer = try allocator.alloc(u8, text.len + read_more_suffix.len);
    defer allocator.free(buffer);
    if (biographyFits(layout, buffer, text, "")) return text.len;
    var low: usize = 0;
    var high: usize = text.len;
    while (low < high) {
        const middle = low + (high - low + 1) / 2;
        const space = std.mem.lastIndexOfScalar(u8, text[0..middle], ' ') orelse 0;
        if (space <= low) {
            high = middle - 1;
            continue;
        }
        if (biographyFits(layout, buffer, std.mem.trimEnd(u8, text[0..space], " \n,;:"), read_more_suffix))
            low = space
        else
            high = space - 1;
    }
    return low;
}

fn fitBiography(page: *ArtistPage) void {
    const label = page.biography_label orelse return;
    const text = page.biography_text orelse return;
    const width = gtk.gtk_widget_get_width(label);
    if (width <= 0) return;
    page.biography_width = width;
    const allocator = page.self.allocator;
    const cut = biographyCut(allocator, label, text, width) catch return;
    page.biography_truncated = cut < text.len;
    const collapsed = page.biography_truncated and !page.biography_expanded;
    const shown = if (collapsed) std.mem.trimEnd(u8, text[0..cut], " \n,;:") else text;
    const escaped = gtk.g_markup_escape_text(shown.ptr, @intCast(shown.len));
    defer gtk.g_free(escaped);
    const link: []const u8 = if (collapsed)
        "… <a href=\"" ++ read_more_uri ++ "\"><span underline=\"none\">Read more</span></a>"
    else if (page.biography_truncated)
        " <a href=\"" ++ read_more_uri ++ "\"><span underline=\"none\">Show less</span></a>"
    else
        "";
    const markup = std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ std.mem.span(escaped), link }, 0) catch return;
    defer allocator.free(markup);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, label), if (collapsed) biography_lines else -1);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), if (collapsed) gtk.ELLIPSIZE_END else gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_markup(gtk.cast(gtk.Label, label), markup.ptr);
    if (page.biography_credit) |credit| {
        const credit_text = gtk.gtk_label_get_text(gtk.cast(gtk.Label, credit));
        gtk.gtk_widget_set_visible(credit, @intFromBool(!collapsed and credit_text[0] != 0));
    }
}

fn biographyTick(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const page = pageData(data);
    const label = page.biography_label orelse return gtk.false_;
    const shown = if (page.biography) |biography| gtk.gtk_widget_get_visible(biography) != 0 else false;
    if (gtk.gtk_widget_get_width(label) <= 0 and shown) return gtk.true_;
    page.biography_pending = false;
    fitBiography(page);
    return gtk.false_;
}

fn queueBiographyFit(page: *ArtistPage) void {
    if (page.biography_pending or page.biography_text == null) return;
    const label = page.biography_label orelse return;
    page.biography_pending = true;
    _ = gtk.gtk_widget_add_tick_callback(label, biographyTick, page, null);
}

fn pageResized(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const label = page.biography_label orelse return;
    if (gtk.gtk_widget_get_width(label) != page.biography_width) queueBiographyFit(page);
}

fn biographyLinkActivated(_: ?*anyopaque, uri: [*:0]const u8, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    if (!std.mem.eql(u8, std.mem.span(uri), read_more_uri)) return gtk.false_;
    const page = pageData(data);
    page.biography_expanded = !page.biography_expanded;
    queueBiographyFit(page);
    return gtk.true_;
}

fn marked(widget: ?*anyopaque) ?usize {
    const position = @intFromPtr(gtk.g_object_get_data(widget.?, "orca-position"));
    if (position == 0) return null;
    return position - 1;
}

fn markPosition(widget: *gtk.Widget, position: usize) void {
    gtk.g_object_set_data(widget, "orca-position", @ptrFromInt(position + 1));
}

fn releaseSeeAllClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const scope = std.enums.fromInt(albums.ArtistScope, marked(button) orelse return) orelse return;
    albums.showArtist(page.self, page.artist_id, page.name, scope);
}

fn albumActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const tile = gtk.gtk_flow_box_child_get_child(gtk.cast(gtk.FlowBoxChild, child)) orelse return;
    const index = marked(tile) orelse return;
    if (index >= page.releases.len) return;
    albums.openAlbum(page.self, page.navigation, page.releases[index]);
}

fn albumMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const tile = menu.gestureWidget(gesture);
    const index = marked(tile) orelse return;
    if (index >= page.releases.len) return;
    if (albums.setAlbumContext(page.self, page.releases[index])) menu.popup(page.self, tile, x, y);
}

fn albumPlayClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = marked(button) orelse return;
    if (index >= page.releases.len) return;
    albums.playRelease(page.self, page.releases[index]);
}

fn tileLabel(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn albumTile(page: *ArtistPage, release: liborca.ReleaseSummary, position: usize) *gtk.Widget {
    const self = page.self;
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "album-tile");
    gtk.gtk_widget_add_css_class(tile, "artist-album-tile");
    gtk.gtk_widget_set_size_request(tile, album_pixels, -1);
    markPosition(tile, position);

    const cover = art.newCover(self, art.initialsPlaceholder(), album_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    art.setInitials(cover, release.title);
    art.show(self, cover, art.Key.release(release.id, art.Size.atLeast(album_pixels)));
    const play_button = gtk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
    for ([_][*:0]const u8{ "tile-play", "tile-action", "circular" }) |class| gtk.gtk_widget_add_css_class(play_button, class);
    gtk.gtk_widget_set_halign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(play_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(play_button, "Play Album");
    markPosition(play_button, position);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(albumPlayClicked), page);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_widget_add_css_class(frame, "album-cover-frame");
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), play_button);
    const playing = albums.playingBadge();
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), playing);
    gtk.g_object_set_data(tile, "orca-playing", playing);
    albums.showPlaying(tile, self.playing().matches(.release, release.id));

    var buffer: [512]u8 = undefined;
    const title = tileLabel(strings.terminated(&buffer, if (release.title.len != 0) release.title else "Untitled").ptr, "tile-title");
    const year = tileLabel(strings.terminated(&buffer, releaseYear(release)).ptr, "tile-year");
    gtk.gtk_widget_add_css_class(year, "numeric");

    for ([_]*gtk.Widget{ frame, title, year }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
    menu.onSecondaryClick(tile, albumMenu, page);
    return tile;
}

fn releaseYear(release: liborca.ReleaseSummary) []const u8 {
    const date = release.release_date orelse return "";
    return date[0..@min(date.len, 4)];
}

fn rowPosition(row: *gtk.Widget) ?usize {
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row));
    if (index < 0) return null;
    return @intCast(index);
}

fn setTrackContext(page: *ArtistPage, position: usize) bool {
    if (position >= page.track_count) return false;
    const self = page.self;
    const track = page.top_tracks[position];
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, track.target.track_id, track.target.recording_id, track.target.feedback) catch return false;
    self.context.release_id = track.release_id;
    self.context.artist_id = track.artist_id orelse page.artist_id;
    return true;
}

fn trackMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const row = menu.gestureWidget(gesture);
    const position = rowPosition(row) orelse return;
    if (setTrackContext(page, position)) menu.popup(page.self, row, x, y);
}

fn trackKeyPressed(controller: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const page = pageData(data);
    const key = menu.trackKey(keyval, modifiers) orelse return gtk.false_;
    if (!window.plainKeysApply(page.self)) return gtk.false_;
    const list = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, controller.?));
    const row = gtk.gtk_list_box_get_selected_row(gtk.cast(gtk.ListBox, list)) orelse return gtk.false_;
    const position = rowPosition(gtk.cast(gtk.Widget, row)) orelse return gtk.false_;
    if (!setTrackContext(page, position)) return gtk.false_;
    menu.runTrackKey(page.self, key);
    return gtk.true_;
}

fn trackMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const position = marked(button) orelse return;
    if (setTrackContext(page, position)) albums.popupBelow(page.self, gtk.cast(gtk.Widget, button.?));
}

fn trackSelected(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const selected = row orelse return;
    const page = pageData(data);
    const position = rowPosition(gtk.cast(gtk.Widget, selected)) orelse return;
    if (position >= page.track_count) return;
    details.choose(page.self, page.track_ids[0..page.track_count], page.track_ids[position]);
}

fn trackActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const position = rowPosition(gtk.cast(gtk.Widget, row)) orelse return;
    if (position >= page.track_count) return;
    const id = page.track_ids[position];
    page.self.runtime.playerSetShuffle(page.self.player, false) catch {};
    const start = std.mem.indexOfScalar(i64, page.tracks, id) orelse return transport.playIds(page.self, &.{id}, 0);
    transport.playIds(page.self, page.tracks, @intCast(start));
}

fn trackSubtitle(buffer: []u8, summary: liborca.TrackSummary, by_plays: bool) [:0]const u8 {
    if (!by_plays) return strings.terminated(buffer, summary.album);
    const plays = if (summary.play_count == 1) "play" else "plays";
    if (summary.album.len == 0) return strings.format(buffer, "{d} {s}", .{ summary.play_count, plays });
    return strings.format(buffer, "{s} · {d} {s}", .{ summary.album, summary.play_count, plays });
}

fn trackRow(page: *ArtistPage, summary: liborca.TrackSummary, position: usize, by_plays: bool) *gtk.Widget {
    const self = page.self;
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "artist-track-row");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "artist-track");

    var buffer: [512]u8 = undefined;
    const number = gtk.gtk_label_new(strings.format(&buffer, "{d}", .{position + 1}).ptr);
    gtk.gtk_widget_set_size_request(number, 22, -1);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 0.0);
    gtk.gtk_widget_add_css_class(number, "artist-track-number");
    gtk.gtk_widget_add_css_class(number, "numeric");

    const thumb = art.newCover(self, art.iconPlaceholder(track_cover_pixels), track_cover_pixels);
    gtk.gtk_widget_add_css_class(thumb, "artist-track-cover");
    const size = art.Size.atLeast(track_cover_pixels);
    art.show(self, thumb, if (summary.release_id) |release| art.Key.release(release, size) else art.Key.track(summary.id, size));

    const title = tileLabel(strings.terminated(&buffer, if (summary.title.len != 0) summary.title else "Untitled").ptr, "artist-track-title");
    const title_line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title_line), title);
    if (summary.explicit == .explicit) gtk.gtk_box_append(gtk.cast(gtk.Box, title_line), explicitBadge());
    const subtitle = tileLabel(trackSubtitle(&buffer, summary, by_plays).ptr, "artist-track-album");
    gtk.gtk_widget_add_css_class(subtitle, "numeric");
    const titles = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(titles, gtk.true_);
    gtk.gtk_widget_set_valign(titles, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, titles), title_line);
    gtk.gtk_box_append(gtk.cast(gtk.Box, titles), subtitle);

    const duration: [:0]const u8 = if (summary.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else "")
    else
        "";
    const duration_label = gtk.gtk_label_new(duration.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration_label), 1.0);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "artist-track-duration");

    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    markPosition(more, position);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(trackMoreClicked), page);

    for ([_]*gtk.Widget{ number, thumb, titles, duration_label, more }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    if (!summary.has_playable_file) gtk.gtk_widget_set_sensitive(row, gtk.false_);
    menu.onSecondaryClick(row, trackMenu, page);
    page.top_tracks[position] = .{
        .target = .{ .track_id = summary.id, .recording_id = summary.recording_id, .feedback = summary.feedback },
        .release_id = summary.release_id,
        .artist_id = summary.artist_id,
        .row = row,
    };
    page.track_ids[position] = summary.id;
    return row;
}

fn explicitBadge() *gtk.Widget {
    const badge = gtk.gtk_label_new("E");
    gtk.gtk_widget_add_css_class(badge, "explicit-badge");
    gtk.gtk_widget_set_tooltip_text(badge, "Explicit");
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_CENTER);
    return badge;
}

fn caption(text: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(label, "artist-section-caption");
    gtk.gtk_widget_set_valign(label, gtk.ALIGN_BASELINE_FILL);
    return label;
}

fn sectionTitle(text: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_widget_add_css_class(label, "artist-section-title");
    gtk.gtk_widget_set_valign(label, gtk.ALIGN_BASELINE_FILL);
    return label;
}

fn spreadHeading(text: [*:0]const u8, note: [*:0]const u8) *gtk.Widget {
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(heading, "artist-section-heading");
    const title = sectionTitle(text);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), caption(note));
    return heading;
}

fn section(spacing: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, spacing);
    gtk.gtk_widget_add_css_class(box, "artist-section");
    return box;
}

fn tracksSection(page: *ArtistPage, top: []const liborca.TrackSummary, by_plays: bool) *gtk.Widget {
    const box = section(10);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), spreadHeading("Top Tracks", if (by_plays) "By your plays" else "By rating"));
    const list = gtk.gtk_list_box_new();
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_SINGLE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.false_);
    gtk.gtk_widget_add_css_class(list, "artist-tracks");
    _ = gtk.signalConnect(list, "row-selected", gtk.callback(trackSelected), page);
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(trackActivated), page);
    const keys = gtk.gtk_event_controller_key_new();
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(trackKeyPressed), page);
    gtk.gtk_widget_add_controller(list, keys);
    for (top, 0..) |summary, position| gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list), trackRow(page, summary, position, by_plays));
    page.track_count = top.len;
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), list);
    return box;
}

const ReleaseRow = struct {
    scope: albums.ArtistScope,
    count: u64,
    releases: liborca.ReleasePage,
    first_position: usize = 0,

    fn title(self: *const ReleaseRow) [*:0]const u8 {
        return if (self.scope == .appearances) "Appears On" else "Albums";
    }

    fn tooltip(self: *const ReleaseRow) [*:0]const u8 {
        return if (self.scope == .appearances) "Show the releases they appear on in Albums" else "Show their albums in Albums";
    }
};

fn loadReleaseRow(self: *App, library: liborca.LibraryHandle, artist_id: i64, scope: albums.ArtistScope, count: u64) ?ReleaseRow {
    if (count == 0) return null;
    var query: liborca.ReleaseQuery = if (scope == .appearances)
        .{ .appearing_artist_id = artist_id }
    else
        .{ .album_artist_id = artist_id, .own_releases_only = true };
    query.sort = .year;
    query.limit = if (scope == .appearances) appearance_limit else own_release_limit;
    const releases = self.runtime.libraryReleasePage(library, query) catch return null;
    return .{ .scope = scope, .count = count, .releases = releases };
}

fn albumsSection(page: *ArtistPage, row: *const ReleaseRow) *gtk.Widget {
    const box = section(14);
    const heading = spreadHeading(row.title(), "In your library");
    if (row.count > row.releases.items.len) {
        var buffer: [48]u8 = undefined;
        const see_all = gtk.gtk_button_new_with_label(strings.format(&buffer, "See all {d}", .{row.count}).ptr);
        gtk.gtk_widget_add_css_class(see_all, "flat");
        gtk.gtk_widget_add_css_class(see_all, "see-all");
        gtk.gtk_widget_set_valign(see_all, gtk.ALIGN_CENTER);
        gtk.gtk_widget_set_tooltip_text(see_all, row.tooltip());
        markPosition(see_all, @intFromEnum(row.scope));
        _ = gtk.signalConnect(see_all, "clicked", gtk.callback(releaseSeeAllClicked), page);
        gtk.gtk_box_append(gtk.cast(gtk.Box, heading), see_all);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);
    const flow = gtk.gtk_flow_box_new();
    const flow_box = gtk.cast(gtk.FlowBox, flow);
    gtk.gtk_flow_box_set_selection_mode(flow_box, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_min_children_per_line(flow_box, album_columns);
    gtk.gtk_flow_box_set_max_children_per_line(flow_box, album_columns);
    gtk.gtk_flow_box_set_homogeneous(flow_box, gtk.true_);
    gtk.gtk_flow_box_set_column_spacing(flow_box, 20);
    gtk.gtk_flow_box_set_row_spacing(flow_box, 20);
    gtk.gtk_flow_box_set_activate_on_single_click(flow_box, gtk.true_);
    gtk.gtk_widget_set_halign(flow, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(flow, "artist-albums");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(albumActivated), page);
    for (row.releases.items, row.first_position..) |release, position| gtk.gtk_flow_box_append(flow_box, albumTile(page, release, position));
    if (page.album_flow_count < page.album_flows.len) {
        page.album_flows[page.album_flow_count] = flow;
        page.album_flow_count += 1;
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), flow);
    return box;
}

fn launched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_uri_launcher_launch_finish(gtk.cast(gtk.UriLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open MusicBrainz");
}

fn launch(self: *App, url: [:0]const u8) void {
    const launcher = gtk.gtk_uri_launcher_new(url.ptr);
    gtk.gtk_uri_launcher_launch(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

fn elsewhereActivated(_: ?*anyopaque, child: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const tile = gtk.gtk_flow_box_child_get_child(gtk.cast(gtk.FlowBoxChild, child)) orelse return;
    const index = marked(tile) orelse return;
    if (index >= page.elsewhere.len) return;
    var buffer: [128]u8 = undefined;
    const url = strings.printZ(&buffer, musicbrainz_release_group_url ++ "{s}", .{page.elsewhere[index].mbid}) catch return;
    launch(page.self, url);
}

fn elsewhereCaption(buffer: []u8, group: liborca.ElsewhereRelease) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (group.credited_with) |names| writer.print("with {s}", .{names}) catch {};
    if (group.year) |year| {
        if (writer.end != 0) writer.writeAll(" · ") catch {};
        writer.print("{d}", .{year}) catch {};
    }
    if (writer.end == 0) writer.writeAll(group.primary_type orelse "") catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn elsewhereTile(page: *ArtistPage, group: liborca.ElsewhereRelease, position: usize) *gtk.Widget {
    const self = page.self;
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "elsewhere-tile");
    gtk.gtk_widget_set_size_request(tile, elsewhere_pixels, -1);
    markPosition(tile, position);

    const cover = art.newCover(self, gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0), elsewhere_pixels);
    gtk.gtk_widget_add_css_class(cover, "elsewhere-cover");
    const absent = gtk.gtk_label_new("No local files");
    gtk.gtk_widget_add_css_class(absent, "elsewhere-absent");
    gtk.gtk_widget_set_halign(absent, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(absent, gtk.ALIGN_CENTER);
    const frame = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, frame), cover);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, frame), absent);
    if (group.cover == .kept) {
        gtk.gtk_widget_add_css_class(tile, "covered");
        gtk.gtk_widget_set_valign(absent, gtk.ALIGN_END);
        gtk.gtk_widget_set_margin_bottom(absent, 8);
        art.show(self, cover, art.Key.releaseGroup(group.mbid, art.Size.atLeast(elsewhere_pixels)));
    }

    var buffer: [512]u8 = undefined;
    const title = tileLabel(strings.terminated(&buffer, if (group.title.len != 0) group.title else "Untitled").ptr, "tile-title");
    const detail = tileLabel(elsewhereCaption(&buffer, group).ptr, "tile-year");
    gtk.gtk_widget_add_css_class(detail, "numeric");
    for ([_]*gtk.Widget{ frame, title, detail }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, tile), piece);
    gtk.gtk_widget_set_tooltip_text(tile, "Open on MusicBrainz");
    return tile;
}

fn showElsewhere(page: *ArtistPage) void {
    const self = page.self;
    const section_box = page.elsewhere_section orelse return;
    const flow = page.elsewhere_flow orelse return;
    const library = self.library orelse return;
    gtk.gtk_flow_box_remove_all(gtk.cast(gtk.FlowBox, flow));
    freeElsewhere(page);
    page.elsewhere = self.runtime.libraryArtistElsewhere(library, self.allocator, page.artist_id) catch &.{};
    for (page.elsewhere, 0..) |group, position| gtk.gtk_flow_box_append(gtk.cast(gtk.FlowBox, flow), elsewhereTile(page, group, position));
    gtk.gtk_widget_set_visible(section_box, @intFromBool(page.elsewhere.len != 0));
}

fn elsewhereSection(page: *ArtistPage) *gtk.Widget {
    const box = section(12);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(heading, "artist-section-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), sectionTitle("Elsewhere"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), caption("From MusicBrainz · not in your library"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);
    const flow = gtk.gtk_flow_box_new();
    const flow_box = gtk.cast(gtk.FlowBox, flow);
    gtk.gtk_flow_box_set_selection_mode(flow_box, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_min_children_per_line(flow_box, 1);
    gtk.gtk_flow_box_set_max_children_per_line(flow_box, 12);
    gtk.gtk_flow_box_set_column_spacing(flow_box, 20);
    gtk.gtk_flow_box_set_row_spacing(flow_box, 20);
    gtk.gtk_flow_box_set_activate_on_single_click(flow_box, gtk.true_);
    gtk.gtk_widget_set_halign(flow, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(flow, "artist-elsewhere");
    _ = gtk.signalConnect(flow, "child-activated", gtk.callback(elsewhereActivated), page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), flow);
    gtk.gtk_widget_set_visible(box, gtk.false_);
    page.elsewhere_section = box;
    page.elsewhere_flow = flow;
    return box;
}

fn relatedClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const page = pageData(data);
    const index = marked(button) orelse return;
    if (index >= page.related_count) return;
    const related = page.related[index];
    if (related.library_artist_id) |id| return openArtist(page.self, page.navigation, id);
    var buffer: [128]u8 = undefined;
    const url = strings.printZ(&buffer, musicbrainz_artist_url ++ "{s}", .{related.mbid[0..related.mbid_len]}) catch return;
    launch(page.self, url);
}

fn relatedTile(page: *ArtistPage, related: liborca.RelatedArtist, position: usize) *gtk.Widget {
    const self = page.self;
    const button = gtk.gtk_button_new();
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "related-artist");
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 9);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_START);
    const cover = art.newCover(self, art.initialsPlaceholder(), related_pixels);
    gtk.gtk_widget_add_css_class(cover, "artist-photo");
    gtk.gtk_widget_add_css_class(cover, "related-artist-photo");
    art.setInitials(cover, related.name);
    const size = art.Size.atLeast(related_pixels);
    var shows_related_photo = false;
    if (related.library_artist_id) |id| {
        art.showArtist(self, cover, id, if (related.has_photo) .stored else .absent, null, size);
    } else if (related.has_photo) {
        shows_related_photo = art.showRelated(self, cover, related.mbid, size);
    }
    var buffer: [256]u8 = undefined;
    const name = gtk.gtk_label_new(strings.terminated(&buffer, related.name).ptr);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, name), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, name), gtk.WRAP_WORD);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, name), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_justify(gtk.cast(gtk.Label, name), gtk.JUSTIFY_CENTER);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, name), 10);
    gtk.gtk_widget_set_size_request(button, related_tile_pixels, -1);
    gtk.gtk_widget_add_css_class(name, "related-artist-name");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cover);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), name);
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), box);
    const action = if (related.library_artist_id != null) "Open in your library" else "Open on MusicBrainz";
    var tooltip: [640]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(button, relatedTooltip(self, related.mbid, shows_related_photo, action, &tooltip).ptr);
    markPosition(button, position);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(relatedClicked), page);
    return button;
}

fn relatedTooltip(self: *App, mbid: []const u8, shows_photo: bool, action: [:0]const u8, buffer: []u8) [:0]const u8 {
    if (!shows_photo) return action;
    const library = self.library orelse return action;
    var info = (self.runtime.libraryRelatedArtistPhotoInfo(library, mbid) catch return action) orelse return action;
    defer info.deinit();
    const author = std.mem.trim(u8, info.record.credit orelse "", " \n");
    const licence = std.mem.trim(u8, info.record.licence orelse "", " \n");
    if (author.len == 0 and licence.len == 0) return action;
    if (author.len != 0 and licence.len != 0) return strings.format(buffer, "{s}\nPhoto: {s} • {s}", .{ action, author, licence });
    return strings.format(buffer, "{s}\nPhoto: {s}", .{ action, if (author.len != 0) author else licence });
}

fn showRelated(page: *ArtistPage) void {
    const self = page.self;
    const section_box = page.related_section orelse return;
    const flow = page.related_flow orelse return;
    const library = self.library orelse return;
    gtk.gtk_flow_box_remove_all(gtk.cast(gtk.FlowBox, flow));
    page.related_count = 0;
    var related = self.runtime.libraryRelatedArtists(library, page.artist_id) catch {
        gtk.gtk_widget_set_visible(section_box, gtk.false_);
        return;
    };
    defer related.deinit();
    for (related.items) |item| {
        if (page.related_count == related_limit) break;
        if (item.mbid.len > 36) continue;
        var entry: Related = .{ .library_artist_id = item.library_artist_id, .mbid = undefined, .mbid_len = @intCast(item.mbid.len) };
        @memcpy(entry.mbid[0..item.mbid.len], item.mbid);
        page.related[page.related_count] = entry;
        gtk.gtk_flow_box_append(gtk.cast(gtk.FlowBox, flow), relatedTile(page, item, page.related_count));
        page.related_count += 1;
    }
    gtk.gtk_widget_set_visible(section_box, @intFromBool(page.related_count != 0));
}

fn relatedSection(page: *ArtistPage) *gtk.Widget {
    const box = section(14);
    const title = sectionTitle("Related Artists");
    gtk.gtk_widget_add_css_class(title, "artist-section-heading");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), title);
    const flow = gtk.gtk_flow_box_new();
    const flow_box = gtk.cast(gtk.FlowBox, flow);
    gtk.gtk_flow_box_set_selection_mode(flow_box, gtk.SELECTION_NONE);
    gtk.gtk_flow_box_set_min_children_per_line(flow_box, 2);
    gtk.gtk_flow_box_set_max_children_per_line(flow_box, related_limit);
    gtk.gtk_flow_box_set_column_spacing(flow_box, 26);
    gtk.gtk_flow_box_set_row_spacing(flow_box, 16);
    gtk.gtk_widget_set_halign(flow, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(flow, "related-artists");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), flow);
    gtk.gtk_widget_set_visible(box, gtk.false_);
    page.related_section = box;
    page.related_flow = flow;
    return box;
}

fn playableTracks(self: *App, library: liborca.LibraryHandle, artist_id: i64) std.ArrayList(i64) {
    var tracks: std.ArrayList(i64) = .empty;
    var offset: u32 = 0;
    while (tracks.items.len < queue_limit) {
        var page = self.runtime.libraryTrackQuery(library, "", .{
            .artist_id = artist_id,
            .sort = .album,
            .limit = app.page_size,
            .offset = offset,
        }) catch break;
        defer page.deinit();
        for (page.items) |item| {
            if (!item.has_playable_file or tracks.items.len == queue_limit) continue;
            tracks.append(self.allocator, item.id) catch {};
        }
        if (page.items.len < app.page_size) break;
        offset += app.page_size;
    }
    return tracks;
}

fn showGenres(page: *ArtistPage) void {
    const self = page.self;
    const box = page.genres orelse return;
    const library = self.library orelse return;
    while (gtk.gtk_widget_get_first_child(box)) |child| gtk.gtk_box_remove(gtk.cast(gtk.Box, box), child);
    const genres = self.runtime.libraryArtistGenres(library, page.artist_id, 3) catch {
        gtk.gtk_widget_set_visible(box, gtk.false_);
        return;
    };
    defer genres.deinit();
    var buffer: [256]u8 = undefined;
    for (genres.items, 0..) |genre, index| {
        if (index != 0) {
            const separator = gtk.gtk_label_new("·");
            gtk.gtk_widget_add_css_class(separator, "artist-genre-separator");
            gtk.gtk_box_append(gtk.cast(gtk.Box, box), separator);
        }
        const label = gtk.gtk_label_new(strings.terminated(&buffer, genre.name).ptr);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_add_css_class(label, "artist-genre");
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), label);
    }
    gtk.gtk_widget_set_visible(box, @intFromBool(genres.items.len != 0));
}

fn showPhoto(page: *ArtistPage) void {
    const self = page.self;
    const photo = page.photo orelse return;
    art.showArtist(self, photo, page.artist_id, .unknown, artists.mostPlayedRelease(self, page.artist_id), art.Size.atLeast(photo_pixels));
}

fn biographyCredit(buffer: []u8, record: liborca.ArtistInfoRecord) [:0]const u8 {
    const licence = std.mem.trim(u8, record.biography_licence orelse "", " \n");
    if (record.biography_source == null) return "";
    if (licence.len == 0) return "From Wikipedia";
    return strings.format(buffer, "From Wikipedia · {s}", .{licence});
}

fn showInfo(page: *ArtistPage) bool {
    const self = page.self;
    showPhoto(page);
    showGenres(page);
    showRelated(page);
    showElsewhere(page);
    const library = self.library orelse return true;
    var stored = (self.runtime.libraryArtistInfo(library, page.artist_id) catch return true) orelse {
        if (page.biography) |biography| gtk.gtk_widget_set_visible(biography, gtk.false_);
        return false;
    };
    defer stored.deinit();
    const record = stored.record;

    const text = std.mem.trim(u8, record.biography orelse "", " \n");
    if (page.biography) |biography| gtk.gtk_widget_set_visible(biography, @intFromBool(text.len != 0));
    if (page.biography_credit) |credit| {
        var buffer: [256]u8 = undefined;
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, credit), biographyCredit(&buffer, record).ptr);
    }
    if (page.biography_text) |old| self.allocator.free(old);
    page.biography_text = null;
    if (text.len == 0) return true;
    page.biography_text = self.allocator.dupeZ(u8, text) catch return true;
    if (page.biography_label) |label| {
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), page.biography_text.?.ptr);
        gtk.gtk_label_set_lines(gtk.cast(gtk.Label, label), biography_lines);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    }
    if (page.biography_credit) |credit| gtk.gtk_widget_set_visible(credit, gtk.false_);
    page.biography_width = 0;
    queueBiographyFit(page);
    return true;
}

fn newPhoto(page: *ArtistPage) *gtk.Widget {
    const photo = art.newFillingCover(page.self, art.initialsPlaceholder());
    for ([_][*:0]const u8{ "cover", "artist-hero-photo" }) |class| gtk.gtk_widget_add_css_class(photo, class);
    gtk.gtk_widget_set_size_request(photo, photo_pixels, photo_pixels);
    gtk.gtk_widget_set_halign(photo, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(photo, gtk.ALIGN_CENTER);
    art.setInitials(photo, page.name);
    menu.onSecondaryClick(photo, heroMenu, page);
    page.photo = photo;
    return photo;
}

fn clampSquare(child: *gtk.Widget, pixels: c_int) *gtk.Widget {
    var widget = child;
    for ([_]c_int{ gtk.ORIENTATION_VERTICAL, gtk.ORIENTATION_HORIZONTAL }) |orientation| {
        const clamp = adw.adw_clamp_new();
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, clamp), orientation);
        adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), pixels);
        adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), pixels);
        adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), widget);
        gtk.gtk_widget_set_halign(clamp, gtk.ALIGN_START);
        gtk.gtk_widget_set_valign(clamp, gtk.ALIGN_CENTER);
        widget = clamp;
    }
    return widget;
}

fn newBiography(page: *ArtistPage) *gtk.Widget {
    const label = gtk.gtk_label_new("");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1000);
    gtk.gtk_widget_add_css_class(label, "artist-biography-text");
    _ = gtk.signalConnect(label, "activate-link", gtk.callback(biographyLinkActivated), page);
    page.biography_label = label;
    const credit = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, credit), 0.0);
    gtk.gtk_widget_add_css_class(credit, "artist-biography-credit");
    page.biography_credit = credit;
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for ([_]*gtk.Widget{ label, credit }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    const measure = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, measure), biography_max_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, measure), biography_max_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, measure), box);
    gtk.gtk_widget_set_halign(measure, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(measure, "artist-biography");
    gtk.gtk_widget_set_visible(measure, gtk.false_);
    page.biography = measure;
    return measure;
}

fn newHero(page: *ArtistPage) *gtk.Widget {
    const hero = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 36);
    gtk.gtk_widget_add_css_class(hero, "artist-hero");
    page.hero = hero;
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), clampSquare(newPhoto(page), photo_pixels));

    const facts = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(facts, "artist-facts");
    gtk.gtk_widget_set_valign(facts, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(facts, gtk.true_);
    const kind = gtk.gtk_label_new("Artist");
    gtk.gtk_widget_add_css_class(kind, "artist-overline");
    const title = gtk.gtk_label_new(page.name.ptr);
    gtk.gtk_widget_add_css_class(title, "artist-hero-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, title), gtk.true_);
    menu.onSecondaryClick(title, heroMenu, page);
    for ([_]*gtk.Widget{ kind, title }) |label| {
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, facts), label);
    }
    const genres = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(genres, "artist-genres");
    page.genres = genres;
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), genres);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), newBiography(page));

    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "album-actions");
    gtk.gtk_widget_add_css_class(actions, "artist-actions");
    const play_button = albums.pill("Play", "orca-play-symbolic", true);
    const shuffle = albums.pill("Shuffle", "orca-shuffle-symbolic", false);
    _ = gtk.signalConnect(play_button, "clicked", gtk.callback(playClicked), page);
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), page);
    const heart = feedback.newAlbumButton(gtk.callback(loveClicked), page);
    feedback.showArtistButton(heart, page.loved);
    page.love_button = heart;
    const more = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "album-more");
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(heroMoreClicked), page);
    for ([_]*gtk.Widget{ play_button, shuffle, heart, more }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    gtk.gtk_box_append(gtk.cast(gtk.Box, facts), actions);
    gtk.gtk_box_append(gtk.cast(gtk.Box, hero), facts);
    gtk.g_object_set_data(hero, "orca-play", play_button);
    return hero;
}

const TopTracks = struct {
    page: liborca.TrackPage,
    count: usize,
    by_plays: bool,

    fn items(self: *const TopTracks) []const liborca.TrackSummary {
        return self.page.items[0..self.count];
    }
};

fn topTracks(self: *App, library: liborca.LibraryHandle, artist_id: i64) ?TopTracks {
    const played = self.runtime.libraryTrackQuery(library, "", .{
        .artist_id = artist_id,
        .sort = .play_count,
        .direction = .descending,
        .limit = top_track_limit,
    }) catch return null;
    var count: usize = 0;
    while (count < played.items.len and played.items[count].play_count != 0) count += 1;
    if (count != 0) return .{ .page = played, .count = count, .by_plays = true };
    played.deinit();
    const rated = self.runtime.libraryTrackQuery(library, "", .{
        .artist_id = artist_id,
        .sort = .rating,
        .direction = .descending,
        .limit = top_track_limit,
    }) catch return null;
    return .{ .page = rated, .count = rated.items.len, .by_plays = false };
}

pub fn openArtist(self: *App, navigation: *adw.NavigationView, artist_id: i64) void {
    if (self.open_artist_page_count == self.open_artist_pages.len) return self.toast("Too many artist pages are open; go back to close one");
    const library = self.library orelse return;
    const artist = (self.runtime.libraryArtist(library, artist_id) catch null) orelse return;
    defer artist.deinit(self.allocator);
    const totals = (self.runtime.libraryArtistTotals(library, artist_id) catch null) orelse return;
    var rows_buffer: [2]ReleaseRow = undefined;
    var row_count: usize = 0;
    defer for (rows_buffer[0..row_count]) |*row| row.releases.deinit();
    var release_total: usize = 0;
    for ([_]albums.ArtistScope{ .albums, .appearances }) |scope| {
        const count: u64 = if (scope == .appearances) totals.appearance_count else totals.release_count;
        var row = loadReleaseRow(self, library, artist_id, scope, count) orelse continue;
        row.first_position = release_total;
        release_total += row.releases.items.len;
        rows_buffer[row_count] = row;
        row_count += 1;
    }
    const rows = rows_buffer[0..row_count];
    const top = topTracks(self, library, artist_id) orelse return;
    defer top.page.deinit();
    var tracks = playableTracks(self, library, artist_id);
    defer tracks.deinit(self.allocator);

    const page = self.allocator.create(ArtistPage) catch return;
    page.* = .{
        .self = self,
        .navigation = navigation,
        .artist_id = artist_id,
        .name = undefined,
        .tracks = &.{},
        .releases = &.{},
        .loved = self.runtime.libraryArtistLoved(library, artist_id) catch artist.loved,
    };
    page.name = self.allocator.dupeSentinel(u8, if (artist.name.len != 0) artist.name else "Unknown Artist", 0) catch {
        self.allocator.destroy(page);
        return;
    };
    page.tracks = tracks.toOwnedSlice(self.allocator) catch {
        self.allocator.free(page.name);
        self.allocator.destroy(page);
        return;
    };
    page.releases = self.allocator.alloc(i64, release_total) catch {
        self.allocator.free(page.name);
        self.allocator.free(page.tracks);
        self.allocator.destroy(page);
        return;
    };
    for (rows) |*row| {
        for (row.releases.items, page.releases[row.first_position..][0..row.releases.items.len]) |release, *id| id.* = release.id;
    }

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 36);
    gtk.gtk_widget_add_css_class(column, "artist-page");
    const hero = newHero(page);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), hero);

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_layout_manager(sections, gtk.gtk_custom_layout_new(null, measureSections, allocateSections));
    gtk.gtk_widget_add_css_class(sections, "artist-sections");
    page.sections = sections;
    if (top.count != 0) gtk.gtk_box_append(gtk.cast(gtk.Box, sections), tracksSection(page, top.items(), top.by_plays));
    const side = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 28);
    gtk.gtk_widget_set_halign(side, gtk.ALIGN_START);
    for (rows) |*row| gtk.gtk_box_append(gtk.cast(gtk.Box, side), albumsSection(page, row));
    gtk.gtk_box_append(gtk.cast(gtk.Box, sections), side);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), sections);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), elsewhereSection(page));
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), relatedSection(page));
    layOut(page);
    _ = showInfo(page);
    if (self.fetch_artist_info) requestInfo(self, artist_id, false);

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), content_max_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), content_max_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), column);
    gtk.gtk_widget_set_halign(clamp, gtk.ALIGN_FILL);
    const layers = gtk.gtk_overlay_new();
    const backdrop = art.newBackdrop(self, .header);
    art.showBackdrop(self, backdrop, &.{page.photo.?});
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), backdrop);
    gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), clamp);
    gtk.gtk_overlay_set_measure_overlay(gtk.cast(gtk.Overlay, layers), clamp, gtk.true_);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), layers);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(pageDestroyed), page);
    _ = gtk.signalConnect(gtk.gtk_scrolled_window_get_hadjustment(gtk.cast(gtk.ScrolledWindow, scroller)), "changed", gtk.callback(pageResized), page);
    page.scroller = scroller;
    page_ui.extendUnderBar(self, scroller, scroller);
    registerPage(page);
    markPlaying(self, self.shown_track_id);

    const pushed = adw.adw_navigation_page_new(scroller, page.name.ptr);
    window.markPushed(pushed, .{ .artist = artist_id });
    adw.adw_navigation_view_push(navigation, pushed);
    if (gtk.g_object_get_data(hero, "orca-play")) |play_button| _ = gtk.gtk_widget_grab_focus(gtk.cast(gtk.Widget, play_button));
}

pub fn infoPending(self: *const App, artist_id: i64) bool {
    const info = &self.artist_info;
    for (info.pending[0..info.pending_count]) |pending| {
        if (pending.artist_id == artist_id) return true;
    }
    return false;
}

pub fn infoMissing(record: ?liborca.ArtistInfoRecord) bool {
    const found = record orelse return true;
    const outcome = std.enums.fromInt(liborca.ArtistInfoOutcome, found.outcome) orelse return true;
    return !infoSettled(outcome);
}

pub fn infoSettled(outcome: liborca.ArtistInfoOutcome) bool {
    return switch (outcome) {
        .fetched, .cached, .no_musicbrainz_id, .not_found => true,
        else => false,
    };
}

pub fn requestInfo(self: *App, artist_id: i64, force: bool) void {
    const info = &self.artist_info;
    if (info.closed or infoPending(self, artist_id)) return;
    if (!force and info.requested.contains(artist_id)) return;
    const library = self.library orelse return;
    if (info.pending_count == info.pending.len) return self.toast("Too many artist lookups are running; try again shortly");
    const job = self.runtime.startArtistInfoFetch(library, artist_id, .{ .force = force }) catch
        return self.toast("Could not look this artist up");
    info.requested.put(self.allocator, artist_id, {}) catch {};
    info.pending[info.pending_count] = .{ .artist_id = artist_id, .job = job };
    info.pending_count += 1;
}

pub fn tick(self: *App) void {
    const info = &self.artist_info;
    var index: usize = 0;
    while (index < info.pending_count) {
        const pending = &info.pending[index];
        if (self.runtime.jobSnapshotSynced(pending.job)) |snapshot| switch (snapshot.state) {
            .succeeded, .failed, .cancelled => {},
            else => {
                const stores = self.runtime.jobArtistInfoStores(pending.job) catch pending.stores;
                if (stores != pending.stores) {
                    pending.stores = stores;
                    refreshInfo(self, pending.artist_id);
                }
                index += 1;
                continue;
            },
        } else |_| {}
        const finished = pending.*;
        info.pending_count -= 1;
        info.pending[index] = info.pending[info.pending_count];
        const outcome = self.runtime.jobArtistInfoOutcome(finished.job) catch .not_requested;
        if (!infoSettled(outcome)) _ = info.requested.remove(finished.artist_id);
        refreshInfo(self, finished.artist_id);
    }
}

fn refreshInfo(self: *App, artist_id: i64) void {
    art.refreshArtist(self, artist_id);
    for (self.open_artist_pages[0..self.open_artist_page_count]) |page| {
        if (page.artist_id == artist_id) _ = showInfo(page);
    }
    details.artistInfoChanged(self, artist_id);
}

pub fn shutdown(self: *App) void {
    const info = &self.artist_info;
    info.closed = true;
    for (info.pending[0..info.pending_count]) |pending| self.runtime.cancelJob(pending.job) catch {};
    info.pending_count = 0;
}

pub fn forgetLibrary(self: *App) void {
    const info = &self.artist_info;
    for (info.pending[0..info.pending_count]) |pending| self.runtime.cancelJob(pending.job) catch {};
    info.pending_count = 0;
    info.requested.clearRetainingCapacity();
}
