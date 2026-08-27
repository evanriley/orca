//! Shared frontend state and the library paging that fills the track list.
//!
//! Threading: every liborca call in this application happens on the GTK main
//! thread, from a signal handler or the `g_timeout_add` tick. There is no worker
//! thread here and there must not be one — the runtime is genuinely
//! multithreaded behind the control lane, and its object pools take no lock.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const mpris = @import("mpris.zig");
const track_model = @import("track_model.zig");

/// One page. The list is filled a page at a time as the user scrolls rather
/// than all at once, so a 22,060-track library stays virtualized.
pub const page_size: u32 = 512;
/// One tick drives everything: pump, event drain, transport, scan.
pub const tick_ms: c_uint = 100;

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
    sort: liborca.database.TrackSort = .id,
    direction: liborca.database.SortDirection = .ascending,

    /// The order a newly entered scope is listed in. An album is listened to in
    /// disc-then-track order, an artist's shelf reads album by album, and an
    /// unscoped library has no natural order to claim, so it pays for none.
    pub fn defaultSort(self: Browse) liborca.database.TrackSort {
        if (self.release_id != null) return .track_number;
        if (self.artist_id != null) return .album;
        return .id;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *liborca.OrcaRuntime,

    /// Optionals rather than `has_*` flags: an absent Library is `null`, and
    /// there is no second field to keep in step with it.
    library: ?liborca.core.LibraryHandle = null,
    player: liborca.core.PlayerHandle = undefined,
    zone: ?liborca.core.ZoneHandle = null,
    scan_job: ?liborca.core.JobHandle = null,
    scanning: bool = false,
    library_path: ?[:0]u8 = null,
    /// Correlates the last `play_track` submission with its completion event, so
    /// a refused play reports why instead of silently doing nothing.
    pending_play_request: u64 = 0,

    // library list
    tracks: ?*gtk.ListStore = null,
    selection: ?*gtk.SelectionModel = null,
    column_view: ?*gtk.ColumnView = null,
    scroller: ?*gtk.Widget = null,
    query: [:0]u8 = &empty_query,
    loaded_rows: u32 = 0,
    page_exhausted: bool = false,
    track_total: u64 = 0,
    browse: Browse = .{},
    /// The header widgets, in `track_model.Column.all` order, so the column a
    /// header click reports can be turned back into a sort key.
    sort_columns: [track_model.Column.all.len]?*gtk.ColumnViewColumn = @splat(null),

    // browse panes
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
    /// Set while a widget is being brought back in line with state that has
    /// already changed. Its "changed" signal still fires, and without this it
    /// would re-enter as though the user had done it.
    suppress_browse_signals: bool = false,

    // chrome
    application: ?*gtk.Application = null,
    window: ?*gtk.Window = null,
    count_label: ?*gtk.Label = null,
    status_label: ?*gtk.Label = null,

    // scan bar
    scan_bar: ?*gtk.Widget = null,
    scan_progress: ?*gtk.ProgressBar = null,
    scan_label: ?*gtk.Label = null,

    // transport
    previous_button: ?*gtk.Widget = null,
    play_button: ?*gtk.Widget = null,
    next_button: ?*gtk.Widget = null,
    seek_scale: ?*gtk.Scale = null,
    seek_adjustment: ?*gtk.Adjustment = null,
    elapsed_label: ?*gtk.Label = null,
    total_label: ?*gtk.Label = null,
    now_playing_title: ?*gtk.Label = null,
    now_playing_detail: ?*gtk.Label = null,
    volume_button: ?*gtk.Widget = null,
    device_drop_down: ?*gtk.DropDown = null,
    device_names: ?*gtk.StringList = null,
    device_ids: std.ArrayList(u64) = .empty,
    /// A drag in flight: the tick stops writing the slider, and the seek is
    /// applied once the value settles.
    seeking: bool = false,
    seek_pending_ms: i64 = 0,
    seek_changed_at_us: i64 = 0,
    suppress_widget_writeback: bool = false,
    last_seen_duration_ms: u64 = 0,
    /// What the now-playing labels currently show, so the resolve query only
    /// runs when the audible entry actually changes.
    shown_track_id: ?i64 = null,
    shown_transport: liborca.audio.player.TransportState = .stopped,
    repeat_mode: liborca.core.runtime.RepeatMode = .off,

    // queue popover
    queue_rows: ?*gtk.StringList = null,
    queue_popover: ?*gtk.Widget = null,

    mpris: mpris.Mpris = .{},

    pub fn setStatus(self: *App, message: [:0]const u8) void {
        const label = self.status_label orelse return;
        gtk.gtk_label_set_text(label, message.ptr);
    }

    /// Resolves a Track id to a title using rows already loaded, or null. The
    /// returned string is owned by the row and is valid only while that row
    /// remains in the model.
    pub fn knownTitle(self: *App, track_id: i64) ?[:0]const u8 {
        const store = self.tracks orelse return null;
        const model = gtk.cast(gtk.ListModel, store);
        const count = gtk.g_list_model_get_n_items(model);
        var index: c_uint = 0;
        while (index < count) : (index += 1) {
            const item = gtk.g_list_model_get_item(model, index) orelse continue;
            const row: *track_model.TrackObject = @ptrCast(@alignCast(item));
            const found = row.id() == track_id;
            const text = row.title();
            gtk.g_object_unref(item);
            if (found) return text;
        }
        return null;
    }

    /// The one place the track listing is described to liborca.
    ///
    /// A full-text search and a relational filter are alternatives to the
    /// engine, not a combination, and asking for both is refused rather than
    /// half-honoured. Searching therefore leaves the scope out: the panes are
    /// reset to "All" when a search starts, and this keeps that true even if a
    /// caller forgets.
    pub fn trackRequest(self: *App, offset: u32) liborca.database.TrackQuery {
        const searching = self.query.len != 0;
        return .{
            .artist_id = if (searching) null else self.browse.artist_id,
            .release_id = if (searching) null else self.browse.release_id,
            .sort = self.browse.sort,
            .direction = self.browse.direction,
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
        const label = self.count_label orelse return;
        if (self.library == null) {
            gtk.gtk_label_set_text(label, "No library");
            return;
        }
        var buffer: [96]u8 = undefined;
        const text = if (self.query.len != 0)
            strings.printZ(&buffer, "{d} matching", .{self.loaded_rows}) catch "…"
        else
            strings.printZ(&buffer, "{d} of {d} tracks", .{
                self.loaded_rows,
                self.track_total,
            }) catch "…";
        gtk.gtk_label_set_text(label, text.ptr);
    }

    /// Fetches exactly one bounded page and appends it. The page is caller-owned
    /// and released here; the rows copy everything they keep.
    pub fn loadNextPage(self: *App) void {
        const library = self.library orelse return;
        if (self.page_exhausted) return;
        const store = self.tracks orelse return;
        var page = self.runtime.libraryTrackQuery(
            library,
            self.query,
            self.trackRequest(self.loaded_rows),
        ) catch {
            self.page_exhausted = true;
            self.setStatus("Unable to query the library");
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
            self.setStatus("Out of memory building the track list");
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
            self.setStatus("Add a music folder to begin");
            return;
        };
        // A full-text match has no cheap total — FTS5 ranks rather than counts —
        // so a search reports what it has loaded and nothing it has not.
        self.track_total = if (self.query.len != 0)
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
        if (self.loaded_rows != 0) {
            self.setStatus("Ready");
        } else if (self.query.len != 0) {
            self.setStatus("No tracks match that search");
        } else if (self.browse.artist_id != null or self.browse.release_id != null) {
            self.setStatus("Nothing on this shelf has a track");
        } else {
            self.setStatus("Library is empty - add a music folder");
        }
    }

    pub fn setQuery(self: *App, text: []const u8) void {
        if (text.len == 0) {
            self.freeQuery();
            return;
        }
        const replacement = self.allocator.dupeSentinel(u8, text, 0) catch return;
        self.freeQuery();
        self.query = replacement;
    }

    fn freeQuery(self: *App) void {
        if (self.query.len != 0) self.allocator.free(self.query);
        self.query = &empty_query;
    }

    pub fn deinit(self: *App) void {
        self.freeQuery();
        self.device_ids.deinit(self.allocator);
        if (self.library_path) |path| self.allocator.free(path);
    }
};

var empty_query: [0:0]u8 = .{};
