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
const artist_page = @import("artist_page.zig");
const details = @import("details.zig");
const playlists = @import("playlists.zig");
const loved = @import("loved.zig");
const genres = @import("genres.zig");
const folders = @import("folders.zig");
const offline = @import("offline.zig");
const health = @import("health.zig");
const activity = @import("activity.zig");
const changes = @import("changes.zig");
const duplicates = @import("duplicates.zig");
const audio_problems = @import("audio_problems.zig");
const matches = @import("matches.zig");
const match_review = @import("match_review.zig");
const artwork_review = @import("artwork_review.zig");
const metadata_issues = @import("metadata_issues.zig");
const first_run = @import("first_run.zig");
const jobs = @import("jobs.zig");
const lyrics = @import("lyrics.zig");
const nowplaying = @import("nowplaying.zig");
const queue = @import("queue.zig");
const palette = @import("palette.zig");
const page_ui = @import("page.zig");
const parametric = @import("parametric.zig");
const libraries = @import("libraries.zig");

/// The list is filled a page at a time as the user scrolls, so a large
/// library stays virtualized.
pub const page_size: u32 = 512;
pub const search_delay_ms: c_uint = 200;
const browse_retry_ms: c_uint = 25;
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
    sort: liborca.TrackSort = .date_added,
    direction: liborca.SortDirection = .descending,

    /// The order a newly entered scope is listed in. An album is listened to in
    /// disc-then-track order, an artist's shelf reads album by album, and the
    /// whole library lists what arrived most recently first.
    pub fn defaultSort(self: Browse) liborca.TrackSort {
        if (self.release_id != null) return .track_number;
        if (self.artist_id != null) return .album;
        return .date_added;
    }

    pub fn defaultDirection(self: Browse) liborca.SortDirection {
        return if (self.defaultSort() == .date_added) .descending else .ascending;
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
pub const crossfeed_amounts = [_]f32{ 0.3, 0.5, 0.7 };

/// The widgets of Settings' Sound tab that its handlers reach back to.
/// Reset when the page is left, since GTK destroys them with the tabs.
pub const SoundControls = struct {
    preset_row: ?*gtk.Widget = null,
    preset_names: ?*gtk.StringList = null,
    bands: ?*gtk.Widget = null,
    band_scales: [equalizer_band_count]?*gtk.Widget = @splat(null),
    preamp_row: ?*gtk.Widget = null,
    crossfeed_amount_row: ?*gtk.Widget = null,
    equalizer_header: ?*gtk.Widget = null,
    mode_buttons: [3]?*gtk.ToggleButton = @splat(null),
    graphic: ?*gtk.Widget = null,
    stop_after_current: ?*gtk.Widget = null,
    queue_end: ?*gtk.DropDown = null,
    device_presets: ?*gtk.Widget = null,
    device_preset_rows: [max_device_preset_rows]?*gtk.Widget = @splat(null),
    device_preset_row_count: usize = 0,
    device_switch_row: ?*gtk.Widget = null,
};

pub const max_device_preset_rows = 33;

pub const SettingsTab = enum { general, library, playback, sound, listening, appearance, advanced, about };

pub const settings_tab_count = @typeInfo(SettingsTab).@"enum".fields.len;

pub const SettingsFit = enum { wide, icons };

pub const SettingsPage = struct {
    host: ?*gtk.Box = null,
    body: ?*gtk.Widget = null,
    tabs: ?*adw.ViewStack = null,
    tab_buttons: [settings_tab_count]?*gtk.ToggleButton = @splat(null),
    tab_labels: [settings_tab_count]?*gtk.Widget = @splat(null),
    columns: [settings_tab_count]?*gtk.Widget = @splat(null),
    contents: [settings_tab_count]?*gtk.Widget = @splat(null),
    filter_hidden: [settings_filter_capacity]*gtk.Widget = undefined,
    filter_hidden_len: usize = 0,
    subtitle: ?*gtk.Label = null,
    folder_slot: ?*gtk.Box = null,
    measure_row: ?*gtk.Widget = null,
    measure_button: ?*gtk.Widget = null,
    threads: Stepper = .{},
    threshold: Stepper = .{},
    cache_value: ?*gtk.Label = null,
    device_drop_down: ?*gtk.DropDown = null,
    device_drop_down_names: ?*gtk.StringList = null,
    genre_source_row: ?*gtk.Widget = null,
    tile_save_timer: c_uint = 0,
    tile_scale: ?*gtk.Range = null,
    /// Set while the tab buttons and device lists are brought in line with
    /// state that has already changed, so their signals do not re-enter.
    syncing: bool = false,
    tab: SettingsTab = .general,
    fit: SettingsFit = .wide,
};

pub const settings_filter_capacity = 512;

pub const Stepper = struct {
    value: ?*gtk.Label = null,
    decrease: ?*gtk.Widget = null,
    increase: ?*gtk.Widget = null,
};

pub const ArtworkInfluence = enum { off, subtle, expressive };
pub const Density = enum { comfortable, compact };
pub const InspectorMode = enum { open_on_selection, remember, closed };
pub const DisplayTypeface = enum { newsreader, interface };

pub const Appearance = struct {
    artwork: ArtworkInfluence = .subtle,
    album_grid_tile: c_int = default_album_tile_pixels,
    density: Density = .comfortable,
    inspector: InspectorMode = .open_on_selection,
    reduce_animation: bool = false,
    sidebar_counts: bool = true,
    display_typeface: DisplayTypeface = .newsreader,
    tabular_numerals: bool = true,
};

pub const StartPage = enum { albums, artists, tracks, now_playing };

pub const General = struct {
    launch_at_login: bool = false,
    start_page: StartPage = .albums,
    notify_tracks: bool = false,
    notify_tasks: bool = true,
    name_order: liborca.NameOrder = .ignore_articles,
};

pub const OnLaunch = enum { restore_paused, restore_playing, start_empty };

pub const Playback = struct {
    remember_long_position: bool = true,
    on_launch: OnLaunch = .restore_paused,
};

pub const default_album_tile_pixels: c_int = 132;
pub const album_tile_range = [2]c_int{ 88, 184 };

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
    entry_box: ?*gtk.Widget = null,
    open_button: ?*gtk.Widget = null,
    stored: bool = false,
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
    pending_row: ?*gtk.Widget = null,
    pending_value: ?*gtk.Label = null,
    token: CredentialControls = .{},
};

pub const TotalsRequest = union(enum) {
    idle,
    /// The browse loader was full; asked for again by the retry timer.
    waiting,
    pending: u64,
};

pub const Failure = enum { none, unreported, reported };

pub const Task = enum { scan, analysis, duplicates, tag_write, matching, submission, backfill, consistency };

/// A Job this frontend started or retried, with what its end should report.
pub const TrackedTask = struct {
    task: Task,
    job: liborca.JobHandle,
    /// The one Track a `.matching` task searches, when it searches one.
    match_track: ?i64 = null,
    /// The Release a `.matching` task matches or fetches the cover of.
    match_release: ?i64 = null,
    match_mode: liborca.MatchMode = .search,
    /// The undo group a `.tag_write` task writes.
    tag_write_group: u64 = 0,
    /// Tracks a `.matching` task had matched when the badge was last counted.
    shown_matched: u64 = 0,
};

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
    /// The background Jobs this frontend started, running or waiting.
    tasks: [activity.max_cards]TrackedTask = undefined,
    task_count: usize = 0,
    backfill_checked: bool = false,
    /// The undo group of the last tag write, for the toast's Undo.
    tag_write_group: u64 = 0,
    /// The Track whose own search last found nothing, so its details say so.
    unmatched_track: ?i64 = null,
    /// The output device chosen in Settings, by name, so the choice
    /// survives device ids being renumbered between runs.
    preferred_output: OwnedText = .{},
    library_path: ?[:0]u8 = null,
    libraries: libraries.State = .{},
    /// Output pinned by `ORCA_OUTPUT_DEVICE`, overriding the device dropdown.
    /// Development affordance only: it exists so an automated run can be held to a
    /// silent sink instead of device 0, which is the system default and therefore
    /// somebody's speakers.
    pinned_output_device: ?u64 = null,
    debug_frames: bool = false,
    debug_reveal: bool = false,
    frame_started_us: i64 = 0,
    slowest_frame_us: i64 = 0,
    /// Correlates the last `play_track` submission with its completion event, so
    /// a refused play reports why instead of silently doing nothing.
    pending_play_request: u64 = 0,

    tracks: track_table.Table = .{},
    track_columns: track_table.Config = .{},
    track_columns_large: track_table.Config = .initial(.large),
    track_filters: track_filters.Filters = .{},
    track_filters_ui: track_filters.Ui = .{},
    scroller: ?*gtk.Widget = null,
    query: OwnedText = .{},
    /// The listing's length and summed duration, as the engine counts them.
    track_count: u32 = 0,
    track_duration_ms: u64 = 0,
    /// Every Track in the library, measured when the listing is unfiltered
    /// or the Tracks page needs it, and forgotten when the library changes.
    track_library_total: ?u64 = null,
    tracks_totals: TotalsRequest = .idle,
    tracks_failure: Failure = .none,
    /// GLib source that asks again for what the browse loader refused;
    /// zero when none is pending.
    browse_retry_source: c_uint = 0,
    /// Set while the Tracks page uses its large form.
    tracks_large: bool = false,
    tracks_title_end: ?*gtk.Widget = null,
    tracks_title_text: ?*gtk.Widget = null,
    tracks_columns_corner: ?*gtk.Widget = null,
    tracks_page: ?*gtk.Widget = null,
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
    browse_chosen: bool = false,
    browse_collapsed: bool = false,
    browse_action: ?*gtk.GSimpleAction = null,

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

    album_model: ?*albums.PagedReleases = null,
    albums_count: u64 = 0,
    albums_count_request: TotalsRequest = .idle,
    albums_failure: Failure = .none,
    albums_meta: ?*gtk.Label = null,
    albums_unavailable: ?*gtk.Label = null,
    albums_body: ?*gtk.Stack = null,
    albums_navigation: ?*adw.NavigationView = null,
    album_sort: liborca.ReleaseSort = .recently_added,
    album_shelf: albums.Shelf = .all,
    album_added: albums.Added = .{},
    album_sections: albums.Sections = .{},
    album_sort_control: ?*gtk.DropDown = null,
    album_chips: [std.meta.fields(albums.Chip).len]?*gtk.ToggleButton = @splat(null),
    album_filters: album_filters.Filters = .{},
    album_filters_ui: album_filters.Ui = .{},
    album_search: OwnedText = .{},
    album_artist_filter: ?albums.ArtistFilter = null,
    album_artist_name: OwnedText = .{},
    album_artist_chip: ?*gtk.Widget = null,
    album_layout: albums.Layout = .grid,
    album_layout_toggles: [2][std.meta.fields(albums.Layout).len]?*gtk.ToggleButton = @splat(@splat(null)),
    album_grid: ?*gtk.GridView = null,
    album_grid_columns: c_uint = 0,
    album_grid_idle: c_uint = 0,
    album_tile_pixels: c_int = default_album_tile_pixels,
    album_cover_scale: ?*gtk.Range = null,
    album_columns: albums.ColumnSet = .initEmpty(),
    album_info: albums.Info = .{},
    albums_empty: ?*adw.StatusPage = null,
    albums_syncing_controls: bool = false,
    open_album_pages: [open_album_page_limit]*albums.AlbumPage = undefined,
    open_album_page_count: usize = 0,
    open_artist_pages: [open_artist_page_limit]*artist_page.ArtistPage = undefined,
    open_artist_page_count: usize = 0,

    now_playing: nowplaying.State = .{},

    art: art.Cache = .{},
    /// What the open right-click menu acts on.
    context: menu.Context = .{},
    playlists: playlists.State = .{},
    loved: loved.State = .{},
    genres: genres.State = .{},
    folders: folders.State = .{},
    offline: offline.State = .{},
    folders_count: ?*gtk.Label = null,
    palette: palette.State = .{},

    health: health.State = .{},
    activity: activity.State = .{},
    changes: changes.State = .{},
    duplicates: duplicates.State = .{},
    audio_problems: audio_problems.State = .{},
    artwork_review: artwork_review.State = .{},
    metadata_issues: metadata_issues.State = .{},
    first_run: first_run.State = .{},

    matches: matches.State = .{},
    match_review: match_review.State = .{},
    matches_count: ?*gtk.Label = null,
    /// An album is confident when its best release is at or above this.
    match_threshold_percent: u8 = default_match_threshold_percent,
    match_fingerprints: bool = true,
    acoustid_key_stored: bool = false,
    acoustid_controls: CredentialControls = .{},

    settings_page: SettingsPage = .{},
    appearance: Appearance = .{},
    general: General = .{},
    playback: Playback = .{},

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

    transport_controls: TransportControls = .{},
    seek_adjustment: ?*gtk.Adjustment = null,
    now_playing_title: ?*gtk.Label = null,
    now_playing_detail: ?*gtk.Label = null,
    now_playing_alert: ?*gtk.Widget = null,
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
    shown_failure_track: ?i64 = null,
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
            .min_sample_rate = if (self.track_filters.rate_above) |rate| rate + 1 else null,
            .codec = if (self.track_filters.codec) |codec| @tagName(codec) else null,
            .added_after = self.track_filters.added.after,
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
            .name_order = self.general.name_order,
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
            .name_order = self.general.name_order,
            .limit = page_size,
            .offset = offset,
        };
    }

    /// Puts the listing in its scope's default order, and shows that on the
    /// column headers so the view and the query cannot disagree.
    pub fn applyScopeDefaultSort(self: *App) void {
        self.browse.sort = self.browse.defaultSort();
        self.browse.direction = self.browse.defaultDirection();
        window.showSort(self);
    }

    fn updateCountLabel(self: *App) void {
        const meta = self.tracks_meta orelse return;
        if (self.library == null) {
            gtk.gtk_label_set_text(meta, "No library");
            return;
        }
        var buffer: [96]u8 = undefined;
        const text = if (self.tracks_large)
            strings.printZ(&buffer, "{f}", .{strings.grouped(self.track_library_total orelse self.track_count)}) catch ""
        else if (self.query.value.len != 0)
            strings.printZ(&buffer, "{f} matching", .{strings.grouped(self.track_count)}) catch ""
        else if (self.track_count == 1)
            "1 track"
        else
            strings.printZ(&buffer, "{f} tracks", .{strings.grouped(self.track_count)}) catch "";
        gtk.gtk_label_set_text(meta, text.ptr);
        track_filters.showTotals(self);
    }

    /// Chooses what the Tracks page shows: the listing, a welcome for a library
    /// with nothing in it, or a note that a search found nothing.
    pub fn updateTracksBody(self: *App) void {
        const body = self.tracks_body orelse return;
        const searching = self.query.value.len != 0;
        const scoped = self.browse.artist_id != null or self.browse.release_id != null;
        if (self.track_count != 0 or scoped) {
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
        if (jobs.active(self, .scan)) {
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
        if (self.welcome_button) |button| gtk.gtk_widget_set_visible(button, if (jobs.active(self, .scan)) gtk.false_ else gtk.true_);
        if (self.welcome_spinner) |spinner| gtk.gtk_widget_set_visible(spinner, if (jobs.active(self, .scan)) gtk.true_ else gtk.false_);
    }

    fn trackListing(self: *App, offset: u32, limit: u32) liborca.BrowseTrackListing {
        var query = self.trackRequest(offset);
        query.limit = limit;
        return .{ .text = self.query.value, .query = query };
    }

    /// Asks the browse loader for one page of rows for the paged track model.
    fn requestTracks(context: *anyopaque, offset: u32, limit: u32) track_model.Requested {
        const self: *App = @ptrCast(@alignCast(context));
        const library = self.library orelse return .failed;
        const id = self.runtime.libraryRequestBrowse(library, self.io, .{ .track_page = self.trackListing(offset, limit) }) catch |err| {
            if (err == error.BrowseQueueFull) {
                self.scheduleBrowseRetry();
                return .busy;
            }
            self.noteTracksFailure();
            return .failed;
        };
        return .{ .issued = id };
    }

    fn cancelTracks(context: *anyopaque, request: u64) void {
        const self: *App = @ptrCast(@alignCast(context));
        const library = self.library orelse return;
        self.runtime.libraryCancelBrowse(library, request);
    }

    /// Toasts from the retry timer rather than here: a page is asked for
    /// while GTK lays the list out.
    fn noteTracksFailure(self: *App) void {
        if (self.tracks_failure == .none) self.tracks_failure = .unreported;
        self.scheduleBrowseRetry();
    }

    pub fn noteAlbumsFailure(self: *App) void {
        if (self.albums_failure == .none) self.albums_failure = .unreported;
        self.scheduleBrowseRetry();
    }

    pub fn scheduleBrowseRetry(self: *App) void {
        if (self.browse_retry_source == 0) self.browse_retry_source = gtk.g_timeout_add(browse_retry_ms, browseRetryFired, self);
    }

    fn browseRetryFired(data: ?*anyopaque) callconv(.c) gtk.gboolean {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.browse_retry_source = 0;
        self.retryBrowse();
        return gtk.SOURCE_REMOVE;
    }

    /// Asks again for what the browse loader was too full to take, and
    /// reports a failure once per listing.
    fn retryBrowse(self: *App) void {
        if (self.tracks_failure == .unreported or self.albums_failure == .unreported) {
            if (self.tracks_failure == .unreported) self.tracks_failure = .reported;
            if (self.albums_failure == .unreported) self.albums_failure = .reported;
            self.toast("Unable to query the library");
        }
        var waiting = albums.retryWaiting(self);
        if (self.tracks_totals == .waiting) {
            self.requestTotals();
            switch (self.tracks_totals) {
                .waiting => waiting = true,
                .idle => self.totalsFailed(),
                .pending => {},
            }
        }
        if (self.tracks.paged) |paged| {
            if (paged.retryWaiting()) waiting = true;
        }
        if (waiting) self.scheduleBrowseRetry();
    }

    /// Takes every finished browse result and hands it to what asked for
    /// it. Results nothing waits for any more are dropped.
    pub fn takeBrowseResults(self: *App) void {
        const library = self.library orelse return;
        var took = false;
        while (self.runtime.libraryTakeBrowse(library)) |result| {
            defer result.deinit();
            took = true;
            const payload = result.payload catch {
                if (self.isTotalsRequest(result.request)) {
                    self.totalsFailed();
                } else if (albums.isCountRequest(self, result.request)) {
                    albums.countFailed(self);
                } else if (albums.pageFailed(self, result.request)) {
                    self.noteAlbumsFailure();
                } else if (self.tracks.paged) |paged| {
                    if (paged.pageFailed(result.request)) self.noteTracksFailure();
                }
                continue;
            };
            switch (payload) {
                .track_page => |page| if (self.tracks.paged) |paged| {
                    const started = gtk.g_get_monotonic_time();
                    paged.pageArrived(result.request, page);
                    if (self.debug_frames) std.debug.print("orca-gtk frames: page {d} us\n", .{gtk.g_get_monotonic_time() - started});
                },
                .track_totals => |totals| if (self.isTotalsRequest(result.request)) self.totalsArrived(totals),
                .release_page => |page| albums.pageArrived(self, result.request, page),
                .release_count => |count| if (albums.isCountRequest(self, result.request)) albums.countArrived(self, count),
            }
        }
        if (took) self.retryBrowse();
    }

    fn requestTotals(self: *App) void {
        const library = self.library orelse {
            self.tracks_totals = .idle;
            return;
        };
        const id = self.runtime.libraryRequestBrowse(library, self.io, .{ .track_totals = self.trackListing(0, page_size) }) catch |err| {
            if (err == error.BrowseQueueFull) {
                self.tracks_totals = .waiting;
                self.scheduleBrowseRetry();
                return;
            }
            self.tracks_totals = .idle;
            self.noteTracksFailure();
            return;
        };
        self.tracks_totals = .{ .pending = id };
    }

    fn cancelTotals(self: *App) void {
        switch (self.tracks_totals) {
            .pending => |id| if (self.library) |library| self.runtime.libraryCancelBrowse(library, id),
            else => {},
        }
        self.tracks_totals = .idle;
    }

    fn isTotalsRequest(self: *const App, request: u64) bool {
        return switch (self.tracks_totals) {
            .pending => |id| id == request,
            else => false,
        };
    }

    fn totalsFailed(self: *App) void {
        self.tracks_totals = .idle;
        self.noteTracksFailure();
        self.track_count = 0;
        self.track_duration_ms = 0;
        if (self.tracks.paged) |paged| paged.resize(0);
        self.showListing();
    }

    fn totalsArrived(self: *App, totals: liborca.TrackTotals) void {
        const started = gtk.g_get_monotonic_time();
        self.tracks_totals = .idle;
        self.track_count = @intCast(@min(totals.count, std.math.maxInt(u32)));
        self.track_duration_ms = totals.duration_ms;
        const unfiltered = self.query.value.len == 0 and !self.track_filters.active() and
            self.browse.artist_id == null and self.browse.release_id == null;
        if (unfiltered) self.track_library_total = self.track_count;
        if (self.tracks.paged) |paged| paged.resize(self.track_count);
        self.showListing();
        if (self.debug_frames) {
            std.debug.print("orca-gtk frames: totals {d} us\n", .{gtk.g_get_monotonic_time() - started});
        }
    }

    fn showListing(self: *App) void {
        window.applyTracksForm(self);
        self.updateCountLabel();
        self.updateTracksBody();
        details.invalidate(self);
    }

    pub fn reload(self: *App) void {
        self.relist(true);
    }

    /// Lists the same tracks in the order `browse` now names, keeping the
    /// count and duration, which a sort cannot change.
    pub fn resort(self: *App) void {
        self.relist(false);
    }

    /// Asks for the listing again. The rows on screen become placeholders
    /// until their pages arrive; a recount keeps the old length, and what
    /// the page says about it, until the new totals arrive.
    fn relist(self: *App, recount: bool) void {
        const paged = self.tracks.paged orelse return;
        const started = gtk.g_get_monotonic_time();
        paged.setSource(.{ .context = self, .request = requestTracks, .cancel = cancelTracks });
        self.tracks_failure = .none;
        if (recount) {
            self.cancelTotals();
            self.requestTotals();
            if (self.tracks_totals == .idle) {
                self.track_count = 0;
                self.track_duration_ms = 0;
            }
        }
        // A scroller left deep in the previous listing would show rows far
        // below a listing that may now be short.
        if (self.scroller) |scroller| gtk.gtk_adjustment_set_value(
            gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
            0.0,
        );
        paged.reset(self.track_count);
        if (self.tracks_totals == .idle) self.showListing();
        if (self.debug_frames) {
            std.debug.print("orca-gtk frames: reload {d} us\n", .{gtk.g_get_monotonic_time() - started});
        }
    }

    pub fn deinit(self: *App) void {
        self.history.deinit();
        if (self.browse_retry_source != 0) _ = gtk.g_source_remove(self.browse_retry_source);
        if (self.equalizer_apply_timer != 0) _ = gtk.g_source_remove(self.equalizer_apply_timer);
        parametric.deinit(self);
        if (self.seek_settle_timer != 0) _ = gtk.g_source_remove(self.seek_settle_timer);
        if (self.volume_settle_timer != 0) _ = gtk.g_source_remove(self.volume_settle_timer);
        self.tracks.deinit();
        self.track_filters_ui.deinit(self.allocator);
        self.album_filters_ui.deinit(self.allocator);
        self.album_info.deinit(self.allocator);
        self.album_sections.deinit(self.allocator);
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
        self.album_search.clear(self.allocator);
        self.album_artist_name.clear(self.allocator);
        self.genres.deinit(self.allocator);
        self.folders.deinit(self.allocator);
        self.offline.deinit(self.allocator);
        self.palette.deinit(self.allocator);
        self.activity.deinit(self.allocator);
        self.changes.deinit();
        self.duplicates.deinit();
        self.matches.deinit();
        self.match_review.deinit(self.allocator);
        self.artwork_review.deinit(self.allocator);
        self.metadata_issues.deinit(self.allocator);
        self.preferred_output.clear(self.allocator);
        if (self.library_path) |path| self.allocator.free(path);
        self.libraries.deinit(self.allocator);
    }
};

fn writeWake(context: ?*anyopaque) callconv(.c) void {
    const wake_fd: *const std.os.linux.fd_t = @ptrCast(@alignCast(context.?));
    const increment: u64 = 1;
    _ = std.os.linux.write(wake_fd.*, std.mem.asBytes(&increment), @sizeOf(u64));
}

var empty_text: [0:0]u8 = .{};
