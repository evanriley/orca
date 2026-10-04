//! Shared frontend state and the library paging that fills the track list.
//!
//! Threading: every liborca call in this application happens on the GTK main
//! thread, from a signal handler or the tick that liborca's waker schedules.
//! There is no worker thread here and there must not be one — the runtime is
//! genuinely multithreaded behind the control lane, and its object pools take
//! no lock. The waker itself only writes `wake_fd`.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const mpris = @import("mpris.zig");
const art = @import("art.zig");
const menu = @import("menu.zig");
const track_model = @import("track_model.zig");
const track_table = @import("track_table.zig");
const track_filters = @import("track_filters.zig");
const album_filters = @import("album_filters.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const details = @import("details.zig");
const playlists = @import("playlists.zig");
const loved = @import("loved.zig");
const genres = @import("genres.zig");
const folders = @import("folders.zig");
const health = @import("health.zig");
const lyrics = @import("lyrics.zig");
const nowplaying = @import("nowplaying.zig");
const queue = @import("queue.zig");
const palette = @import("palette.zig");
const page_ui = @import("page.zig");
const parametric = @import("parametric.zig");

/// The list is filled a page at a time as the user scrolls, so a large
/// library stays virtualized.
pub const page_size: u32 = 512;
pub const search_delay_ms: c_uint = 200;
pub const open_album_page_limit = 32;
pub const open_artist_page_limit = 8;

pub const Sidebar = enum { hidden, details, lyrics, signal_path };

pub const PlayingKind = enum { track, release, artist };

pub const Playing = struct {
    track_id: ?i64 = null,
    release_id: ?i64 = null,
    artist_id: ?i64 = null,
    album_artist_id: ?i64 = null,

    pub fn matches(playing: Playing, kind: PlayingKind, id: ?i64) bool {
        const wanted = id orelse return false;
        return switch (kind) {
            .track => same(playing.track_id, wanted),
            .release => same(playing.release_id, wanted),
            .artist => same(playing.artist_id, wanted) or same(playing.album_artist_id, wanted),
        };
    }

    fn same(known: ?i64, wanted: i64) bool {
        return if (known) |id| id == wanted else false;
    }
};

pub const MarkedView = struct {
    view: *gtk.Widget,
    kind: PlayingKind,
};

const marked_view_limit = 8;

/// Which shelf of the library the track list is showing, and in what order.
///
/// This is a *request* the engine answers, not a description of the rows on
/// screen. Both halves matter: the filters are the relational ones liborca
/// indexes, and the sort is the engine's, because every ORDER BY it generates
/// ends in a unique tiebreaker and only a total order makes LIMIT/OFFSET paging
/// exact. Re-ordering the loaded rows instead would sort one page of a listing
/// the user is scrolling through thousands of.
pub const Browse = struct {
    artist_id: ?i64 = null,
    release_id: ?i64 = null,
    sort: liborca.TrackSort = .id,
    direction: liborca.SortDirection = .ascending,

    /// The order a newly entered scope is listed in. An album is listened to in
    /// disc-then-track order, an artist's shelf reads album by album, and an
    /// unscoped library has no natural order to claim, so it pays for none.
    pub fn defaultSort(self: Browse) liborca.TrackSort {
        if (self.release_id != null) return .track_number;
        if (self.artist_id != null) return .album;
        return .id;
    }
};

/// A NUL-terminated string the frontend owns: a widget writes it and an engine
/// query reads it. Empty means absent and allocates nothing, so the "no filter"
/// case costs no allocation on any of the keystrokes that pass through it.
pub const OwnedText = struct {
    value: [:0]u8 = &empty_text,

    /// Silently keeps the previous value if the copy cannot be allocated: a
    /// search box is not a place to fail, and the listing simply does not
    /// narrow.
    pub fn set(self: *OwnedText, allocator: std.mem.Allocator, text: []const u8) void {
        if (text.len == 0) return self.clear(allocator);
        const replacement = allocator.dupeSentinel(u8, text, 0) catch return;
        self.clear(allocator);
        self.value = replacement;
    }

    pub fn clear(self: *OwnedText, allocator: std.mem.Allocator) void {
        if (self.value.len != 0) allocator.free(self.value);
        self.value = &empty_text;
    }
};

pub const equalizer_band_count = @typeInfo(@FieldType(liborca.Equalizer, "gains_db")).array.len;
pub const crossfeed_amounts = [_]f32{ 0.2, 0.35, 0.5 };

/// The widgets of Settings' Sound tab that its handlers reach back to.
/// Reset when the page is left, since GTK destroys them with the tabs.
pub const SoundControls = struct {
    preset_row: ?*gtk.Widget = null,
    preset_names: ?*gtk.StringList = null,
    bands: ?*gtk.Widget = null,
    band_scales: [equalizer_band_count]?*gtk.Widget = @splat(null),
    preamp_row: ?*gtk.Widget = null,
    crossfeed_amount_row: ?*gtk.Widget = null,
    equalizer_title: ?*gtk.Widget = null,
    equalizer_meta: ?*gtk.Widget = null,
    equalizer_menu: ?*gtk.Widget = null,
    equalizer_header: ?*gtk.Widget = null,
    graphic: ?*gtk.Widget = null,
};

pub const SettingsTab = enum { general, library, playback, sound, listening, appearance, advanced };

pub const settings_tab_count = @typeInfo(SettingsTab).@"enum".fields.len;

pub const AudioFact = enum { output_format, sample_rate, bit_depth, channels };

pub const SettingsFit = enum { wide, stacked, icons };

pub const SettingsPage = struct {
    host: ?*gtk.Box = null,
    body: ?*gtk.Widget = null,
    tabs: ?*adw.ViewStack = null,
    tab_buttons: [settings_tab_count]?*gtk.ToggleButton = @splat(null),
    tab_labels: [settings_tab_count]?*gtk.Widget = @splat(null),
    columns: [settings_tab_count]?*gtk.Widget = @splat(null),
    folder_slot: ?*gtk.Box = null,
    measure_row: ?*gtk.Widget = null,
    measure_button: ?*gtk.Widget = null,
    device_row: ?*gtk.Widget = null,
    device_row_names: ?*gtk.StringList = null,
    device_drop_down: ?*gtk.DropDown = null,
    device_drop_down_names: ?*gtk.StringList = null,
    sources: ?*gtk.Box = null,
    genre_source_row: ?*gtk.Widget = null,
    tile_save_timer: c_uint = 0,
    audio_card: ?*gtk.Widget = null,
    audio_values: std.EnumArray(AudioFact, ?*gtk.Label) = .initFill(null),
    audio_idle: ?*gtk.Widget = null,
    audio_rows: ?*gtk.Widget = null,
    /// Set while the tab buttons and device lists are brought in line with
    /// state that has already changed, so their signals do not re-enter.
    syncing: bool = false,
    tab: SettingsTab = .library,
    fit: SettingsFit = .wide,
};

pub const ArtworkInfluence = enum { off, subtle };
pub const Density = enum { comfortable, compact };

pub const Appearance = struct {
    artwork: ArtworkInfluence = .subtle,
    album_grid_tile: c_int = default_album_tile_pixels,
    density: Density = .comfortable,
    inspector_open: bool = false,
    reduce_animation: bool = false,
    sidebar_counts: bool = false,
};

pub const default_album_tile_pixels: c_int = 148;
pub const album_tile_range = [2]c_int{ 112, 220 };

pub const TransportSurface = enum { bar, now_playing };

pub const TransportControls = struct {
    shuffle: ?*gtk.Widget = null,
    previous: ?*gtk.Widget = null,
    play: ?*gtk.Widget = null,
    next: ?*gtk.Widget = null,
    repeat: ?*gtk.Widget = null,
    scale: ?*gtk.Widget = null,
    elapsed: ?*gtk.Label = null,
    total: ?*gtk.Label = null,
};

pub const CredentialControls = struct {
    entry_row: ?*gtk.Widget = null,
    entry_title: ?*gtk.Label = null,
    reveal_button: ?*gtk.Widget = null,
    save_button: ?*gtk.Widget = null,
    stored_row: ?*gtk.Widget = null,
    remove_button: ?*gtk.Widget = null,
    unlock_button: ?*gtk.Widget = null,
    saving: bool = false,
    checked: bool = false,
};

pub const ListeningControls = struct {
    now_playing_row: ?*gtk.Widget = null,
    status_row: ?*gtk.Widget = null,
    token: CredentialControls = .{},
    status_text: [192]u8 = undefined,
    status_len: usize = 0,
};

pub const Task = enum { scan, analysis, duplicates, tag_write, matching, submission };

pub const default_match_threshold_percent: u8 = 90;

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *liborca.Runtime,
    wake_fd: std.os.linux.fd_t,
    timeout_source: c_uint = 0,

    /// Optionals rather than `has_*` flags: an absent Library is `null`, and
    /// there is no second field to keep in step with it.
    library: ?liborca.LibraryHandle = null,
    player: liborca.PlayerHandle = undefined,
    zone: ?liborca.ZoneHandle = null,
    /// The background job this frontend started and is showing, if any.
    task: ?Task = null,
    task_job: ?liborca.JobHandle = null,
    /// The undo group of the last tag write, for the toast's Undo.
    tag_write_group: u64 = 0,
    /// The one Track a `.matching` task searches, when it searches one.
    match_task_track: ?i64 = null,
    /// The Release a `.matching` task matches or fetches the cover of.
    match_task_release: ?i64 = null,
    match_task_mode: liborca.MatchMode = .search,
    /// The Track whose own search last found nothing, so its details say so.
    unmatched_track: ?i64 = null,
    /// Tracks the running matching job had matched when the badge was last
    /// counted.
    shown_matched: u64 = 0,
    /// The output device chosen in Settings, by name, so the choice
    /// survives device ids being renumbered between runs.
    preferred_output: OwnedText = .{},
    library_path: ?[:0]u8 = null,
    /// Output pinned by `ORCA_OUTPUT_DEVICE`, overriding the device dropdown.
    /// Development affordance only: it exists so an automated run can be held to a
    /// silent sink instead of device 0, which is the system default and therefore
    /// somebody's speakers.
    pinned_output_device: ?u64 = null,
    /// Correlates the last `play_track` submission with its completion event, so
    /// a refused play reports why instead of silently doing nothing.
    pending_play_request: u64 = 0,

    tracks: track_table.Table = .{},
    track_columns: track_table.Config = .{},
    track_filters: track_filters.Filters = .{},
    track_filters_ui: track_filters.Ui = .{},
    scroller: ?*gtk.Widget = null,
    query: OwnedText = .{},
    loaded_rows: u32 = 0,
    page_exhausted: bool = false,
    track_total: u64 = 0,
    browse: Browse = .{},
    sort_dropdown: ?*gtk.DropDown = null,

    artists: ?*gtk.ListStore = null,
    artist_selection: ?*gtk.SingleSelection = null,
    artists_loaded: u32 = 0,
    artists_exhausted: bool = false,
    releases: ?*gtk.ListStore = null,
    release_selection: ?*gtk.SingleSelection = null,
    releases_loaded: u32 = 0,
    releases_exhausted: bool = false,
    artist_header: ?*gtk.Label = null,
    release_header: ?*gtk.Label = null,
    /// What the Artist pane's search box says. Passed to liborca unfolded — the
    /// engine folds it exactly as it folded `artists.key`, and a frontend that
    /// folded it here would be keeping a second copy of that definition.
    artist_filter: OwnedText = .{},
    artist_search_entry: ?*gtk.Editable = null,
    /// The name of the Artist the Releases pane is scoped to, for its header.
    /// Kept rather than re-queried because the header is rewritten on every
    /// release page load and the name cannot have changed between them.
    artist_scope_name: OwnedText = .{},
    /// Set while a widget is being brought back in line with state that has
    /// already changed. Its "changed" signal still fires, and without this it
    /// would re-enter as though the user had done it.
    suppress_browse_signals: bool = false,

    application: ?*gtk.Application = null,
    window: ?*gtk.Window = null,
    toasts: ?*adw.ToastOverlay = null,
    split_view: ?*adw.NavigationSplitView = null,
    content_page: ?*adw.NavigationPage = null,
    nav_items: std.EnumArray(window.Page, ?*gtk.Widget) = .initFill(null),
    library_counts: std.EnumArray(window.LibraryCount, ?*gtk.Label) = .initFill(null),
    pages: ?*gtk.Stack = null,
    current_page: window.Page = .albums,
    history: window.History = .{},
    top_bar: page_ui.Bar = .{},
    filtered_page: ?window.Page = null,
    tracks_meta: ?*gtk.Label = null,
    /// The Tracks page's body: the browser and list, or a status page when
    /// there is nothing to list.
    tracks_body: ?*gtk.Stack = null,
    welcome: ?*adw.StatusPage = null,
    welcome_button: ?*gtk.Widget = null,
    welcome_spinner: ?*gtk.Widget = null,
    browse_panes: ?*gtk.Widget = null,
    browse_toggle: ?*gtk.Widget = null,
    list_toggle: ?*gtk.Widget = null,

    /// What the inspector shows, restored from settings.
    sidebar_page: Sidebar = .hidden,
    /// Set while the window is below the breakpoint that lays the inspector
    /// over the content.
    window_narrow: bool = false,
    inspector_overlaid: bool = false,
    inspector: ?*details.Panel = null,
    header_compact: bool = false,
    inspector_crowded: bool = false,
    lyrics: lyrics.State = .{},
    seen_recorded_listens: u64 = 0,

    album_store: ?*gtk.ListStore = null,
    albums_loaded: u32 = 0,
    albums_exhausted: bool = false,
    albums_meta: ?*gtk.Label = null,
    albums_body: ?*gtk.Stack = null,
    albums_navigation: ?*adw.NavigationView = null,
    album_sort: liborca.ReleaseSort = .artist,
    album_shelf_sort: liborca.ReleaseSort = .artist,
    album_shelf: albums.Shelf = .all,
    album_sort_control: ?*gtk.DropDown = null,
    album_chips: [std.meta.fields(albums.Chip).len]?*gtk.ToggleButton = @splat(null),
    album_filters: album_filters.Filters = .{},
    album_filters_ui: album_filters.Ui = .{},
    album_search: OwnedText = .{},
    album_artist_filter: ?albums.ArtistFilter = null,
    album_artist_name: OwnedText = .{},
    album_artist_chip: ?*gtk.Widget = null,
    album_layout: albums.Layout = .grid,
    album_layout_toggles: [std.meta.fields(albums.Layout).len]?*gtk.ToggleButton = @splat(null),
    album_grid: ?*gtk.GridView = null,
    album_grid_columns: c_uint = 0,
    album_grid_idle: c_uint = 0,
    album_tile_pixels: c_int = default_album_tile_pixels,
    album_columns: albums.ColumnSet = .initEmpty(),
    album_info: albums.Info = .{},
    albums_empty: ?*adw.StatusPage = null,
    albums_syncing_controls: bool = false,
    open_album_pages: [open_album_page_limit]*albums.AlbumPage = undefined,
    open_album_page_count: usize = 0,
    open_artist_pages: [open_artist_page_limit]*artists.ArtistPage = undefined,
    open_artist_page_count: usize = 0,

    now_playing: nowplaying.State = .{},

    art: art.Cache = .{},
    /// What the open right-click menu acts on.
    context: menu.Context = .{},
    playlists: playlists.State = .{},
    loved: loved.State = .{},
    genres: genres.State = .{},
    folders: folders.State = .{},
    palette: palette.State = .{},

    health: health.State = .{},

    matches_list: ?*gtk.ListBox = null,
    matches_corrections: ?*gtk.ListBox = null,
    matches_corrections_box: ?*gtk.Widget = null,
    matches_group_count: u64 = 0,
    matches_note: ?*gtk.Label = null,
    matches_body: ?*gtk.Stack = null,
    matches_meta: ?*gtk.Label = null,
    matches_count: ?*gtk.Label = null,
    matches_empty: ?*adw.StatusPage = null,
    matches_empty_button: ?*gtk.Widget = null,
    matches_accept_button: ?*gtk.Widget = null,
    matches_submit_button: ?*gtk.Widget = null,
    /// The Track whose row is open, kept open across reloads.
    matches_open_track: ?i64 = null,
    /// Accept Confident takes a track's best match at or above this.
    match_threshold_percent: u8 = default_match_threshold_percent,
    match_fingerprints: bool = true,
    acoustid_key_stored: bool = false,
    acoustid_controls: CredentialControls = .{},

    settings_page: SettingsPage = .{},
    appearance: Appearance = .{},

    /// Files Measure Loudness decodes at once; null takes liborca's default.
    analysis_threads: ?u16 = null,
    watch_folders: bool = true,
    watch_row: ?*gtk.Widget = null,
    watch_status_text: [320]u8 = undefined,
    watch_status_len: usize = 0,
    idle_maintenance: bool = false,
    maintenance_row: ?*gtk.Widget = null,
    maintenance_status_text: [128]u8 = undefined,
    maintenance_status_len: usize = 0,
    maintenance_units_seen: u64 = 0,

    scrobbling: bool = false,
    announce_now_playing: bool = false,
    listening_controls: ListeningControls = .{},

    sound_controls: SoundControls = .{},
    /// The curve the equalizer had when last on or being edited, so switching
    /// it off and on again restores it.
    equalizer_curve: liborca.Equalizer = .{},
    /// GLib source that applies `equalizer_curve` once a slider drag settles;
    /// zero when none is pending.
    equalizer_apply_timer: c_uint = 0,
    crossfeed_amount: f32 = crossfeed_amounts[1],
    /// Set while the Sound page's widgets are being brought in line with state
    /// that has already changed, so their signals do not re-enter as edits.
    suppress_sound_signals: bool = false,
    parametric: parametric.State = .{},

    artist_list_store: ?*gtk.ListStore = null,
    artist_list_loaded: u32 = 0,
    artist_list_exhausted: bool = false,
    artist_list_filter: OwnedText = .{},
    artist_list_genre: ?i64 = null,
    artist_list_genre_name: OwnedText = .{},
    artist_genre_chip: ?*gtk.Widget = null,
    artist_list_meta: ?*gtk.Label = null,
    artists_navigation: ?*adw.NavigationView = null,
    artist_sort: liborca.ArtistSort = .name,
    artist_sort_control: ?*gtk.DropDown = null,
    artist_layout: albums.Layout = .grid,
    artist_layout_toggles: [std.meta.fields(albums.Layout).len]?*gtk.ToggleButton = @splat(null),
    artist_grid: ?*gtk.GridView = null,
    artist_grid_columns: c_uint = 0,
    artist_grid_idle: c_uint = 0,
    artist_tile_pixels: c_int = 150,
    artists_body: ?*gtk.Stack = null,
    artists_empty: ?*adw.StatusPage = null,
    artists_syncing_controls: bool = false,
    artist_info: artists.Info = .{},
    fetch_artist_info: bool = true,

    scan_revealer: ?*gtk.Revealer = null,
    activity_label: ?*gtk.Label = null,
    activity_percent: ?*gtk.Label = null,
    activity_bar: ?*gtk.ProgressBar = null,
    activity_popover: ?*gtk.Popover = null,
    scan_label: ?*gtk.Label = null,
    scan_detail: ?*gtk.Label = null,

    transport_controls: std.EnumArray(TransportSurface, TransportControls) = .initFill(.{}),
    seek_adjustment: ?*gtk.Adjustment = null,
    now_playing_title: ?*gtk.Label = null,
    now_playing_detail: ?*gtk.Label = null,
    /// The now-playing cover. One widget in two states: a paintable when the
    /// audible track's file carries a readable image, and a placeholder icon
    /// when it does not, so there is no second widget to keep visible in step
    /// with a nullable image.
    now_playing_art: ?*gtk.Widget = null,
    now_playing_box: ?*gtk.Widget = null,
    love_button: ?*gtk.Widget = null,
    now_love_button: ?*gtk.Widget = null,
    volume_adjustment: ?*gtk.Adjustment = null,
    volume_icon: ?*gtk.Widget = null,
    volume_scale: ?*gtk.Widget = null,
    volume_menu: ?*gtk.Widget = null,
    device_list: ?*gtk.ListBox = null,
    device_popover: ?*gtk.Popover = null,
    device_label: ?*gtk.Label = null,
    device_icon: ?*gtk.Widget = null,
    signal_path_label: ?*gtk.Label = null,
    format_slot: ?*gtk.Widget = null,
    format_button: ?*gtk.Widget = null,
    format_label: ?*gtk.Label = null,
    signal_path_popover: ?*gtk.Popover = null,
    signal_path_has_output: bool = false,
    volume_settle_timer: c_uint = 0,
    device_ids: std.ArrayList(u64) = .empty,
    device_checks: std.ArrayList(*gtk.Widget) = .empty,
    /// Names in `device_ids` order, as the output menu shows them.
    device_names: std.ArrayList([:0]u8) = .empty,
    /// Index into `device_ids` of the output the next Zone opens on.
    device_index: usize = 0,
    /// A drag in flight: the tick stops writing the slider, and the seek is
    /// applied once the value settles.
    seeking: bool = false,
    seek_pending_ms: i64 = 0,
    seek_settle_timer: c_uint = 0,
    suppress_widget_writeback: bool = false,
    last_seen_duration_ms: u64 = 0,
    /// What the now-playing labels currently show, so the resolve query only
    /// runs when the audible entry actually changes.
    shown_track_id: ?i64 = null,
    shown_playing: Playing = .{},
    marked_views: [marked_view_limit]?MarkedView = @splat(null),
    shown_recording_id: ?i64 = null,
    shown_feedback: liborca.Feedback = .none,
    shown_transport: liborca.TransportState = .stopped,
    repeat_mode: liborca.RepeatMode = .off,

    queue: queue.State = .{},
    queue_count: ?*gtk.Label = null,
    queue_visible: bool = false,

    mpris: mpris.Mpris = .{},

    pub fn requestTick(self: *App) void {
        writeWake(&self.wake_fd);
    }

    pub fn waker(self: *App) liborca.HostWaker {
        return .{ .context = &self.wake_fd, .wake_fn = writeWake };
    }

    pub fn playing(self: *App) Playing {
        const track_id = self.shown_track_id;
        const known = self.shown_playing.track_id;
        if (track_id == null and known == null) return self.shown_playing;
        if (track_id != null and known != null and track_id.? == known.?) return self.shown_playing;
        self.shown_playing = self.resolvePlaying(track_id);
        return self.shown_playing;
    }

    fn resolvePlaying(self: *App, track_id: ?i64) Playing {
        const id = track_id orelse return .{};
        var result: Playing = .{ .track_id = id };
        const library = self.library orelse return result;
        const summary = (self.runtime.libraryTrackSummary(library, id) catch null) orelse return result;
        defer summary.deinit(self.allocator);
        result.release_id = summary.release_id;
        result.artist_id = summary.artist_id;
        const release_id = summary.release_id orelse return result;
        const release = (self.runtime.libraryRelease(library, release_id) catch null) orelse return result;
        defer release.deinit(self.allocator);
        result.album_artist_id = release.album_artist_id;
        return result;
    }

    pub fn toast(self: *App, message: [:0]const u8) void {
        const overlay = self.toasts orelse return;
        const item = adw.adw_toast_new(message.ptr);
        adw.adw_toast_set_timeout(item, 3);
        adw.adw_toast_overlay_add_toast(overlay, item);
    }

    /// The one place the track listing is described to liborca.
    ///
    /// A search keeps the Filters popover's filters but leaves the scope out:
    /// the panes are reset to "All" when a search starts, and this keeps that
    /// true even if a caller forgets.
    ///
    /// The Artist pane's filter is *not* part of this. It narrows which Artists
    /// are listed and never reaches a `TrackQuery`, so it and a track search are
    /// free to hold text at the same time without either one being half applied.
    pub fn trackRequest(self: *App, offset: u32) liborca.TrackQuery {
        const searching = self.query.value.len != 0;
        return .{
            .artist_id = if (searching) null else self.browse.artist_id,
            .release_id = if (searching) null else self.browse.release_id,
            .genre_id = self.track_filters.genre_id,
            .loved_only = self.track_filters.loved_only,
            .year_min = self.track_filters.year_from,
            .year_max = self.track_filters.year_to,
            .lossless = switch (self.track_filters.format) {
                .any => null,
                .lossless => true,
                .lossy => false,
            },
            .min_sample_rate = self.track_filters.min_sample_rate,
            .explicit_only = self.track_filters.explicit_only,
            .sort = self.browse.sort,
            .direction = self.browse.direction,
            .limit = page_size,
            .offset = offset,
        };
    }

    /// The one place the Artist pane is described to liborca.
    ///
    /// The filter text is handed over exactly as typed. Folding it is the
    /// engine's definition of artist identity — the same fold that produced
    /// `artists.key` — and doing it here would be a second copy of that
    /// definition, free to drift from the one the rows were keyed by.
    pub fn artistRequest(self: *App, offset: u32) liborca.ArtistQuery {
        return .{
            .filter = self.artist_filter.value,
            .limit = page_size,
            .offset = offset,
        };
    }

    /// The one place the Release pane is described to liborca. The Artist
    /// filter above narrows which Artists are *listed*; this one is the Artist
    /// the user picked, which is a different question and the only one a
    /// Release listing can be scoped by.
    pub fn releaseRequest(self: *App, offset: u32) liborca.ReleaseQuery {
        return .{
            .album_artist_id = self.browse.artist_id,
            .limit = page_size,
            .offset = offset,
        };
    }

    /// Puts the listing in its scope's default order, and shows that on the
    /// column headers so the view and the query cannot disagree.
    pub fn applyScopeDefaultSort(self: *App) void {
        self.browse.sort = self.browse.defaultSort();
        self.browse.direction = .ascending;
        window.showSort(self);
    }

    fn updateCountLabel(self: *App) void {
        const meta = self.tracks_meta orelse return;
        if (self.library == null) {
            gtk.gtk_label_set_text(meta, "No library");
            return;
        }
        var buffer: [96]u8 = undefined;
        const text = if (self.query.value.len != 0)
            strings.printZ(&buffer, "{d}{s} matching", .{
                self.loaded_rows,
                if (self.page_exhausted) "" else "+",
            }) catch ""
        else if (self.track_total == 1)
            "1 track"
        else
            strings.printZ(&buffer, "{d} tracks", .{self.track_total}) catch "";
        gtk.gtk_label_set_text(meta, text.ptr);
    }

    /// Chooses what the Tracks page shows: the listing, a welcome for a library
    /// with nothing in it, or a note that a search found nothing.
    pub fn updateTracksBody(self: *App) void {
        const body = self.tracks_body orelse return;
        const searching = self.query.value.len != 0;
        const scoped = self.browse.artist_id != null or self.browse.release_id != null;
        if (self.loaded_rows != 0 or scoped) {
            gtk.gtk_stack_set_visible_child_name(body, "list");
        } else if (searching or self.track_filters.active()) {
            gtk.gtk_stack_set_visible_child_name(body, "no-results");
        } else {
            self.updateWelcome();
            gtk.gtk_stack_set_visible_child_name(body, "welcome");
        }
    }

    /// The welcome page doubles as progress for a first scan, so a new library
    /// never shows an empty table while it is being read.
    pub fn updateWelcome(self: *App) void {
        const page = self.welcome orelse return;
        if (self.task == .scan) {
            adw.adw_status_page_set_icon_name(page, null);
            adw.adw_status_page_set_title(page, "Reading your music…");
            adw.adw_status_page_set_description(page, "Albums appear here as they are found.");
        } else {
            adw.adw_status_page_set_icon_name(page, "folder-music-symbolic");
            adw.adw_status_page_set_title(page, "Welcome to Orca");
            adw.adw_status_page_set_description(
                page,
                "Add the folder your music lives in. Orca reads it and never changes a file unless you ask.",
            );
        }
        if (self.welcome_button) |button| gtk.gtk_widget_set_visible(button, if (self.task == .scan) gtk.false_ else gtk.true_);
        if (self.welcome_spinner) |spinner| gtk.gtk_widget_set_visible(spinner, if (self.task == .scan) gtk.true_ else gtk.false_);
    }

    /// Fetches exactly one bounded page and appends it. The page is caller-owned
    /// and released here; the rows copy everything they keep.
    pub fn loadNextPage(self: *App) void {
        const library = self.library orelse return;
        if (self.page_exhausted) return;
        const store = self.tracks.store orelse return;
        var page = self.runtime.libraryTrackQuery(
            library,
            self.query.value,
            self.trackRequest(self.loaded_rows),
        ) catch {
            self.page_exhausted = true;
            self.toast("Unable to query the library");
            return;
        };
        defer page.deinit();
        if (page.items.len < page_size) self.page_exhausted = true;
        if (page.items.len == 0) {
            self.updateCountLabel();
            return;
        }
        var additions = std.ArrayList(?*anyopaque).initCapacity(
            self.allocator,
            page.items.len,
        ) catch {
            self.toast("Out of memory building the track list");
            return;
        };
        defer additions.deinit(self.allocator);
        for (page.items) |item| {
            const row = track_model.new(item) orelse continue;
            additions.appendAssumeCapacity(row);
        }
        if (additions.items.len != 0) {
            gtk.g_list_store_splice(
                store,
                gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
                0,
                additions.items.ptr,
                @intCast(additions.items.len),
            );
            self.loaded_rows += @intCast(additions.items.len);
            for (additions.items) |row| gtk.g_object_unref(row);
        }
        self.updateCountLabel();
    }

    pub fn reload(self: *App) void {
        const store = self.tracks.store orelse return;
        gtk.g_list_store_remove_all(store);
        self.loaded_rows = 0;
        self.page_exhausted = false;
        self.track_total = 0;
        const library = self.library orelse {
            self.updateCountLabel();
            self.updateTracksBody();
            return;
        };
        // A full-text match has no cheap total — FTS5 ranks rather than counts —
        // so a search reports what it has loaded and nothing it has not.
        self.track_total = if (self.query.value.len != 0)
            0
        else
            self.runtime.libraryTrackMatchCount(library, self.trackRequest(0)) catch 0;
        // A scroller left deep in the previous listing would page from the
        // bottom of a list that is now one page long.
        if (self.scroller) |scroller| gtk.gtk_adjustment_set_value(
            gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
            0.0,
        );
        self.loadNextPage();
        self.updateTracksBody();
        details.invalidate(self);
    }

    pub fn deinit(self: *App) void {
        self.history.deinit();
        if (self.equalizer_apply_timer != 0) _ = gtk.g_source_remove(self.equalizer_apply_timer);
        parametric.deinit(self);
        if (self.seek_settle_timer != 0) _ = gtk.g_source_remove(self.seek_settle_timer);
        if (self.volume_settle_timer != 0) _ = gtk.g_source_remove(self.volume_settle_timer);
        self.tracks.deinit();
        self.track_filters_ui.deinit(self.allocator);
        self.album_filters_ui.deinit(self.allocator);
        self.album_info.deinit(self.allocator);
        self.artist_info.deinit(self.allocator);
        self.query.clear(self.allocator);
        self.artist_filter.clear(self.allocator);
        self.artist_scope_name.clear(self.allocator);
        self.device_ids.deinit(self.allocator);
        self.device_checks.deinit(self.allocator);
        for (self.device_names.items) |name| self.allocator.free(name);
        self.device_names.deinit(self.allocator);
        self.art.deinit(self.allocator);
        self.context.deinit(self.allocator);
        self.playlists.deinit(self.allocator);
        self.artist_list_filter.clear(self.allocator);
        self.artist_list_genre_name.clear(self.allocator);
        self.album_search.clear(self.allocator);
        self.album_artist_name.clear(self.allocator);
        self.genres.deinit(self.allocator);
        self.folders.deinit(self.allocator);
        self.palette.deinit(self.allocator);
        self.preferred_output.clear(self.allocator);
        if (self.library_path) |path| self.allocator.free(path);
    }
};

fn writeWake(context: ?*anyopaque) callconv(.c) void {
    const wake_fd: *const std.os.linux.fd_t = @ptrCast(@alignCast(context.?));
    const increment: u64 = 1;
    _ = std.os.linux.write(wake_fd.*, std.mem.asBytes(&increment), @sizeOf(u64));
}

var empty_text: [0:0]u8 = .{};
