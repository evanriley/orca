//! The Artist and Release panes, and the navigation between them.
//!
//! Two stacked lists beside the track list — the browser every desktop music
//! player has had since iTunes, and the shape that needs no navigation state of
//! its own: an Artist selection scopes the Release pane, a Release selection
//! scopes the track list, and the "All" row at the top of each pane is the way
//! back out. There is no history, no breadcrumb and no back button to keep in
//! step with the listing, because the two selections *are* the position.
//!
//! Every pane pages exactly like the track list does, for the same reason: 2,468
//! Artists and 2,637 Releases do not fit in liborca's 512-row bound, and a
//! frontend that asked for them all at once would be inventing its own paging.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const browse_model = @import("browse_model.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

// ------------------------------------------------------------------- rows

fn setupRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    const name = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    const detail = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, detail), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, detail), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(detail, "dim-label");
    gtk.gtk_widget_add_css_class(detail, "caption");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), detail);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), row);
}

fn bindRow(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const object = gtk.gtk_list_item_get_item(list_item) orelse return;
    const row: *BrowseObject = @ptrCast(@alignCast(object));
    const child = gtk.gtk_list_item_get_child(list_item) orelse return;
    const name = gtk.gtk_widget_get_first_child(child) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, name), row.name().ptr);
    const detail = gtk.gtk_widget_get_next_sibling(name) orelse return;
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, detail), row.detail().ptr);
    gtk.gtk_widget_set_visible(detail, if (row.detail().len == 0) gtk.false_ else gtk.true_);
}

fn append(store: *gtk.ListStore, id: ?i64, name: []const u8, detail: []const u8) void {
    const row = browse_model.new(id, name, detail) orelse return;
    var addition: [1]?*anyopaque = .{row};
    gtk.g_list_store_splice(
        store,
        gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
        0,
        &addition,
        1,
    );
    gtk.g_object_unref(row);
}

// ---------------------------------------------------------------- artists

pub fn reloadArtists(self: *App) void {
    const store = self.artists orelse return;
    const previous = self.suppress_browse_signals;
    self.suppress_browse_signals = true;
    defer self.suppress_browse_signals = previous;

    gtk.g_list_store_remove_all(store);
    self.artists_loaded = 0;
    self.artists_exhausted = false;
    append(store, null, "All Artists", "");
    const library = self.library orelse {
        self.artists_exhausted = true;
        return;
    };
    const total = self.runtime.libraryArtistCount(library) catch 0;
    if (self.artist_header) |header| {
        var buffer: [64]u8 = undefined;
        const text = strings.printZ(&buffer, "Artists — {d}", .{total}) catch "Artists";
        gtk.gtk_label_set_text(header, text.ptr);
    }
    loadNextArtistPage(self);
    if (self.artist_selection) |selection| gtk.gtk_single_selection_set_selected(selection, 0);
}

pub fn loadNextArtistPage(self: *App) void {
    const store = self.artists orelse return;
    if (self.artists_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryArtistPage(library, .{
        .limit = app.page_size,
        .offset = self.artists_loaded,
    }) catch {
        self.artists_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.artists_exhausted = true;
    var buffer: [96]u8 = undefined;
    for (page.items) |artist| {
        const detail = strings.printZ(&buffer, "{d} releases · {d} tracks", .{
            artist.release_count,
            artist.track_count,
        }) catch "";
        append(store, artist.id, artist.name, detail);
    }
    self.artists_loaded += @intCast(page.items.len);
}

// ---------------------------------------------------------------- releases

pub fn reloadReleases(self: *App) void {
    const store = self.releases orelse return;
    const previous = self.suppress_browse_signals;
    self.suppress_browse_signals = true;
    defer self.suppress_browse_signals = previous;

    gtk.g_list_store_remove_all(store);
    self.releases_loaded = 0;
    self.releases_exhausted = false;
    append(store, null, "All Releases", "");
    if (self.library == null) self.releases_exhausted = true;
    loadNextReleasePage(self);
    if (self.release_selection) |selection| gtk.gtk_single_selection_set_selected(selection, 0);
}

pub fn loadNextReleasePage(self: *App) void {
    const store = self.releases orelse return;
    if (self.releases_exhausted) return;
    const library = self.library orelse return;
    var page = self.runtime.libraryReleasePage(library, .{
        .album_artist_id = self.browse.artist_id,
        .limit = app.page_size,
        .offset = self.releases_loaded,
    }) catch {
        self.releases_exhausted = true;
        return;
    };
    defer page.deinit();
    if (page.items.len < app.page_size) self.releases_exhausted = true;
    var buffer: [256]u8 = undefined;
    for (page.items) |release| {
        const discs = release.disc_count orelse 1;
        const detail = if (discs > 1)
            strings.printZ(&buffer, "{s} · {d} tracks · {d} discs", .{
                release.album_artist,
                release.track_count,
                discs,
            }) catch ""
        else
            strings.printZ(&buffer, "{s} · {d} tracks", .{
                release.album_artist,
                release.track_count,
            }) catch "";
        append(store, release.id, release.title, detail);
    }
    self.releases_loaded += @intCast(page.items.len);
}

// -------------------------------------------------------------- navigation

fn selectedRow(selection: ?*gtk.SingleSelection) ?*BrowseObject {
    const model = selection orelse return null;
    const position = gtk.gtk_single_selection_get_selected(model);
    if (position == gtk.INVALID_LIST_POSITION) return null;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, model), position) orelse
        return null;
    defer gtk.g_object_unref(item);
    return @ptrCast(@alignCast(item));
}

/// A search and a browse scope are alternatives — liborca refuses to combine a
/// full-text match with a relational filter — so entering one leaves the other.
fn clearSearch(self: *App) void {
    if (self.query.len == 0) return;
    self.setQuery("");
    const entry = self.search_entry orelse return;
    const previous = self.suppress_browse_signals;
    self.suppress_browse_signals = true;
    defer self.suppress_browse_signals = previous;
    gtk.gtk_editable_set_text(entry, "");
}

/// Returns the panes to "All", for a search that has just taken over the
/// listing. Does not reload: the caller is mid-reload already.
pub fn clearScope(self: *App) void {
    const previous = self.suppress_browse_signals;
    self.suppress_browse_signals = true;
    defer self.suppress_browse_signals = previous;
    self.browse.artist_id = null;
    self.browse.release_id = null;
    if (self.artist_selection) |selection| gtk.gtk_single_selection_set_selected(selection, 0);
    reloadReleases(self);
    if (self.release_header) |header| gtk.gtk_label_set_text(header, "Releases");
}

/// Repopulates both panes and returns the listing to the whole library, for
/// when the shelves themselves have changed: a library opening, or a scan
/// finishing. The caller reloads the track list.
pub fn reload(self: *App) void {
    self.browse.artist_id = null;
    self.browse.release_id = null;
    if (self.release_header) |header| gtk.gtk_label_set_text(header, "Releases");
    reloadArtists(self);
    reloadReleases(self);
    self.applyScopeDefaultSort();
}

fn artistSelected(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_browse_signals) return;
    const row = selectedRow(self.artist_selection) orelse return;
    self.browse.artist_id = row.id();
    self.browse.release_id = null;
    if (self.release_header) |header| {
        var buffer: [160]u8 = undefined;
        const text = if (row.id() == null)
            "Releases"
        else
            strings.printZ(&buffer, "Releases — {s}", .{row.name()}) catch "Releases";
        gtk.gtk_label_set_text(header, text.ptr);
    }
    clearSearch(self);
    reloadReleases(self);
    self.applyScopeDefaultSort();
    self.reload();
}

fn releaseSelected(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.suppress_browse_signals) return;
    const row = selectedRow(self.release_selection) orelse return;
    self.browse.release_id = row.id();
    clearSearch(self);
    self.applyScopeDefaultSort();
    self.reload();
}

// ------------------------------------------------------------------ panes

fn artistsScrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.artists_exhausted) return;
    if (nearEnd(adjustment)) loadNextArtistPage(self);
}

fn releasesScrolled(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.releases_exhausted) return;
    if (nearEnd(adjustment)) loadNextReleasePage(self);
}

fn nearEnd(adjustment: ?*anyopaque) bool {
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) -
        (gtk.gtk_adjustment_get_value(value) + page);
    return remaining < page;
}

const Pane = struct {
    widget: *gtk.Widget,
    store: *gtk.ListStore,
    selection: *gtk.SingleSelection,
    header: *gtk.Label,
};

fn buildPane(
    self: *App,
    title: [*:0]const u8,
    on_selection: gtk.GCallback,
    on_scroll: gtk.GCallback,
) Pane {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    const selection = gtk.gtk_single_selection_new(
        gtk.cast(gtk.ListModel, gtk.g_object_ref(store)),
    );
    _ = gtk.signalConnect(selection, "notify::selected", on_selection, self);

    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupRow), null);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindRow), null);
    const list = gtk.gtk_list_view_new(gtk.cast(gtk.SelectionModel, selection), factory);

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        on_scroll,
        self,
    );

    const header = gtk.gtk_label_new(title);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, header), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, header), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(header, "heading");
    gtk.gtk_widget_set_margin_start(header, 8);
    gtk.gtk_widget_set_margin_top(header, 6);
    gtk.gtk_widget_set_margin_bottom(header, 2);

    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), scroller);
    return .{
        .widget = box,
        .store = store,
        .selection = selection,
        .header = gtk.cast(gtk.Label, header),
    };
}

/// The browser: Artists above Releases, in a pane the user can resize.
pub fn build(self: *App) *gtk.Widget {
    const artists = buildPane(
        self,
        "Artists",
        gtk.callback(artistSelected),
        gtk.callback(artistsScrolled),
    );
    self.artists = artists.store;
    self.artist_selection = artists.selection;
    self.artist_header = artists.header;

    const releases = buildPane(
        self,
        "Releases",
        gtk.callback(releaseSelected),
        gtk.callback(releasesScrolled),
    );
    self.releases = releases.store;
    self.release_selection = releases.selection;
    self.release_header = releases.header;

    const split = gtk.gtk_paned_new(gtk.ORIENTATION_VERTICAL);
    gtk.gtk_paned_set_start_child(gtk.cast(gtk.Paned, split), artists.widget);
    gtk.gtk_paned_set_end_child(gtk.cast(gtk.Paned, split), releases.widget);
    gtk.gtk_paned_set_position(gtk.cast(gtk.Paned, split), 360);
    gtk.gtk_paned_set_resize_start_child(gtk.cast(gtk.Paned, split), gtk.true_);
    gtk.gtk_paned_set_shrink_start_child(gtk.cast(gtk.Paned, split), gtk.false_);
    gtk.gtk_paned_set_shrink_end_child(gtk.cast(gtk.Paned, split), gtk.false_);
    return split;
}
