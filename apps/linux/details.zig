//! The inspector: the window's one panel at the end of every page that shows
//! one Track's details, the playing Track's lyrics, or the playing audio's
//! signal path.
//!
//! liborca answers `libraryTrackDetails` and `playerSignalPath`; this only
//! words the answers. Its mode is kept on the `App`: hidden, details, lyrics
//! or signal path. The window tells it which page's Tracks to follow with
//! `setSource`. It queries details only when the Track it shows changes, and
//! is handed the signal path whenever `transport.refreshSignalPath` reads it.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const signal_path = @import("signal_path.zig");
const track_table = @import("track_table.zig");
const matches = @import("matches.zig");
const jobs = @import("jobs.zig");
const lyrics = @import("lyrics.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");
const nowplaying = @import("nowplaying.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");

const App = app.App;

const inspector_width: f64 = 420;
const key_width = 98;
const separator = " · ";
const minus = "−";

const proposal_slots = 3;
const remembered_choice_limit = 32;

/// Where the inspector finds the Track it shows when nobody has chosen one.
pub const Source = union(enum) {
    selection: *gtk.SelectionModel,
    /// A playlist's selected row, else the playlist itself.
    playlist: PlaylistSource,
    /// The row last chosen, else the playing Track if it is one of these.
    ids: []const i64,
    /// As `ids`, else the album itself.
    album: AlbumSource,
    /// As `ids`, else the artist itself.
    artist: ArtistSource,
    playing,

    fn trackIds(source: Source) ?[]const i64 {
        return switch (source) {
            .ids => |values| values,
            .album => |album| album.ids,
            .artist => |artist| artist.ids,
            .selection, .playlist, .playing => null,
        };
    }
};

pub const PlaylistSource = struct {
    selection: *gtk.SelectionModel,
    playlist_id: i64,
};

pub const AlbumSource = struct {
    ids: []const i64,
    release_id: i64,
};

pub const ArtistSource = struct {
    ids: []const i64,
    artist_id: i64,
};

const ChoicePage = union(enum) {
    album: i64,
    artist: i64,
    genre: i64,
};

const RememberedChoice = struct {
    page: ChoicePage,
    track_id: i64,
};

const Row = struct {
    root: *gtk.Widget,
    value: *gtk.Label,
};

const LinkRow = struct {
    root: *gtk.Widget,
    value: *gtk.Label,
    link: *gtk.Widget,
    link_label: *gtk.Label,
};

const Proposal = struct {
    root: *gtk.Widget,
    title: *gtk.Label,
    subtitle: *gtk.Label,
    accept: *gtk.Widget,
    dismiss: *gtk.Widget,
};

const StageView = struct {
    tag: *gtk.Label,
    lines: *gtk.Label,
    tech: *gtk.Label,
    revealer: *gtk.Widget,
    chevron: *gtk.Widget,
};

pub const Panel = struct {
    self: *App,
    source: Source = .playing,
    /// The mode last laid out, so the signal path is read only on opening it.
    laid_out: app.Sidebar = .hidden,
    split: *gtk.Widget,
    root: *gtk.Widget,
    lyrics: lyrics.View = undefined,
    placeholder: *gtk.Widget,
    content: *gtk.Widget,
    title: *gtk.Widget,
    artist: *gtk.Widget,
    album: *gtk.Widget,
    audio_section: *gtk.Widget,
    format_row: Row,
    sample_rate_row: Row,
    channels_row: Row,
    bitrate_row: Row,
    duration_row: Row,
    loudness_missing: Row,
    integrated_row: Row,
    peak_row: Row,
    replay_gain_row: Row,
    musicbrainz_row: LinkRow,
    acoustid_row: Row,
    match_status: Row,
    identifiers_button: *gtk.Widget,
    identifiers: *gtk.Widget,
    recording_row: Row,
    release_id_row: Row,
    release_group_id_row: Row,
    release_track_id_row: Row,
    album_artist_id_row: Row,
    proposals: [proposal_slots]Proposal,
    proposal_ids: [proposal_slots]i64 = @splat(0),
    review_button: *gtk.Widget,
    find_button: *gtk.Widget,
    verify_button: *gtk.Widget,
    metadata_section: *gtk.Widget,
    album_artist_row: Row,
    date_row: Row,
    genre_row: Row,
    track_row: Row,
    disc_row: Row,
    compilation_row: Row,
    explicit_row: Row,
    plays_row: Row,
    last_played_row: Row,
    folder_row: Row,
    file_row: Row,
    size_row: Row,
    modified_row: Row,
    added_row: Row,
    copy_button: *gtk.Widget,
    album_view: Album,
    signal_status: *gtk.Label,
    signal_content: *gtk.Widget,
    signal_dot: *gtk.Widget,
    signal_verdict_label: *gtk.Label,
    signal_chain_label: *gtk.Label,
    signal_stages: [signal_path.all_stages.len]StageView,
    signal_footer_label: *gtk.Label,
    signal_block_frames: ?u32 = null,
    /// The Track on screen, and whether that is stale since the library changed.
    shown: ?i64 = null,
    stale: bool = false,
    chosen: ?i64 = null,
    remembered: [remembered_choice_limit]RememberedChoice = undefined,
    remembered_count: usize = 0,
    path: ?[:0]u8 = null,
    artist_view: Artist,
    /// Shows the Artist even while one of the page's Tracks plays, until a
    /// Track is chosen.
    artist_pinned: bool = false,
    playlist_view: PlaylistView,
};

const PlaylistView = struct {
    content: *gtk.Widget,
    title: *gtk.Widget,
    subtitle: *gtk.Widget,
    creator: *gtk.Widget,
    tracks_row: Row,
    unavailable_row: Row,
    duration_row: Row,
    mixed_row: Row,
    genre_row: Row,
    created_row: Row,
    updated_row: Row,
    description_section: *gtk.Widget,
    description: *gtk.Widget,
    tags_section: *gtk.Widget,
    tags: *gtk.Widget,
};

const Album = struct {
    content: *gtk.Widget,
    title: *gtk.Widget,
    artist_row: Row,
    date_row: Row,
    genre_row: Row,
    tracks_row: Row,
    duration_row: Row,
    format_row: Row,
    identity_section: *gtk.Widget,
    musicbrainz_row: Row,
    description_section: *gtk.Widget,
    description: *gtk.Widget,
};

const Artist = struct {
    content: *gtk.Widget,
    title: *gtk.Widget,
    genre_row: Row,
    years_row: Row,
    albums_row: Row,
    tracks_row: Row,
    library_row: Row,
    biography_section: *gtk.Widget,
    biography: *gtk.Widget,
    biography_link: *gtk.Widget,
    biography_licence: *gtk.Widget,
    links_section: *gtk.Widget,
    links: *gtk.Widget,
    fetch: *gtk.Widget,
};

const link_order = [_]liborca.ArtistLinkKind{
    .official, .wikipedia, .musicbrainz, .discogs,  .bandcamp, .soundcloud,
    .youtube,  .spotify,   .apple_music, .tidal,    .deezer,   .instagram,
    .x,        .facebook,  .tiktok,      .wikidata, .lastfm,
};

fn linkName(kind: liborca.ArtistLinkKind) [*:0]const u8 {
    return switch (kind) {
        .official => "Official Website",
        .wikipedia => "Wikipedia",
        .wikidata => "Wikidata",
        .musicbrainz => "MusicBrainz",
        .discogs => "Discogs",
        .lastfm => "Last.fm",
        .bandcamp => "Bandcamp",
        .soundcloud => "SoundCloud",
        .youtube => "YouTube",
        .spotify => "Spotify",
        .apple_music => "Apple Music",
        .tidal => "TIDAL",
        .deezer => "Deezer",
        .instagram => "Instagram",
        .x => "X (Twitter)",
        .facebook => "Facebook",
        .tiktok => "TikTok",
        .other => "Website",
    };
}

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn panelData(data: ?*anyopaque) *Panel {
    return @ptrCast(@alignCast(data.?));
}

fn overlays(self: *const App) bool {
    return self.window_narrow or self.header_compact or self.inspector_crowded;
}

pub fn shownMode(self: *const App) app.Sidebar {
    if (overlays(self) and !self.inspector_overlaid) return .hidden;
    return self.sidebar_page;
}

pub fn setNarrow(self: *App, narrow: bool) void {
    self.window_narrow = narrow;
    self.inspector_overlaid = false;
    applyVisibility(self);
}

pub fn refit(self: *App) void {
    self.inspector_overlaid = false;
    applyVisibility(self);
}

pub fn toggle(self: *App) void {
    showSidebar(self, if (shownMode(self) == .details) .hidden else .details);
}

pub fn toggleSignalPath(self: *App) void {
    showSidebar(self, if (shownMode(self) == .signal_path) .hidden else .signal_path);
}

pub fn showSidebar(self: *App, sidebar: app.Sidebar) void {
    if (sidebar == shownMode(self)) return;
    if (sidebar == .hidden and overlays(self)) {
        self.inspector_overlaid = false;
    } else {
        self.inspector_overlaid = true;
        if (sidebar != self.sidebar_page) {
            self.sidebar_page = sidebar;
            settings.save(self);
        }
    }
    applyVisibility(self);
}

pub fn revealSignalPath(self: *App) bool {
    const panel = self.inspector orelse return false;
    if (gtk.gtk_widget_get_mapped(panel.split) == 0) return false;
    showSidebar(self, .signal_path);
    return true;
}

fn pageName(mode: app.Sidebar) [*:0]const u8 {
    return switch (mode) {
        .hidden, .details => "details",
        .lyrics => "lyrics",
        .signal_path => "signal_path",
    };
}

pub fn applyVisibility(self: *App) void {
    const mode = shownMode(self);
    var opened_signal_path = false;
    if (self.inspector) |panel| {
        opened_signal_path = mode == .signal_path and panel.laid_out != .signal_path;
        panel.laid_out = mode;
        showMode(panel, mode);
        update(panel);
    }
    nowplaying.placePanel(self);
    lyrics.sync(self);
    if (opened_signal_path) transport.refreshSignalPath(self);
}

fn showMode(panel: *Panel, mode: app.Sidebar) void {
    const split = gtk.cast(adw.OverlaySplitView, panel.split);
    if (mode != .hidden) gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, panel.root), pageName(mode));
    adw.adw_overlay_split_view_set_collapsed(split, boolean(overlays(panel.self)));
    adw.adw_overlay_split_view_set_show_sidebar(split, boolean(mode != .hidden));
}

fn sidebarShownChanged(split: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const shown = adw.adw_overlay_split_view_get_show_sidebar(gtk.cast(adw.OverlaySplitView, split)) != 0;
    if (!shown and shownMode(panel.self) != .hidden) showSidebar(panel.self, .hidden);
}

/// The library changed under the inspector: what it shows may no longer be true.
pub fn invalidate(self: *App) void {
    const panel = self.inspector orelse return;
    panel.stale = true;
    update(panel);
}

pub fn tick(self: *App) void {
    const library = self.library orelse return;
    const recorded = self.runtime.libraryListensRecorded(library) catch return;
    if (recorded == self.seen_recorded_listens) return;
    self.seen_recorded_listens = recorded;
    invalidate(self);
}

/// The playing Track changed.
pub fn trackChanged(self: *App) void {
    update(self.inspector orelse return);
}

/// Follows `source` from now on, showing the Track last chosen on that
/// album, artist or genre page while it is still one of its Tracks.
pub fn setSource(self: *App, source: Source) void {
    const panel = self.inspector orelse return;
    if (std.meta.eql(panel.source, source)) return;
    panel.source = source;
    panel.chosen = recalledChoice(panel);
    panel.artist_pinned = false;
    panel.stale = true;
    update(panel);
}

/// Called as a page whose Tracks are `ids` is freed, so the inspector never
/// holds them after.
pub fn forgetIds(self: *App, ids: []const i64) void {
    const panel = self.inspector orelse return;
    const followed = panel.source.trackIds() orelse return;
    if (followed.ptr != ids.ptr) return;
    panel.source = .playing;
    panel.chosen = null;
    panel.stale = true;
    if (gtk.gtk_widget_get_mapped(panel.split) != 0) {
        window.syncInspector(self);
        update(panel);
    }
}

pub fn selectionChanged(model: ?*anyopaque, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const panel = state(data).inspector orelse return;
    const selection: *gtk.SelectionModel = switch (panel.source) {
        .selection => |selection| selection,
        .playlist => |playlist| playlist.selection,
        .ids, .album, .artist, .playing => return,
    };
    if (@as(?*anyopaque, selection) == model) update(panel);
}

/// Shows `track_id`, chosen in the page whose Tracks are `ids`, while the
/// inspector follows that page.
pub fn choose(self: *App, ids: []const i64, track_id: i64) void {
    const panel = self.inspector orelse return;
    const followed = panel.source.trackIds() orelse return;
    if (followed.ptr != ids.ptr) return;
    panel.chosen = track_id;
    panel.artist_pinned = false;
    if (choicePage(panel)) |page| rememberChoice(panel, page, track_id);
    update(panel);
}

fn choicePage(panel: *const Panel) ?ChoicePage {
    return switch (panel.source) {
        .album => |album| .{ .album = album.release_id },
        .artist => |artist| .{ .artist = artist.artist_id },
        .ids => |ids| {
            const genres = &panel.self.genres;
            if (ids.ptr != genres.track_ids[0..].ptr) return null;
            return .{ .genre = (genres.current orelse return null).id };
        },
        .selection, .playlist, .playing => null,
    };
}

fn rememberedIndex(panel: *const Panel, page: ChoicePage) ?usize {
    for (panel.remembered[0..panel.remembered_count], 0..) |choice, index| {
        if (std.meta.eql(choice.page, page)) return index;
    }
    return null;
}

fn forgetChoice(panel: *Panel, page: ChoicePage) void {
    const index = rememberedIndex(panel, page) orelse return;
    std.mem.copyForwards(
        RememberedChoice,
        panel.remembered[index .. panel.remembered_count - 1],
        panel.remembered[index + 1 .. panel.remembered_count],
    );
    panel.remembered_count -= 1;
}

fn rememberChoice(panel: *Panel, page: ChoicePage, track_id: i64) void {
    forgetChoice(panel, page);
    if (panel.remembered_count == panel.remembered.len) forgetChoice(panel, panel.remembered[0].page);
    panel.remembered[panel.remembered_count] = .{ .page = page, .track_id = track_id };
    panel.remembered_count += 1;
}

pub fn releaseMoved(self: *App, old_id: i64, new_id: i64) void {
    const panel = self.inspector orelse return;
    const index = rememberedIndex(panel, .{ .album = old_id }) orelse return;
    const track_id = panel.remembered[index].track_id;
    forgetChoice(panel, .{ .album = old_id });
    rememberChoice(panel, .{ .album = new_id }, track_id);
}

fn recalledChoice(panel: *const Panel) ?i64 {
    const page = choicePage(panel) orelse return null;
    const track_id = panel.remembered[rememberedIndex(panel, page) orelse return null].track_id;
    const ids = panel.source.trackIds() orelse return null;
    return if (std.mem.indexOfScalar(i64, ids, track_id) != null) track_id else null;
}

fn wantedTrack(panel: *Panel) ?i64 {
    const self = panel.self;
    switch (panel.source) {
        .selection => |selection| return track_table.firstSelected(selection) orelse self.shown_track_id,
        .playlist => |playlist| return track_table.firstSelected(playlist.selection),
        .ids, .album, .artist => {
            if (panel.chosen) |chosen| return chosen;
            if (panel.artist_pinned) return null;
            const playing = self.shown_track_id orelse return null;
            for (panel.source.trackIds().?) |id| if (id == playing) return playing;
            return null;
        },
        .playing => return self.shown_track_id,
    }
}

fn update(panel: *Panel) void {
    if (shownMode(panel.self) != .details) return;
    const wanted = wantedTrack(panel);
    if (!panel.stale and optionalEql(wanted, panel.shown)) return;
    panel.stale = false;
    panel.shown = wanted;
    show(panel, wanted);
}

fn show(panel: *Panel, track_id: ?i64) void {
    const self = panel.self;
    const library = self.library orelse return showPlaceholder(panel);
    const id = track_id orelse return showAlbumOrPlaceholder(panel);
    const details = (self.runtime.libraryTrackDetails(library, id) catch null) orelse
        return showPlaceholder(panel);
    defer details.deinit();
    populate(panel, details);
    showOnly(panel, panel.content);
}

fn showOnly(panel: *Panel, shown: *gtk.Widget) void {
    for ([_]*gtk.Widget{ panel.placeholder, panel.content, panel.album_view.content, panel.artist_view.content, panel.playlist_view.content }) |view|
        gtk.gtk_widget_set_visible(view, boolean(view == shown));
}

fn showPlaceholder(panel: *Panel) void {
    showOnly(panel, panel.placeholder);
    setPath(panel, null);
}

fn showAlbumOrPlaceholder(panel: *Panel) void {
    switch (panel.source) {
        .playlist => |playlist| {
            if (!populatePlaylist(panel, playlist.playlist_id)) return showPlaceholder(panel);
            showOnly(panel, panel.playlist_view.content);
        },
        .artist => |artist| {
            if (!populateArtist(panel, artist.artist_id)) return showPlaceholder(panel);
            showOnly(panel, panel.artist_view.content);
        },
        .album => |album| {
            if (!populateAlbum(panel, album.release_id)) return showPlaceholder(panel);
            showOnly(panel, panel.album_view.content);
        },
        .selection, .ids, .playing => return showPlaceholder(panel),
    }
    setPath(panel, null);
}

fn populateAlbum(panel: *Panel, release_id: i64) bool {
    const self = panel.self;
    const library = self.library orelse return false;
    const release = (self.runtime.libraryRelease(library, release_id) catch null) orelse return false;
    defer release.deinit(self.allocator);
    const album = panel.album_view;
    var buffer: [1024]u8 = undefined;
    const title = if (release.title.len != 0) release.title else "Unknown album";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, album.title), strings.terminated(&buffer, title).ptr);

    _ = setRow(album.artist_row, if (release.album_artist.len != 0) strings.terminated(&buffer, release.album_artist) else null);
    var date_buffer: [64]u8 = undefined;
    _ = setRow(album.date_row, if (release.release_date) |date| (if (date.len != 0) strings.terminated(&date_buffer, date) else null) else null);
    var genre_buffer: [256]u8 = undefined;
    _ = setRow(album.genre_row, albumGenres(panel, release_id, &genre_buffer));
    var tracks_buffer: [32]u8 = undefined;
    _ = setRow(album.tracks_row, strings.format(&tracks_buffer, "{d}", .{release.track_count}));
    var duration_buffer: [32]u8 = undefined;
    _ = setRow(album.duration_row, if (release.total_duration_ms > 0)
        strings.format(&duration_buffer, "{d} min", .{albums.minutesOf(release.total_duration_ms)})
    else
        null);
    var format_buffer: [64]u8 = undefined;
    const format = albums.releaseFormat(&format_buffer, &release);
    _ = setRow(album.format_row, if (format.len != 0) format else null);

    var stored = self.runtime.libraryReleaseInfo(library, release_id) catch null;
    defer if (stored) |*info| info.deinit();
    const record = if (stored) |info| info.record else null;
    gtk.gtk_widget_set_visible(album.identity_section, boolean(record != null));
    if (record) |found| _ = setRow(album.musicbrainz_row, if (found.musicbrainz_release_id != null) "Matched" else "Not matched");
    const description: []const u8 = if (record) |found| found.description orelse "" else "";
    gtk.gtk_widget_set_visible(album.description_section, boolean(description.len != 0));
    var description_buffer: [4096]u8 = undefined;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, album.description), strings.terminated(&description_buffer, description).ptr);
    return true;
}

fn albumGenres(panel: *Panel, release_id: i64, buffer: []u8) ?[:0]const u8 {
    const self = panel.self;
    const library = self.library orelse return null;
    const genres = self.runtime.libraryReleaseGenres(library, release_id, 2) catch return null;
    defer genres.deinit();
    if (genres.items.len == 0) return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (genres.items, 0..) |genre, index| {
        if (index != 0) writer.writeAll(" / ") catch {};
        writer.writeAll(genre.name) catch {};
    }
    return finish(buffer, &writer);
}

/// Redraws the inspector if it shows `playlist_id`, which may have changed.
pub fn playlistChanged(self: *App, playlist_id: i64) void {
    const panel = self.inspector orelse return;
    switch (panel.source) {
        .playlist => |playlist| if (playlist.playlist_id != playlist_id) return,
        else => return,
    }
    panel.stale = true;
    update(panel);
}

fn populatePlaylist(panel: *Panel, playlist_id: i64) bool {
    const self = panel.self;
    const library = self.library orelse return false;
    const summary = self.runtime.libraryPlaylist(library, playlist_id) catch return false;
    defer summary.deinit(self.runtime.allocator);
    const view = panel.playlist_view;
    var buffer: [1024]u8 = undefined;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.title), strings.terminated(&buffer, summary.name).ptr);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.subtitle), if (summary.kind == .smart) "Smart Playlist" else "Playlist");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.creator), switch (summary.creator) {
        .user => "You",
        .imported => "Imported from a file",
    });

    var tracks_buffer: [32]u8 = undefined;
    _ = setRow(view.tracks_row, strings.format(&tracks_buffer, "{d}", .{summary.entries}));
    var unavailable_buffer: [32]u8 = undefined;
    const missing = summary.entries -| summary.available;
    _ = setRow(view.unavailable_row, if (missing != 0) strings.format(&unavailable_buffer, "{d}", .{missing}) else null);
    var duration_buffer: [32]u8 = undefined;
    var duration_text: [40]u8 = undefined;
    _ = setRow(view.duration_row, if (summary.duration_ms > 0)
        strings.terminated(&duration_text, strings.totalDuration(&duration_buffer, summary.duration_ms))
    else
        null);
    _ = setRow(view.mixed_row, if (summary.entries == 0) null else if (summary.mixed_artists) "Yes" else "No");
    var genre_buffer: [256]u8 = undefined;
    _ = setRow(view.genre_row, genresText(&genre_buffer, summary.top_genres));
    var created_buffer: [64]u8 = undefined;
    _ = setRow(view.created_row, dateText(&created_buffer, summary.created_at));
    var updated_buffer: [64]u8 = undefined;
    _ = setRow(view.updated_row, dateText(&updated_buffer, summary.updated_at));

    gtk.gtk_widget_set_visible(view.description_section, boolean(summary.description.len != 0));
    var description_buffer: [4096]u8 = undefined;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.description), strings.terminated(&description_buffer, summary.description).ptr);

    const tags = gtk.cast(adw.WrapBox, view.tags);
    adw.adw_wrap_box_remove_all(tags);
    for (summary.tags) |tag| {
        var tag_buffer: [256]u8 = undefined;
        const chip = gtk.gtk_label_new(strings.terminated(&tag_buffer, tag).ptr);
        gtk.gtk_widget_add_css_class(chip, "tag-chip");
        adw.adw_wrap_box_append(tags, chip);
    }
    gtk.gtk_widget_set_visible(view.tags_section, boolean(summary.tags.len != 0));
    return true;
}

fn dateText(buffer: []u8, unix_seconds: i64) ?[:0]const u8 {
    if (unix_seconds <= 0) return null;
    const moment = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return null;
    defer gtk.g_date_time_unref(moment);
    const text = gtk.g_date_time_format(moment, "%-d %b %Y") orelse return null;
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

/// Redraws the inspector if it shows `release_id`, now that its info is stored.
pub fn albumInfoChanged(self: *App, release_id: i64) void {
    const panel = self.inspector orelse return;
    switch (panel.source) {
        .album => |album| if (album.release_id != release_id) return,
        else => return,
    }
    if (panel.shown != null) return;
    panel.stale = true;
    update(panel);
}

fn populateArtist(panel: *Panel, artist_id: i64) bool {
    const self = panel.self;
    const library = self.library orelse return false;
    const artist = (self.runtime.libraryArtist(library, artist_id) catch null) orelse return false;
    defer artist.deinit(self.allocator);
    const view = panel.artist_view;
    var buffer: [1024]u8 = undefined;
    const name = if (artist.name.len != 0) artist.name else "Unknown Artist";
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.title), strings.terminated(&buffer, name).ptr);

    var genre_buffer: [512]u8 = undefined;
    _ = setRow(view.genre_row, artistGenres(panel, artist_id, &genre_buffer));
    var albums_buffer: [32]u8 = undefined;
    _ = setRow(view.albums_row, strings.format(&albums_buffer, "{d}", .{artist.release_count}));
    var tracks_buffer: [32]u8 = undefined;
    _ = setRow(view.tracks_row, strings.format(&tracks_buffer, "{d}", .{artist.track_count}));
    var library_buffer: [48]u8 = undefined;
    _ = setRow(view.library_row, strings.format(&library_buffer, "{d} {s}", .{
        artist.track_count,
        if (artist.track_count == 1) "track" else "tracks",
    }));

    var stored = self.runtime.libraryArtistInfo(library, artist_id) catch null;
    defer if (stored) |*info| info.deinit();
    const record = if (stored) |info| info.record else null;
    var years_buffer: [48]u8 = undefined;
    _ = setRow(view.years_row, if (record) |found| yearsText(&years_buffer, found) else null);

    const biography = std.mem.trim(u8, if (record) |found| found.biography orelse "" else "", " \n");
    gtk.gtk_widget_set_visible(view.biography_section, boolean(biography.len != 0));
    if (biography.len != 0) {
        const owned = self.allocator.dupeZ(u8, biography) catch null;
        defer if (owned) |text| self.allocator.free(text);
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.biography), if (owned) |text| text.ptr else "");
        const url = record.?.biography_url orelse "";
        gtk.gtk_widget_set_visible(view.biography_link, boolean(url.len != 0));
        if (url.len != 0) gtk.gtk_link_button_set_uri(gtk.cast(gtk.LinkButton, view.biography_link), strings.terminated(&buffer, url).ptr);
        const licence = record.?.biography_licence orelse "";
        gtk.gtk_widget_set_visible(view.biography_licence, boolean(licence.len != 0));
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.biography_licence), strings.terminated(&buffer, licence).ptr);
    }

    while (gtk.gtk_widget_get_first_child(view.links)) |child| gtk.gtk_box_remove(gtk.cast(gtk.Box, view.links), child);
    var shown_links: usize = 0;
    if (record != null) {
        var links = self.runtime.libraryArtistLinks(library, artist_id) catch null;
        defer if (links) |*found| found.deinit();
        if (links) |found| for (link_order) |kind| {
            for (found.items) |link| {
                if (link.kind != kind or link.url.len == 0) continue;
                gtk.gtk_box_append(gtk.cast(gtk.Box, view.links), newExternalLink(strings.terminated(&buffer, link.url).ptr, linkName(kind)));
                shown_links += 1;
                break;
            }
        };
    }
    gtk.gtk_widget_set_visible(view.links_section, boolean(shown_links != 0));
    gtk.gtk_widget_set_visible(view.fetch, boolean(record == null));
    gtk.gtk_widget_set_sensitive(view.fetch, boolean(!artists.infoPending(self, artist_id)));
    return true;
}

fn artistGenres(panel: *Panel, artist_id: i64, buffer: []u8) ?[:0]const u8 {
    const self = panel.self;
    const library = self.library orelse return null;
    const genres = self.runtime.libraryArtistGenres(library, artist_id, 3) catch return null;
    defer genres.deinit();
    if (genres.items.len == 0) return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (genres.items, 0..) |genre, index| {
        if (index != 0) writer.writeAll("\n") catch {};
        writer.writeAll(genre.name) catch {};
    }
    return finish(buffer, &writer);
}

fn yearsText(buffer: []u8, record: liborca.ArtistInfoRecord) ?[:0]const u8 {
    const begin: u32 = @intCast(@max(record.begin_year orelse return null, 0));
    if (!record.ended) return strings.format(buffer, "{d} – present", .{begin});
    const end: u32 = @intCast(@max(record.end_year orelse return strings.format(buffer, "{d}", .{begin}), 0));
    return strings.format(buffer, "{d} – {d}", .{ begin, end });
}

fn newExternalLink(uri: [*:0]const u8, name: [*:0]const u8) *gtk.Widget {
    const link = gtk.gtk_link_button_new_with_label(uri, name);
    const inner = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    const label = gtk.gtk_label_new(name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, inner), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, inner), gtk.gtk_image_new_from_icon_name("adw-external-link-symbolic"));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, link), inner);
    gtk.gtk_widget_add_css_class(link, "inspector-link");
    gtk.gtk_widget_set_halign(link, gtk.ALIGN_START);
    return link;
}

fn followedArtist(panel: *const Panel) ?i64 {
    return switch (panel.source) {
        .artist => |artist| artist.artist_id,
        else => null,
    };
}

/// Opens the inspector on `artist_id` while it follows that artist's page.
pub fn revealArtist(self: *App, artist_id: i64) void {
    const panel = self.inspector orelse return;
    if (followedArtist(panel) != artist_id) return;
    panel.chosen = null;
    forgetChoice(panel, .{ .artist = artist_id });
    panel.artist_pinned = true;
    panel.stale = true;
    showSidebar(self, .details);
    update(panel);
}

pub fn artistInfoChanged(self: *App, artist_id: i64) void {
    const panel = self.inspector orelse return;
    if (followedArtist(panel) != artist_id or panel.shown != null) return;
    panel.stale = true;
    update(panel);
}

fn fetchArtistClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const artist_id = followedArtist(panel) orelse return;
    artists.requestInfo(panel.self, artist_id, true);
    gtk.gtk_widget_set_sensitive(panel.artist_view.fetch, boolean(!artists.infoPending(panel.self, artist_id)));
}

/// Draws `path`, as `transport.refreshSignalPath` read it, in the inspector;
/// null when it could not be read. `playerSignalPath` pauses the engine
/// briefly, so the inspector never reads it itself.
pub fn showSignalPath(self: *App, path: ?liborca.SignalPath) void {
    if (shownMode(self) != .signal_path) return;
    const context: signal_path.Context = .{
        .title = labelText(self.now_playing_title),
        .subtitle = labelText(self.now_playing_detail),
        .device = transport.deviceName(self),
        .replay_gain_mode = self.runtime.playerReplayGainMode(self.player) catch .off,
    };
    drawSignalPath(self.inspector orelse return, path, context);
}

fn labelText(label: ?*gtk.Label) []const u8 {
    return std.mem.span(gtk.gtk_label_get_text(label orelse return ""));
}

fn drawSignalPath(panel: *Panel, maybe_path: ?liborca.SignalPath, context: signal_path.Context) void {
    const path = maybe_path orelse return showSignalStatus(panel, "Signal path unavailable");
    if (path.source == null) return showSignalStatus(panel, signal_path.nothing_playing);
    panel.signal_block_frames = path.device_quantum_frames;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, panel.signal_status), gtk.false_);
    gtk.gtk_widget_set_visible(panel.signal_content, gtk.true_);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeVerdict(&writer, path) catch {};
    if (writer.end == 0) writer.writeAll("No output open") catch {};
    gtk.gtk_label_set_text(panel.signal_verdict_label, finish(&buffer, &writer).ptr);
    writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeChain(&writer, path, context.device) catch {};
    gtk.gtk_label_set_text(panel.signal_chain_label, finish(&buffer, &writer).ptr);
    if (signal_path.native(path))
        gtk.gtk_widget_add_css_class(panel.signal_dot, "native")
    else
        gtk.gtk_widget_remove_css_class(panel.signal_dot, "native");

    for (signal_path.all_stages, panel.signal_stages) |stage, view| {
        writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        signal_path.writeTag(&writer, path, stage) catch {};
        gtk.gtk_label_set_text(view.tag, finish(&buffer, &writer).ptr);
        writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        signal_path.writeLines(&writer, path, stage, context) catch {};
        gtk.gtk_label_set_text(view.lines, finish(&buffer, &writer).ptr);
        if (signal_path.isLive(stage)) {
            writeLiveTech(panel, stage, view);
        } else {
            writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
            signal_path.writeTech(&writer, path, stage) catch {};
            gtk.gtk_label_set_text(view.tech, finish(&buffer, &writer).ptr);
        }
    }

    writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeFooter(&writer, path) catch {};
    gtk.gtk_label_set_text(panel.signal_footer_label, finish(&buffer, &writer).ptr);
}

fn writeLiveTech(panel: *Panel, stage: signal_path.Stage, view: StageView) void {
    const self = panel.self;
    const snapshot = self.runtime.playerSnapshot(self.player) catch null;
    const stats = if (self.zone) |zone| self.runtime.zoneStats(zone) catch null else null;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeLiveTech(&writer, stage, panel.signal_block_frames, snapshot, stats) catch {};
    gtk.gtk_label_set_text(view.tech, finish(&buffer, &writer).ptr);
}

fn showSignalStatus(panel: *Panel, text: [*:0]const u8) void {
    gtk.gtk_label_set_text(panel.signal_status, text);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, panel.signal_status), gtk.true_);
    gtk.gtk_widget_set_visible(panel.signal_content, gtk.false_);
}

fn stageIcon(stage: signal_path.Stage) [*:0]const u8 {
    return switch (stage) {
        .source => "x-office-document-symbolic",
        .gain => "multimedia-volume-control-symbolic",
        .dsp => "orca-pulse-symbolic",
        .engine => "emblem-system-symbolic",
        .output => "audio-headphones-symbolic",
    };
}

fn expandStage(panel: *Panel, index: usize, expanded: bool) void {
    const view = panel.signal_stages[index];
    const stage = signal_path.all_stages[index];
    if (expanded and signal_path.isLive(stage)) writeLiveTech(panel, stage, view);
    gtk.gtk_revealer_set_reveal_child(gtk.cast(gtk.Revealer, view.revealer), boolean(expanded));
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, view.chevron), if (expanded) "pan-down-symbolic" else "go-next-symbolic");
    gtk.gtk_widget_set_tooltip_text(view.chevron, if (expanded) "Hide details" else "Show details");
    gtk.gtk_accessible_update_state(gtk.cast(gtk.Accessible, view.chevron), gtk.ACCESSIBLE_STATE_EXPANDED, @as(c_int, boolean(expanded)), @as(c_int, -1));
}

fn stageExpanded(panel: *Panel, index: usize) bool {
    return gtk.gtk_revealer_get_reveal_child(gtk.cast(gtk.Revealer, panel.signal_stages[index].revealer)) != 0;
}

fn stageChevronClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const index = slotOf(button);
    expandStage(panel, index, !stageExpanded(panel, index));
}

fn verdictClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    var all = true;
    for (0..panel.signal_stages.len) |index| all = all and stageExpanded(panel, index);
    for (0..panel.signal_stages.len) |index| expandStage(panel, index, !all);
}

fn closeClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showSidebar(panelData(data).self, .hidden);
}

fn newStage(panel: *Panel, index: usize, flow: *gtk.Box) StageView {
    const stage = signal_path.all_stages[index];
    const icon = gtk.gtk_image_new_from_icon_name(stageIcon(stage));
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 20);
    const node = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(node, "signal-node");
    gtk.gtk_widget_set_halign(node, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(node, gtk.false_);
    gtk.gtk_widget_set_vexpand(node, gtk.false_);
    gtk.gtk_widget_set_hexpand(icon, gtk.true_);
    gtk.gtk_widget_set_vexpand(icon, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, node), icon);
    const rail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(rail, "signal-rail");
    gtk.gtk_widget_set_halign(rail, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(rail, gtk.true_);
    gtk.gtk_widget_set_visible(rail, boolean(index + 1 < signal_path.all_stages.len));
    const track = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(track, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, track), node);
    gtk.gtk_box_append(gtk.cast(gtk.Box, track), rail);

    const title = gtk.gtk_label_new(signal_path.stageTitle(stage).ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_widget_add_css_class(title, "signal-stage");
    const tag = newLabel("signal-tag");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, tag), gtk.false_);
    const head = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, head), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, head), tag);

    const lines = newLabel("signal-lines");
    gtk.gtk_widget_set_hexpand(lines, gtk.true_);
    const chevron = gtk.gtk_button_new_from_icon_name("go-next-symbolic");
    gtk.gtk_widget_add_css_class(chevron, "flat");
    gtk.gtk_widget_add_css_class(chevron, "signal-chevron");
    gtk.gtk_widget_set_valign(chevron, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(chevron, "Show details");
    gtk.g_object_set_data(chevron, "orca-slot", @ptrFromInt(index));
    _ = gtk.signalConnect(chevron, "clicked", gtk.callback(stageChevronClicked), panel);
    const body = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), lines);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), chevron);

    const tech = newLabel("signal-tech");
    gtk.gtk_widget_add_css_class(tech, "numeric");
    gtk.gtk_label_set_selectable(gtk.cast(gtk.Label, tech), gtk.true_);
    const revealer = gtk.gtk_revealer_new();
    gtk.gtk_revealer_set_transition_type(gtk.cast(gtk.Revealer, revealer), gtk.REVEALER_TRANSITION_SLIDE_DOWN);
    gtk.gtk_revealer_set_child(gtk.cast(gtk.Revealer, revealer), tech);

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_add_css_class(text, "signal-text");
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), head);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), body);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), revealer);

    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(row, "signal-stage-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), track);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), text);
    gtk.gtk_box_append(flow, row);
    return .{
        .tag = gtk.cast(gtk.Label, tag),
        .lines = gtk.cast(gtk.Label, lines),
        .tech = gtk.cast(gtk.Label, tech),
        .revealer = revealer,
        .chevron = chevron,
    };
}

fn populate(panel: *Panel, details: liborca.TrackDetails) void {
    var buffer: [1024]u8 = undefined;

    const title = if (details.title.len != 0) details.title else "Unknown title";
    const heading = if (details.track_number) |number|
        strings.format(&buffer, "{d}. {s}", .{ number, title })
    else
        strings.terminated(&buffer, title);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, panel.title), heading.ptr);
    setLabel(panel.artist, details.artist, &buffer);
    setLabel(panel.album, details.album, &buffer);

    var any_audio = false;
    any_audio = setRow(panel.format_row, formatText(&buffer, details)) or any_audio;
    var rate_buffer: [32]u8 = undefined;
    any_audio = setRow(panel.sample_rate_row, if (details.sample_rate) |rate| rateText(&rate_buffer, rate) else null) or any_audio;
    var channels_buffer: [32]u8 = undefined;
    any_audio = setRow(panel.channels_row, if (details.channels) |channels| channelsText(&channels_buffer, channels) else null) or any_audio;
    var bitrate_buffer: [32]u8 = undefined;
    any_audio = setRow(panel.bitrate_row, bitrateText(&bitrate_buffer, details.bitrate_kbps)) or any_audio;
    var duration_buffer: [32]u8 = undefined;
    const duration_text: ?[:0]const u8 = if (details.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&duration_buffer, @intCast(ms)) else null)
    else
        null;
    any_audio = setRow(panel.duration_row, duration_text) or any_audio;
    gtk.gtk_widget_set_visible(panel.audio_section, boolean(any_audio));

    populateLoudness(panel, details.loudness);
    populateRecording(panel, details);

    _ = setRow(panel.album_artist_row, optionalText(&buffer, details.album_artist));
    _ = setRow(panel.date_row, if (details.date) |date| optionalText(&buffer, date) else null);
    _ = setRow(panel.genre_row, genresText(&buffer, details.genres));
    var track_buffer: [48]u8 = undefined;
    _ = setRow(panel.track_row, ofText(&track_buffer, details.track_number, details.track_total));
    gtk.gtk_widget_set_tooltip_text(
        panel.track_row.root,
        if (details.track_total != null and details.track_total_inferred) "Total counted from the album's tracks" else null,
    );
    var disc_buffer: [48]u8 = undefined;
    _ = setRow(panel.disc_row, ofText(&disc_buffer, details.disc_number, details.disc_total));
    const compilation: ?[:0]const u8 = if (details.compilation) |flag| (if (flag) "Yes" else "No") else null;
    _ = setRow(panel.compilation_row, compilation);
    _ = setRow(panel.explicit_row, switch (details.explicit) {
        .unknown => null,
        .none => "No",
        .explicit => "Yes",
        .clean => "Clean",
    });
    var plays_buffer: [24]u8 = undefined;
    _ = setRow(panel.plays_row, strings.printZ(&plays_buffer, "{d}", .{details.play_count}) catch null);
    var played_buffer: [64]u8 = undefined;
    _ = setRow(panel.last_played_row, recentMomentText(&played_buffer, details.last_played_at));

    if (details.path) |path| {
        const split = std.mem.lastIndexOfScalar(u8, path, '/');
        const folder = if (split) |index| path[0..@max(index, 1)] else "";
        const name = if (split) |index| path[index + 1 ..] else path;
        setPathRow(panel.folder_row, folder, &buffer);
        setPathRow(panel.file_row, name, &buffer);
        setPath(panel, path);
    } else {
        _ = setRow(panel.folder_row, null);
        _ = setRow(panel.file_row, "File missing");
        gtk.gtk_widget_set_tooltip_text(panel.file_row.root, null);
        setPath(panel, null);
    }
    gtk.gtk_widget_set_visible(panel.copy_button, boolean(panel.path != null));
    var size_buffer: [64]u8 = undefined;
    _ = setRow(panel.size_row, if (details.size_bytes) |bytes| sizeText(&size_buffer, bytes) else null);
    var modified_buffer: [64]u8 = undefined;
    _ = setRow(panel.modified_row, momentText(&modified_buffer, details.modified_at));
    var added_buffer: [64]u8 = undefined;
    _ = setRow(panel.added_row, momentText(&added_buffer, details.added_at));
}

fn setPathRow(row: Row, text: []const u8, buffer: []u8) void {
    const value = optionalText(buffer, text);
    _ = setRow(row, value);
    gtk.gtk_widget_set_tooltip_text(row.root, if (value) |shown| shown.ptr else null);
}

fn populateLoudness(panel: *Panel, loudness: ?liborca.TrackLoudness) void {
    var buffer: [64]u8 = undefined;
    const measured = loudness orelse {
        _ = setRow(panel.loudness_missing, "Not measured");
        for ([_]Row{ panel.integrated_row, panel.peak_row, panel.replay_gain_row }) |row| _ = setRow(row, null);
        return;
    };
    _ = setRow(panel.loudness_missing, null);
    _ = setRow(panel.integrated_row, decibelText(&buffer, measured.integrated_lufs, false, " LUFS"));
    const peak: ?[:0]const u8 = if (measured.sample_peak > 0)
        decibelText(&buffer, 20 * std.math.log10(measured.sample_peak), true, " dBFS")
    else
        minus ++ "∞ dBFS";
    _ = setRow(panel.peak_row, peak);
    _ = setRow(panel.replay_gain_row, decibelText(&buffer, measured.replay_gain_db, true, " dB"));
}

fn setIdRow(row: Row, id: ?[]const u8, source: ?liborca.RecordingIdSource) bool {
    var buffer: [64]u8 = undefined;
    if (!setRow(row, if (id) |text| strings.terminated(&buffer, text) else null)) return false;
    var tooltip_buffer: [128]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(row.root, strings.format(&tooltip_buffer, "{s}\n{s}", .{ id.?, sourceText(source) }).ptr);
    return true;
}

fn sourceText(source: ?liborca.RecordingIdSource) [:0]const u8 {
    return switch (source orelse return "") {
        .tag => "From tags",
        .match => "Matched",
        .edit => "Set by you",
    };
}

fn populateIdentifiers(panel: *Panel, details: liborca.TrackDetails) void {
    var any = false;
    any = setIdRow(panel.recording_row, details.musicbrainz_recording_id, details.musicbrainz_recording_id_source) or any;
    any = setIdRow(panel.release_id_row, details.musicbrainz_release_id, details.musicbrainz_release_id_source) or any;
    any = setIdRow(panel.release_group_id_row, details.musicbrainz_release_group_id, details.musicbrainz_release_group_id_source) or any;
    any = setIdRow(panel.release_track_id_row, details.musicbrainz_release_track_id, details.musicbrainz_release_track_id_source) or any;
    any = setIdRow(panel.album_artist_id_row, details.musicbrainz_album_artist_id, details.musicbrainz_album_artist_id_source) or any;
    gtk.gtk_widget_set_visible(panel.identifiers_button, boolean(any));
    if (!any) showIdentifiers(panel, false);
}

fn showIdentifiers(panel: *Panel, shown: bool) void {
    gtk.gtk_widget_set_visible(panel.identifiers, boolean(shown));
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, panel.identifiers_button), if (shown) "Hide identifiers" else "Show identifiers");
}

fn populateRecording(panel: *Panel, details: liborca.TrackDetails) void {
    populateIdentifiers(panel, details);
    for (panel.proposals) |proposal| gtk.gtk_widget_set_visible(proposal.root, gtk.false_);
    for ([_]*gtk.Widget{ panel.review_button, panel.find_button, panel.verify_button }) |button|
        gtk.gtk_widget_set_visible(button, gtk.false_);
    _ = setRow(panel.acoustid_row, "Not checked");
    const link = panel.musicbrainz_row;
    if (details.musicbrainz_recording_id) |recording_mbid| {
        const source = sourceText(details.musicbrainz_recording_id_source);
        gtk.gtk_label_set_text(link.link_label, if (source.len != 0) source.ptr else "Identified");
        matches.setRecording(link.link, recording_mbid);
        gtk.gtk_widget_set_visible(link.link, gtk.true_);
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, link.value), gtk.false_);
        _ = setRow(panel.match_status, null);
        populateVerification(panel, details.track_id);
        return;
    }
    gtk.gtk_label_set_text(link.value, "Not matched");
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, link.value), gtk.true_);
    gtk.gtk_widget_set_visible(link.link, gtk.false_);
    const self = panel.self;
    const searching = self.task == .matching and self.match_task_mode != .verify and self.match_task_track == details.track_id;
    const library = self.library orelse return;
    const proposals = self.runtime.libraryMatchProposals(library, details.track_id, proposal_slots + 1) catch null;
    defer if (proposals) |page| page.deinit();
    const pending = if (proposals) |page| page.items else &.{};
    const status: ?[:0]const u8 = if (searching)
        (if (self.match_fingerprints) "Searching MusicBrainz and AcoustID…" else "Searching MusicBrainz…")
    else if (pending.len == 0 and self.unmatched_track == details.track_id)
        "No match found"
    else
        null;
    _ = setRow(panel.match_status, status);
    const shown = @min(pending.len, proposal_slots);
    for (pending[0..shown], panel.proposals[0..shown], 0..) |proposal, widgets, slot| {
        showProposal(widgets, proposal);
        panel.proposal_ids[slot] = proposal.id;
    }
    gtk.gtk_widget_set_visible(panel.review_button, boolean(pending.len > proposal_slots));
    gtk.gtk_widget_set_visible(panel.find_button, boolean(pending.len == 0 and !searching));
}

fn populateVerification(panel: *Panel, track_id: i64) void {
    const self = panel.self;
    if (self.task == .matching and self.match_task_mode == .verify and self.match_task_track == track_id) {
        _ = setRow(panel.acoustid_row, "Checking…");
        return;
    }
    const library = self.library orelse return;
    const verification = (self.runtime.libraryTrackVerification(library, self.allocator, track_id) catch null) orelse {
        gtk.gtk_widget_set_visible(panel.verify_button, gtk.true_);
        return;
    };
    defer verification.deinit();
    var buffer: [128]u8 = undefined;
    _ = setRow(panel.acoustid_row, strings.format(&buffer, "{s}{s}{s}", .{
        switch (verification.outcome) {
            .agrees => "Matched",
            .disagrees => "Hears a different recording",
            .unconfirmed => "Could not confirm",
            .no_fingerprint => "Could not fingerprint",
        },
        if (verification.stale) separator ++ "out of date" else "",
        if (verification.dismissed) separator ++ "suggestion dismissed" else "",
    }));
    gtk.gtk_widget_set_visible(panel.verify_button, boolean(verification.stale));
}

fn showProposal(widgets: Proposal, proposal: liborca.MatchProposal) void {
    var title_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(title_buffer[0 .. title_buffer.len - 1]);
    matches.writeHeading(&writer, proposal) catch {};
    const title = finish(&title_buffer, &writer);
    gtk.gtk_label_set_text(widgets.title, title.ptr);
    var subtitle_buffer: [512]u8 = undefined;
    writer = std.Io.Writer.fixed(subtitle_buffer[0 .. subtitle_buffer.len - 1]);
    const album = proposal.release_title orelse proposal.album;
    if (album.len != 0) writer.print("{s}" ++ separator, .{album}) catch {};
    if (proposal.release_date) |date| writer.print("{s}" ++ separator, .{date}) catch {};
    if (proposal.duration_ms) |milliseconds| {
        var length_buffer: [32]u8 = undefined;
        writer.print("{s}" ++ separator, .{strings.formatMs(&length_buffer, milliseconds)}) catch {};
    }
    writer.print("{d}%", .{matches.percent(proposal.confidence)}) catch {};
    const subtitle = finish(&subtitle_buffer, &writer);
    gtk.gtk_label_set_text(widgets.subtitle, subtitle.ptr);
    var source_buffer: [96]u8 = undefined;
    writer = std.Io.Writer.fixed(source_buffer[0 .. source_buffer.len - 1]);
    matches.writeSource(&writer, proposal) catch {};
    const source = finish(&source_buffer, &writer);
    var tooltip_buffer: [1024]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(widgets.root, strings.format(&tooltip_buffer, "{s}\n{s}\nFrom {s}", .{ title, subtitle, source }).ptr);
    gtk.gtk_widget_set_visible(widgets.root, gtk.true_);
}

fn setPath(panel: *Panel, path: ?[]const u8) void {
    const allocator = panel.self.allocator;
    if (panel.path) |old| allocator.free(old);
    panel.path = if (path) |value| allocator.dupeZ(u8, value) catch null else null;
}

fn optionalEql(a: ?i64, b: ?i64) bool {
    if (a) |left| return left == (b orelse return false);
    return b == null;
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn optionalText(buffer: []u8, text: []const u8) ?[:0]const u8 {
    return if (text.len == 0) null else strings.terminated(buffer, text);
}

fn ofText(buffer: []u8, value: ?i64, total: ?i64) ?[:0]const u8 {
    const number = value orelse return null;
    if (total) |count| return strings.printZ(buffer, "{d} of {d}", .{ number, count }) catch null;
    return strings.printZ(buffer, "{d}", .{number}) catch null;
}

pub fn genresText(buffer: []u8, genres: []const []const u8) ?[:0]const u8 {
    if (genres.len == 0) return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    for (genres, 0..) |genre, index| {
        if (index != 0) writer.writeAll(", ") catch {};
        writer.writeAll(genre) catch {};
    }
    return finish(buffer, &writer);
}

fn sizeText(buffer: []u8, bytes: i64) ?[:0]const u8 {
    const text = gtk.g_format_size(@intCast(@max(bytes, 0)));
    defer gtk.g_free(text);
    return strings.printZ(buffer, "{s}", .{std.mem.span(text)}) catch null;
}

fn finish(buffer: []u8, writer: *const std.Io.Writer) [:0]const u8 {
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn formatText(buffer: []u8, details: liborca.TrackDetails) ?[:0]const u8 {
    if (details.codec.len == 0) return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeCodecName(&writer, details.codec) catch {};
    if (!details.lossy) if (details.bit_depth) |depth| writer.print(" ({d}-bit)", .{depth}) catch {};
    return finish(buffer, &writer);
}

fn rateText(buffer: []u8, rate: u32) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    signal_path.writeRate(&writer, rate) catch {};
    return finish(buffer, &writer);
}

fn channelsText(buffer: []u8, channels: u32) [:0]const u8 {
    return switch (channels) {
        1 => "1 (mono)",
        2 => "2 (stereo)",
        else => strings.format(buffer, "{d}", .{channels}),
    };
}

fn bitrateText(buffer: []u8, bitrate_kbps: ?u32) ?[:0]const u8 {
    const kbps = bitrate_kbps orelse return null;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    strings.writeGrouped(&writer, kbps) catch {};
    writer.writeAll(" kbps") catch {};
    return finish(buffer, &writer);
}

pub fn recentMomentText(buffer: []u8, unix_seconds: ?i64) [:0]const u8 {
    const seconds = unix_seconds orelse return "Never";
    const played = gtk.g_date_time_new_from_unix_local(seconds) orelse return "Never";
    defer gtk.g_date_time_unref(played);
    const clock = formatted(played, "%R") orelse return "Recently";
    defer gtk.g_free(clock);
    if (daysAgo(played)) |days| switch (days) {
        0 => return strings.format(buffer, "Today, {s}", .{std.mem.span(clock)}),
        1 => return strings.format(buffer, "Yesterday, {s}", .{std.mem.span(clock)}),
        else => {},
    };
    const date = formatted(played, "%-d %b %Y") orelse return "Recently";
    defer gtk.g_free(date);
    return strings.format(buffer, "{s}, {s}", .{ std.mem.span(date), std.mem.span(clock) });
}

pub fn recentDayText(buffer: []u8, unix_seconds: i64) [:0]const u8 {
    const played = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return "";
    defer gtk.g_date_time_unref(played);
    if (daysAgo(played)) |days| return switch (days) {
        0 => "Today",
        1 => "Yesterday",
        else => strings.format(buffer, "{d} days ago", .{days}),
    };
    const date = formatted(played, "%-d %b %Y") orelse return "";
    defer gtk.g_free(date);
    return strings.format(buffer, "{s}", .{std.mem.span(date)});
}

fn daysAgo(moment: *gtk.GDateTime) ?c_int {
    const now = gtk.g_date_time_new_now_local() orelse return null;
    defer gtk.g_date_time_unref(now);
    const day = formatted(moment, "%F") orelse return null;
    defer gtk.g_free(day);
    var days: c_int = 0;
    while (days < 7) : (days += 1) {
        const earlier = gtk.g_date_time_add_days(now, -days) orelse return null;
        defer gtk.g_date_time_unref(earlier);
        if (sameDay(day, earlier)) return days;
    }
    return null;
}

fn momentText(buffer: []u8, unix_seconds: ?i64) ?[:0]const u8 {
    const seconds = unix_seconds orelse return null;
    const moment = gtk.g_date_time_new_from_unix_local(seconds) orelse return null;
    defer gtk.g_date_time_unref(moment);
    const text = formatted(moment, "%F %R") orelse return null;
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

fn formatted(moment: *gtk.GDateTime, pattern: [*:0]const u8) ?[*:0]u8 {
    return gtk.g_date_time_format(moment, pattern);
}

fn sameDay(day: [*:0]const u8, moment: *gtk.GDateTime) bool {
    const other = formatted(moment, "%F") orelse return false;
    defer gtk.g_free(other);
    return std.mem.eql(u8, std.mem.span(day), std.mem.span(other));
}

fn decibelText(buffer: []u8, value: f32, comptime signed: bool, unit: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeDecibels(&writer, value, signed) catch {};
    writer.writeAll(unit) catch {};
    return finish(buffer, &writer);
}

fn writeDecibels(writer: *std.Io.Writer, value: f32, comptime signed: bool) std.Io.Writer.Error!void {
    const tenths = @round(value * 10) / 10;
    if (tenths == 0) return writer.writeAll("0.0");
    const sign: []const u8 = if (tenths < 0) minus else if (signed) "+" else "";
    try writer.print("{s}{d:.1}", .{ sign, @abs(tenths) });
}

fn setLabel(label: *gtk.Widget, text: []const u8, buffer: []u8) void {
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), strings.terminated(buffer, text).ptr);
    gtk.gtk_widget_set_visible(label, boolean(text.len != 0));
}

/// Shows `text` as the row's value, or hides the row when there is none.
fn setRow(row: Row, text: ?[:0]const u8) bool {
    const value = text orelse {
        gtk.gtk_widget_set_visible(row.root, gtk.false_);
        return false;
    };
    gtk.gtk_label_set_text(row.value, value.ptr);
    gtk.gtk_widget_set_visible(row.root, gtk.true_);
    return true;
}

fn newKey(key: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(key);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_widget_set_valign(label, gtk.ALIGN_START);
    gtk.gtk_widget_set_size_request(label, key_width, -1);
    gtk.gtk_widget_add_css_class(label, "inspector-key");
    return label;
}

fn newRowWith(key: [*:0]const u8, value: *gtk.Widget) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "inspector-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), newKey(key));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), value);
    return row;
}

fn newValue() *gtk.Widget {
    const value = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, value), gtk.true_);
    gtk.gtk_widget_set_hexpand(value, gtk.true_);
    gtk.gtk_widget_add_css_class(value, "inspector-value");
    return value;
}

fn newRow(key: [*:0]const u8) Row {
    const value = newValue();
    return .{ .root = newRowWith(key, value), .value = gtk.cast(gtk.Label, value) };
}

fn newPathRow(key: [*:0]const u8, ellipsize: c_int) Row {
    const row = newRow(key);
    gtk.gtk_label_set_wrap(row.value, gtk.false_);
    gtk.gtk_label_set_ellipsize(row.value, ellipsize);
    return row;
}

fn newLinkRow(key: [*:0]const u8) LinkRow {
    const value = newValue();
    const link_label = gtk.gtk_label_new("");
    const icon = gtk.gtk_image_new_from_icon_name("adw-external-link-symbolic");
    const inner = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_box_append(gtk.cast(gtk.Box, inner), link_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, inner), icon);
    const link = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, link), inner);
    gtk.gtk_widget_add_css_class(link, "flat");
    gtk.gtk_widget_add_css_class(link, "inspector-link");
    gtk.gtk_widget_set_halign(link, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(link, "Open this recording on MusicBrainz");
    const values = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(values, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, values), value);
    gtk.gtk_box_append(gtk.cast(gtk.Box, values), link);
    return .{
        .root = newRowWith(key, values),
        .value = gtk.cast(gtk.Label, value),
        .link = link,
        .link_label = gtk.cast(gtk.Label, link_label),
    };
}

fn newIdRow(key: [*:0]const u8) Row {
    const row = newPathRow(key, gtk.ELLIPSIZE_MIDDLE);
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, row.value), "tech");
    gtk.gtk_widget_set_visible(row.root, gtk.false_);
    return row;
}

fn newLine(css_class: ?[*:0]const u8) Row {
    const label = newLabel(css_class);
    gtk.gtk_widget_add_css_class(label, "inspector-line");
    return .{ .root = label, .value = gtk.cast(gtk.Label, label) };
}

fn newSection(icon: [*:0]const u8, heading: [*:0]const u8, children: []const *gtk.Widget, trailing: ?*gtk.Widget) *gtk.Widget {
    const image = gtk.gtk_image_new_from_icon_name(icon);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), 20);
    gtk.gtk_widget_add_css_class(image, "inspector-icon");
    const title = gtk.gtk_label_new(heading);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_widget_add_css_class(title, "inspector-heading");
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(header, "inspector-section-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), image);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), title);
    if (trailing) |widget| gtk.gtk_box_append(gtk.cast(gtk.Box, header), widget);
    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(section, "inspector-section");
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), header);
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, section), child);
    return section;
}

fn newLabel(css_class: ?[*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
    if (css_class) |name| gtk.gtk_widget_add_css_class(label, name);
    return label;
}
fn copyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const path = panel.path orelse return;
    gtk.gdk_clipboard_set_text(gtk.gtk_widget_get_clipboard(panel.copy_button), path.ptr);
    panel.self.toast("Path copied");
}

fn recordingLinkClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    matches.openRecording(panelData(data).self, matches.recordingOf(button) orelse return);
}

fn slotOf(button: ?*anyopaque) usize {
    return @intFromPtr(gtk.g_object_get_data(button.?, "orca-slot"));
}

fn proposalAcceptClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    matches.accept(panel.self, panel.shown orelse return, panel.proposal_ids[slotOf(button)]);
}

fn proposalDismissClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    matches.dismiss(panel.self, panel.shown orelse return, panel.proposal_ids[slotOf(button)]);
}

fn reviewAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    matches.reveal(panel.self, panel.shown orelse return);
}

fn verifyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    jobs.startTrackVerification(panel.self, panel.shown orelse return);
}

fn findMatchClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    jobs.startTrackMatching(panel.self, panel.shown orelse return);
}

fn identifiersClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    showIdentifiers(panel, gtk.gtk_widget_get_visible(panel.identifiers) == 0);
}

fn iconButton(icon: [*:0]const u8, tooltip: [*:0]const u8, slot: usize) *gtk.Widget {
    const button = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.g_object_set_data(button, "orca-slot", @ptrFromInt(slot));
    return button;
}

fn newProposal(slot: usize) Proposal {
    const title = newLabel(null);
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, title), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    const subtitle = newLabel("tech");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, subtitle), gtk.false_);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, subtitle), gtk.ELLIPSIZE_END);
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), subtitle);
    const accept = iconButton("object-select-symbolic", "Accept", slot);
    const dismiss = iconButton("window-close-symbolic", "Dismiss", slot);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(row, "inspector-proposal");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), accept);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), dismiss);
    gtk.gtk_widget_set_visible(row, gtk.false_);
    return .{
        .root = row,
        .title = gtk.cast(gtk.Label, title),
        .subtitle = gtk.cast(gtk.Label, subtitle),
        .accept = accept,
        .dismiss = dismiss,
    };
}

fn actionButton(label: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(label);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "inspector-action");
    gtk.gtk_widget_set_visible(button, gtk.false_);
    return button;
}

fn scrolled(child: *gtk.Widget) *gtk.Widget {
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), child);
    gtk.gtk_widget_set_focusable(scroller, gtk.false_);
    return scroller;
}

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const self = panel.self;
    if (self.inspector == panel) self.inspector = null;
    setPath(panel, null);
    panel.lyrics.deinit();
    self.allocator.destroy(panel);
}

fn newAlbum(panel: *Panel) Album {
    const title = newLabel("inspector-title");
    const subtitle = newLabel("inspector-subtitle");
    gtk.gtk_widget_add_css_class(subtitle, "dim");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, subtitle), "Album");
    const heading = newHeader(panel, &.{ title, subtitle }, null);

    const artist_row = newRow("Artist");
    const date_row = newRow("Date");
    const genre_row = newRow("Genre");
    const tracks_row = newRow("Tracks");
    const duration_row = newRow("Duration");
    const format_row = newRow("Format");
    const overview = newSection("x-office-document-symbolic", "Overview", &.{
        artist_row.root,
        date_row.root,
        genre_row.root,
        tracks_row.root,
        duration_row.root,
        format_row.root,
    }, null);
    const musicbrainz_row = newRow("MusicBrainz");
    const identity_section = newSection("auth-fingerprint-symbolic", "Identity", &.{musicbrainz_row.root}, null);
    const description = newLabel("inspector-description");
    const description_section = newSection("format-justify-left-symbolic", "Description", &.{description}, null);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_visible(content, gtk.false_);
    for ([_]*gtk.Widget{ heading, overview, identity_section, description_section }) |section|
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), section);
    return .{
        .content = content,
        .title = title,
        .artist_row = artist_row,
        .date_row = date_row,
        .genre_row = genre_row,
        .tracks_row = tracks_row,
        .duration_row = duration_row,
        .format_row = format_row,
        .identity_section = identity_section,
        .musicbrainz_row = musicbrainz_row,
        .description_section = description_section,
        .description = description,
    };
}

fn newPlaylistView() PlaylistView {
    const title = newLabel("inspector-title");
    gtk.gtk_widget_add_css_class(title, "inspector-title-upper");
    const subtitle = newLabel("inspector-subtitle");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(heading, "inspector-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), subtitle);

    const avatar = gtk.gtk_image_new_from_icon_name("avatar-default-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, avatar), 20);
    gtk.gtk_widget_add_css_class(avatar, "playlist-creator-avatar");
    const creator = newLabel("inspector-value");
    const creator_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(creator_row, "inspector-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, creator_row), avatar);
    gtk.gtk_box_append(gtk.cast(gtk.Box, creator_row), creator);
    const creator_section = newSection("avatar-default-symbolic", "Created by", &.{creator_row}, null);

    const tracks_row = newRow("Tracks");
    const unavailable_row = newRow("Unavailable");
    const duration_row = newRow("Duration");
    const mixed_row = newRow("Mixed artists");
    const genre_row = newRow("Genre");
    const created_row = newRow("Created");
    const updated_row = newRow("Last updated");
    const overview = newSection("x-office-document-symbolic", "Details", &.{
        tracks_row.root,
        unavailable_row.root,
        duration_row.root,
        mixed_row.root,
        genre_row.root,
        created_row.root,
        updated_row.root,
    }, null);
    const description = newLabel("inspector-description");
    const description_section = newSection("format-justify-left-symbolic", "Description", &.{description}, null);
    const tags = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, tags), 8);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, tags), 8);
    gtk.gtk_widget_add_css_class(tags, "inspector-tags");
    const tags_section = newSection("tag-symbolic", "Tags", &.{tags}, null);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_visible(content, gtk.false_);
    for ([_]*gtk.Widget{ heading, creator_section, overview, description_section, tags_section }) |section|
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), section);
    return .{
        .content = content,
        .title = title,
        .subtitle = subtitle,
        .creator = creator,
        .tracks_row = tracks_row,
        .unavailable_row = unavailable_row,
        .duration_row = duration_row,
        .mixed_row = mixed_row,
        .genre_row = genre_row,
        .created_row = created_row,
        .updated_row = updated_row,
        .description_section = description_section,
        .description = description,
        .tags_section = tags_section,
        .tags = tags,
    };
}

fn newArtistView() Artist {
    const title = newLabel("inspector-title");
    const subtitle = newLabel("inspector-subtitle");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, subtitle), "Artist");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(heading, "inspector-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), subtitle);

    const genre_row = newRow("Genres");
    const years_row = newRow("Years active");
    const albums_row = newRow("Total albums");
    const tracks_row = newRow("Total tracks");
    const library_row = newRow("In your library");
    const fetch = gtk.gtk_button_new_with_label("Fetch artist info");
    gtk.gtk_widget_add_css_class(fetch, "inspector-action");
    gtk.gtk_widget_set_halign(fetch, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(fetch, "Look this artist up on MusicBrainz, Wikidata, Wikipedia and ListenBrainz");
    const overview = newSection("x-office-document-symbolic", "Overview", &.{
        genre_row.root,
        years_row.root,
        albums_row.root,
        tracks_row.root,
        library_row.root,
        fetch,
    }, null);

    const biography = newLabel("inspector-description");
    const biography_link = newExternalLink("https://wikipedia.org/", "Read more on Wikipedia");
    const biography_licence = newLabel("inspector-licence");
    const biography_section = newSection("format-justify-left-symbolic", "Biography", &.{ biography, biography_link, biography_licence }, null);

    const links = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(links, "inspector-links");
    const links_section = newSection("insert-link-symbolic", "Links", &.{links}, null);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_visible(content, gtk.false_);
    for ([_]*gtk.Widget{ heading, overview, biography_section, links_section }) |section|
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), section);
    return .{
        .content = content,
        .title = title,
        .genre_row = genre_row,
        .years_row = years_row,
        .albums_row = albums_row,
        .tracks_row = tracks_row,
        .library_row = library_row,
        .biography_section = biography_section,
        .biography = biography,
        .biography_link = biography_link,
        .biography_licence = biography_licence,
        .links_section = links_section,
        .links = links,
        .fetch = fetch,
    };
}

/// Makes `split`'s sidebar the inspector.
pub fn build(self: *App, split: *adw.OverlaySplitView) void {
    const panel = self.allocator.create(Panel) catch return;

    const title = newLabel("inspector-title");
    const artist = newLabel("inspector-subtitle");
    const album = newLabel("inspector-subtitle");
    gtk.gtk_widget_add_css_class(album, "dim");
    const track_actions = gtk.gtk_button_new_from_icon_name("orca-more-symbolic");
    gtk.gtk_widget_add_css_class(track_actions, "flat");
    gtk.gtk_widget_add_css_class(track_actions, "inspector-close");
    gtk.gtk_widget_set_valign(track_actions, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(track_actions, "Track actions");
    _ = gtk.signalConnect(track_actions, "clicked", gtk.callback(trackActionsClicked), panel);
    const heading = newHeader(panel, &.{ title, artist, album }, track_actions);

    const format_row = newRow("Format");
    const sample_rate_row = newRow("Sample rate");
    const channels_row = newRow("Channels");
    const bitrate_row = newRow("Bitrate");
    const duration_row = newRow("Duration");
    const loudness_missing = newLine("inspector-key");
    const integrated_row = newRow("Integrated");
    const peak_row = newRow("Peak");
    const replay_gain_row = newRow("ReplayGain");

    const musicbrainz_row = newLinkRow("MusicBrainz");
    const acoustid_row = newRow("AcoustID");
    const match_status = newLine("meta");
    const recording_row = newIdRow("Recording");
    const release_id_row = newIdRow("Release");
    const release_group_id_row = newIdRow("Release group");
    const release_track_id_row = newIdRow("Release track");
    const album_artist_id_row = newIdRow("Album artist");
    const identifiers = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for ([_]Row{ recording_row, release_id_row, release_group_id_row, release_track_id_row, album_artist_id_row }) |row|
        gtk.gtk_box_append(gtk.cast(gtk.Box, identifiers), row.root);
    gtk.gtk_widget_set_visible(identifiers, gtk.false_);
    var proposals: [proposal_slots]Proposal = undefined;
    for (&proposals, 0..) |*proposal, index| proposal.* = newProposal(index);
    const identifiers_button = actionButton("Show identifiers");
    const review_button = actionButton("Review All");
    const find_button = actionButton("Find Match");
    const verify_button = actionButton("Verify");
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(actions, "inspector-actions");
    for ([_]*gtk.Widget{ identifiers_button, review_button, find_button, verify_button }) |button|
        gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);

    const album_artist_row = newRow("Album artist");
    const date_row = newRow("Date");
    const genre_row = newRow("Genre");
    const track_row = newRow("Track");
    const disc_row = newRow("Disc");
    const compilation_row = newRow("Compilation");
    const explicit_row = newRow("Explicit");
    const plays_row = newRow("Plays");
    const last_played_row = newRow("Last played");

    const folder_row = newPathRow("Path", gtk.ELLIPSIZE_START);
    const file_row = newPathRow("File", gtk.ELLIPSIZE_MIDDLE);
    const size_row = newRow("Size");
    const modified_row = newRow("Modified");
    const added_row = newRow("Date added");
    const copy_button = gtk.gtk_button_new_from_icon_name("edit-copy-symbolic");
    gtk.gtk_widget_set_valign(copy_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(copy_button, "flat");
    gtk.gtk_widget_add_css_class(copy_button, "inspector-copy");
    gtk.gtk_widget_set_tooltip_text(copy_button, "Copy path");

    const audio_section = newSection("audio-x-generic-symbolic", "Audio", &.{
        format_row.root,
        sample_rate_row.root,
        channels_row.root,
        bitrate_row.root,
        duration_row.root,
    }, null);
    const loudness_section = newSection("multimedia-volume-control-symbolic", "Loudness", &.{
        loudness_missing.root,
        integrated_row.root,
        peak_row.root,
        replay_gain_row.root,
    }, null);
    const identity_section = newSection("auth-fingerprint-symbolic", "Identity", &.{
        musicbrainz_row.root,
        acoustid_row.root,
        match_status.root,
        proposals[0].root,
        proposals[1].root,
        proposals[2].root,
        actions,
        identifiers,
    }, null);
    const metadata_section = newSection("x-office-document-symbolic", "Metadata", &.{
        album_artist_row.root,
        date_row.root,
        genre_row.root,
        track_row.root,
        disc_row.root,
        compilation_row.root,
        explicit_row.root,
        plays_row.root,
        last_played_row.root,
    }, null);
    const file_section = newSection("folder-symbolic", "File", &.{
        folder_row.root,
        file_row.root,
        size_row.root,
        modified_row.root,
        added_row.root,
    }, copy_button);

    const album_view = newAlbum();
    const artist_view = newArtistView();
    const playlist_view = newPlaylistView();

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_visible(content, gtk.false_);
    for ([_]*gtk.Widget{ heading, audio_section, loudness_section, identity_section, metadata_section, file_section }) |section|
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), section);

    const placeholder = gtk.gtk_label_new("Select a track to see its details.");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, placeholder), gtk.true_);
    gtk.gtk_widget_add_css_class(placeholder, "dim-label");
    gtk.gtk_widget_set_margin_top(placeholder, 24);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "inspector-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), placeholder);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), content);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), album_view.content);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), artist_view.content);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), playlist_view.content);

    const signal_icon = gtk.gtk_image_new_from_icon_name("network-cellular-signal-excellent-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, signal_icon), 24);
    gtk.gtk_widget_set_valign(signal_icon, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(signal_icon, "signal-header-icon");
    const signal_title = newLabel("signal-title");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, signal_title), "Signal Path");
    const signal_subtitle = newLabel("signal-subtitle");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, signal_subtitle), "See how your audio is processed from source to output.");
    const signal_titles = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(signal_titles, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_titles), signal_title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_titles), signal_subtitle);
    const signal_close = gtk.gtk_button_new_from_icon_name("window-close-symbolic");
    gtk.gtk_widget_add_css_class(signal_close, "flat");
    gtk.gtk_widget_set_valign(signal_close, gtk.ALIGN_START);
    gtk.gtk_widget_set_tooltip_text(signal_close, "Close");
    const signal_header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(signal_header, "signal-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_header), signal_icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_header), signal_titles);
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_header), signal_close);

    const signal_status = newLabel("dim-label");
    gtk.gtk_widget_set_margin_top(signal_status, 12);

    const signal_dot = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(signal_dot, "signal-dot");
    gtk.gtk_widget_set_valign(signal_dot, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_halign(signal_dot, gtk.ALIGN_CENTER);
    const signal_verdict_label = newLabel("signal-verdict-title");
    const signal_chain_label = newLabel("signal-chain");
    const verdict_text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(verdict_text, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, verdict_text), signal_verdict_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, verdict_text), signal_chain_label);
    const verdict_chevron = gtk.gtk_image_new_from_icon_name("go-next-symbolic");
    gtk.gtk_widget_add_css_class(verdict_chevron, "signal-chevron");
    const verdict_inner = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_box_append(gtk.cast(gtk.Box, verdict_inner), signal_dot);
    gtk.gtk_box_append(gtk.cast(gtk.Box, verdict_inner), verdict_text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, verdict_inner), verdict_chevron);
    const signal_verdict = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, signal_verdict), verdict_inner);
    gtk.gtk_widget_add_css_class(signal_verdict, "signal-verdict");
    gtk.gtk_widget_set_tooltip_text(signal_verdict, "Show every stage's details");

    const signal_flow = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(signal_flow, "signal-flow");
    var signal_stages: [signal_path.all_stages.len]StageView = undefined;
    for (&signal_stages, 0..) |*view, index| view.* = newStage(panel, index, gtk.cast(gtk.Box, signal_flow));

    const footer_icon = gtk.gtk_image_new_from_icon_name("dialog-information-symbolic");
    gtk.gtk_widget_set_valign(footer_icon, gtk.ALIGN_START);
    const signal_footer_label = newLabel("signal-footer-title");
    const footer_detail = newLabel("signal-footer-detail");
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, footer_detail), signal_path.pipewire_hedge);
    const footer_text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(footer_text, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer_text), signal_footer_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer_text), footer_detail);
    const signal_footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(signal_footer, "signal-footer");
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_footer), footer_icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, signal_footer), footer_text);

    const signal_content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    for ([_]*gtk.Widget{ signal_verdict, signal_flow, signal_footer }) |widget|
        gtk.gtk_box_append(gtk.cast(gtk.Box, signal_content), widget);
    const signal_body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(signal_body, "signal-body");
    for ([_]*gtk.Widget{ signal_header, signal_status, signal_content }) |widget|
        gtk.gtk_box_append(gtk.cast(gtk.Box, signal_body), widget);

    const root = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(root, "inspector");
    gtk.gtk_widget_set_vexpand(root, gtk.true_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, root), scrolled(body), "details");

    adw.adw_overlay_split_view_set_min_sidebar_width(split, inspector_width);
    adw.adw_overlay_split_view_set_max_sidebar_width(split, inspector_width);
    adw.adw_overlay_split_view_set_sidebar(split, root);

    panel.* = .{
        .self = self,
        .split = gtk.cast(gtk.Widget, split),
        .root = root,
        .placeholder = placeholder,
        .content = content,
        .title = title,
        .artist = artist,
        .album = album,
        .audio_section = audio_section,
        .format_row = format_row,
        .sample_rate_row = sample_rate_row,
        .channels_row = channels_row,
        .bitrate_row = bitrate_row,
        .duration_row = duration_row,
        .loudness_missing = loudness_missing,
        .integrated_row = integrated_row,
        .peak_row = peak_row,
        .replay_gain_row = replay_gain_row,
        .musicbrainz_row = musicbrainz_row,
        .acoustid_row = acoustid_row,
        .match_status = match_status,
        .identifiers_button = identifiers_button,
        .identifiers = identifiers,
        .recording_row = recording_row,
        .release_id_row = release_id_row,
        .release_group_id_row = release_group_id_row,
        .release_track_id_row = release_track_id_row,
        .album_artist_id_row = album_artist_id_row,
        .proposals = proposals,
        .review_button = review_button,
        .find_button = find_button,
        .verify_button = verify_button,
        .metadata_section = metadata_section,
        .album_artist_row = album_artist_row,
        .date_row = date_row,
        .genre_row = genre_row,
        .track_row = track_row,
        .disc_row = disc_row,
        .compilation_row = compilation_row,
        .explicit_row = explicit_row,
        .plays_row = plays_row,
        .last_played_row = last_played_row,
        .folder_row = folder_row,
        .file_row = file_row,
        .size_row = size_row,
        .modified_row = modified_row,
        .added_row = added_row,
        .copy_button = copy_button,
        .album_view = album_view,
        .artist_view = artist_view,
        .playlist_view = playlist_view,
        .signal_status = gtk.cast(gtk.Label, signal_status),
        .signal_content = signal_content,
        .signal_dot = signal_dot,
        .signal_verdict_label = gtk.cast(gtk.Label, signal_verdict_label),
        .signal_chain_label = gtk.cast(gtk.Label, signal_chain_label),
        .signal_stages = signal_stages,
        .signal_footer_label = gtk.cast(gtk.Label, signal_footer_label),
    };
    _ = gtk.signalConnect(copy_button, "clicked", gtk.callback(copyClicked), panel);
    _ = gtk.signalConnect(artist_view.fetch, "clicked", gtk.callback(fetchArtistClicked), panel);
    _ = gtk.signalConnect(musicbrainz_row.link, "clicked", gtk.callback(recordingLinkClicked), panel);
    for (proposals) |proposal| {
        _ = gtk.signalConnect(proposal.accept, "clicked", gtk.callback(proposalAcceptClicked), panel);
        _ = gtk.signalConnect(proposal.dismiss, "clicked", gtk.callback(proposalDismissClicked), panel);
    }
    _ = gtk.signalConnect(identifiers_button, "clicked", gtk.callback(identifiersClicked), panel);
    _ = gtk.signalConnect(review_button, "clicked", gtk.callback(reviewAllClicked), panel);
    _ = gtk.signalConnect(find_button, "clicked", gtk.callback(findMatchClicked), panel);
    _ = gtk.signalConnect(verify_button, "clicked", gtk.callback(verifyClicked), panel);
    _ = gtk.signalConnect(signal_close, "clicked", gtk.callback(closeClicked), panel);
    _ = gtk.signalConnect(signal_verdict, "clicked", gtk.callback(verdictClicked), panel);
    panel.lyrics.init(self);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, root), panel.lyrics.root, "lyrics");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, root), scrolled(signal_body), "signal_path");
    _ = gtk.signalConnect(root, "destroy", gtk.callback(destroyed), panel);
    _ = gtk.signalConnect(split, "notify::show-sidebar", gtk.callback(sidebarShownChanged), panel);
    self.inspector = panel;

    applyVisibility(self);
}
