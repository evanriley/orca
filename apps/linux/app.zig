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
const window = @import("window.zig");
const albums = @import("albums.zig");
const details = @import("details.zig");

/// The list is filled a page at a time as the user scrolls, so a large
/// library stays virtualized.
pub const page_size: u32 = 512;
pub const page_history_depth = 16;
pub const open_album_page_limit = 32;

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

/// The widgets of Preferences' Sound page that its handlers reach back to.
/// Reset when the dialog closes, since GTK destroys them with it.
pub const SoundControls = struct {
    preset_row: ?*gtk.Widget = null,
    preset_names: ?*gtk.StringList = null,
    bands: ?*gtk.Widget = null,
    band_scales: [equalizer_band_count]?*gtk.Widget = @splat(null),
    preamp_row: ?*gtk.Widget = null,
    crossfeed_amount_row: ?*gtk.Widget = null,
};

pub const CredentialControls = struct {
    entry_row: ?*gtk.Widget = null,
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
    /// The Track whose own search last found nothing, so its details say so.
    unmatched_track: ?i64 = null,
    /// Tracks the running matching job had matched when the badge was last
    /// counted.
    shown_matched: u64 = 0,
    /// The output device chosen in Preferences, by name, so the choice
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

    tracks: ?*gtk.ListStore = null,
    selection: ?*gtk.SelectionModel = null,
    column_view: ?*gtk.ColumnView = null,
    scroller: ?*gtk.Widget = null,
    query: OwnedText = .{},
    loaded_rows: u32 = 0,
    page_exhausted: bool = false,
    track_total: u64 = 0,
    browse: Browse = .{},
    /// The header widgets, in `track_model.Column.all` order, so the column a
    /// header click reports can be turned back into a sort key.
    sort_columns: [track_model.Column.all.len]?*gtk.ColumnViewColumn = @splat(null),

    artists: ?*gtk.ListStore = null,
    artist_selection: ?*gtk.SingleSelection = null,
    artists_loaded: u32 = 0,
    artists_exhausted: bool = false,
    releases: ?*gtk.ListStore = null,
    release_selection: ?*gtk.SingleSelection = null,
    releases_loaded: u32 = 0,
    releases_exhausted: bool = false,
    search_entry: ?*gtk.Editable = null,
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
    sidebar: ?*adw.Sidebar = null,
    pages: ?*gtk.Stack = null,
    current_page: window.Page = .albums,
    page_history: [page_history_depth]window.Page = undefined,
    page_history_len: usize = 0,
    tracks_title: ?*adw.WindowTitle = null,
    /// The Tracks page's body: the browser and list, or a status page when
    /// there is nothing to list.
    tracks_body: ?*gtk.Stack = null,
    welcome: ?*adw.StatusPage = null,
    welcome_button: ?*gtk.Widget = null,
    welcome_spinner: ?*gtk.Widget = null,
    browse_panes: ?*gtk.Widget = null,
    browse_toggle: ?*gtk.Widget = null,

    /// The one on/off choice the details panels share, restored from settings.
    details_visible: bool = false,
    /// Set while the window is below the breakpoint that hides the panels.
    window_narrow: bool = false,
    details_panels: [details.panel_limit]?*details.Panel = @splat(null),
    seen_recorded_listens: u64 = 0,

    album_store: ?*gtk.ListStore = null,
    albums_loaded: u32 = 0,
    albums_exhausted: bool = false,
    albums_title: ?*adw.WindowTitle = null,
    albums_body: ?*gtk.Stack = null,
    albums_navigation: ?*adw.NavigationView = null,
    album_sort: liborca.ReleaseSort = .artist,
    open_album_pages: [open_album_page_limit]*albums.AlbumPage = undefined,
    open_album_page_count: usize = 0,

    now_cover: ?*gtk.Widget = null,
    now_title: ?*gtk.Label = null,
    now_artist: ?*gtk.Label = null,
    now_album: ?*gtk.Label = null,
    now_up_next: ?*gtk.ListBox = null,
    now_up_next_heading: ?*gtk.Widget = null,
    tint_provider: ?*gtk.CssProvider = null,

    art: art.Cache = .{},
    /// What the open right-click menu acts on.
    context: menu.Context = .{},

    health_list: ?*gtk.ListBox = null,
    health_note: ?*gtk.Label = null,
    health_body: ?*gtk.Stack = null,
    health_title: ?*adw.WindowTitle = null,
    health_count: ?*gtk.Label = null,

    matches_list: ?*gtk.ListBox = null,
    matches_note: ?*gtk.Label = null,
    matches_body: ?*gtk.Stack = null,
    matches_title: ?*adw.WindowTitle = null,
    matches_count: ?*gtk.Label = null,
    matches_empty: ?*adw.StatusPage = null,
    matches_empty_button: ?*gtk.Widget = null,
    matches_accept_button: ?*gtk.Widget = null,
    matches_submit_button: ?*gtk.Widget = null,
    /// The Track whose row is open, kept open across reloads.
    matches_open_track: ?i64 = null,
    /// The open row, focused once laid out so the list scrolls to it.
    matches_focus_row: ?*gtk.Widget = null,
    /// Accept Confident takes a song's only match at or above this.
    match_threshold_percent: u8 = default_match_threshold_percent,
    match_fingerprints: bool = true,
    acoustid_key_stored: bool = false,
    acoustid_controls: CredentialControls = .{},

    preferences_dialog: ?*adw.Dialog = null,

    watch_folders: bool = true,
    watch_row: ?*gtk.Widget = null,
    watch_status_text: [320]u8 = undefined,
    watch_status_len: usize = 0,

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

    artist_list_store: ?*gtk.ListStore = null,
    artist_list_loaded: u32 = 0,
    artist_list_exhausted: bool = false,
    artist_list_filter: OwnedText = .{},
    artist_list_title: ?*adw.WindowTitle = null,
    artist_list_search: ?*gtk.Widget = null,
    artists_navigation: ?*adw.NavigationView = null,

    scan_revealer: ?*gtk.Revealer = null,
    scan_label: ?*gtk.Label = null,
    scan_detail: ?*gtk.Label = null,

    previous_button: ?*gtk.Widget = null,
    play_button: ?*gtk.Widget = null,
    next_button: ?*gtk.Widget = null,
    seek_scale: ?*gtk.Scale = null,
    seek_adjustment: ?*gtk.Adjustment = null,
    elapsed_label: ?*gtk.Label = null,
    total_label: ?*gtk.Label = null,
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
    volume_button: ?*gtk.Widget = null,
    shuffle_button: ?*gtk.Widget = null,
    repeat_button: ?*gtk.Widget = null,
    device_list: ?*gtk.ListBox = null,
    device_popover: ?*gtk.Popover = null,
    signal_path_label: ?*gtk.Label = null,
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
    shown_recording_id: ?i64 = null,
    shown_feedback: liborca.Feedback = .none,
    shown_transport: liborca.TransportState = .stopped,
    repeat_mode: liborca.RepeatMode = .off,

    queue_store: ?*gtk.ListStore = null,
    queue_title: ?*adw.WindowTitle = null,
    queue_body: ?*gtk.Stack = null,
    queue_count: ?*gtk.Label = null,
    /// What the queue page last showed, so it is rebuilt only when the queue
    /// or its position actually moved.
    shown_queue_length: u32 = std.math.maxInt(u32),
    shown_queue_index: u32 = std.math.maxInt(u32),
    queue_visible: bool = false,

    mpris: mpris.Mpris = .{},

    pub fn requestTick(self: *App) void {
        writeWake(&self.wake_fd);
    }

    pub fn waker(self: *App) liborca.HostWaker {
        return .{ .context = &self.wake_fd, .wake_fn = writeWake };
    }

    pub fn toast(self: *App, message: [:0]const u8) void {
        const overlay = self.toasts orelse return;
        const item = adw.adw_toast_new(message.ptr);
        adw.adw_toast_set_timeout(item, 3);
        adw.adw_toast_overlay_add_toast(overlay, item);
    }

    /// The one place the track listing is described to liborca.
    ///
    /// A full-text search and a relational filter are alternatives to the
    /// engine, not a combination, and asking for both is refused rather than
    /// half-honoured. Searching therefore leaves the scope out: the panes are
    /// reset to "All" when a search starts, and this keeps that true even if a
    /// caller forgets.
    ///
    /// The Artist pane's filter is *not* part of this. It narrows which Artists
    /// are listed and never reaches a `TrackQuery`, so it and a track search are
    /// free to hold text at the same time without either one being half applied.
    pub fn trackRequest(self: *App, offset: u32) liborca.TrackQuery {
        const searching = self.query.value.len != 0;
        return .{
            .artist_id = if (searching) null else self.browse.artist_id,
            .release_id = if (searching) null else self.browse.release_id,
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
        const view = self.column_view orelse return;
        var chosen: ?*gtk.ColumnViewColumn = null;
        for (track_model.Column.all, self.sort_columns) |column, header| {
            if (column.sortKey() == self.browse.sort) chosen = header;
        }
        // Sorting the view is indistinguishable from a header click to GTK, and
        // its "changed" signal would arrive back here as one.
        const previous = self.suppress_browse_signals;
        self.suppress_browse_signals = true;
        defer self.suppress_browse_signals = previous;
        gtk.gtk_column_view_sort_by_column(view, chosen, gtk.SORT_ASCENDING);
    }

    fn updateCountLabel(self: *App) void {
        const title = self.tracks_title orelse return;
        if (self.library == null) {
            adw.adw_window_title_set_subtitle(title, "No library");
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
        adw.adw_window_title_set_subtitle(title, text.ptr);
    }

    /// Chooses what the Tracks page shows: the listing, a welcome for a library
    /// with nothing in it, or a note that a search found nothing.
    pub fn updateTracksBody(self: *App) void {
        const body = self.tracks_body orelse return;
        const searching = self.query.value.len != 0;
        const scoped = self.browse.artist_id != null or self.browse.release_id != null;
        if (self.loaded_rows != 0 or scoped) {
            gtk.gtk_stack_set_visible_child_name(body, "list");
        } else if (searching) {
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
        const store = self.tracks orelse return;
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
        const store = self.tracks orelse return;
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
        if (self.equalizer_apply_timer != 0) _ = gtk.g_source_remove(self.equalizer_apply_timer);
        if (self.seek_settle_timer != 0) _ = gtk.g_source_remove(self.seek_settle_timer);
        self.query.clear(self.allocator);
        self.artist_filter.clear(self.allocator);
        self.artist_scope_name.clear(self.allocator);
        self.device_ids.deinit(self.allocator);
        self.device_checks.deinit(self.allocator);
        for (self.device_names.items) |name| self.allocator.free(name);
        self.device_names.deinit(self.allocator);
        self.art.deinit(self.allocator);
        self.context.deinit(self.allocator);
        self.artist_list_filter.clear(self.allocator);
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
