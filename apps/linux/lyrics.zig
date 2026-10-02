//! The lyrics page of the details sidebar: the audible Track's lyrics, which
//! liborca resolves on a job, followed line by line while they are synced.
//!
//! Every details panel carries a `View`; they all draw the one `State`. A
//! Track's lyrics are asked for only while a view is on screen, and a view
//! that was off screen when they arrived is drawn when it is shown.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const details = @import("details.zig");
const strings = @import("strings.zig");
const nowplaying = @import("nowplaying.zig");

const App = app.App;

const follow_interval_ms: c_uint = 100;

const Found = struct {
    outcome: liborca.LyricsOutcome,
    lyrics: ?liborca.Lyrics,
};

const Resolution = union(enum) {
    nothing_playing,
    resolving: liborca.JobHandle,
    found: Found,
    failed,
};

pub const State = struct {
    fetch: bool = false,
    track_id: ?i64 = null,
    resolution: Resolution = .nothing_playing,
    stale: bool = true,
    generation: u64 = 1,
    follow_timer: c_uint = 0,
    quote_slot: ?*gtk.Widget = null,
    quote: ?*gtk.Widget = null,
    quote_line: ?usize = null,
    /// Set at shutdown, after which widgets torn down later start nothing.
    closed: bool = false,
};

pub const View = struct {
    self: *App,
    root: *gtk.Widget,
    status: *gtk.Widget,
    scroller: *gtk.Widget,
    list: *gtk.Widget,
    plain: *gtk.Widget,
    labels: std.ArrayList(*gtk.Widget) = .empty,
    line: ?usize = null,
    generation: u64 = 0,
    margin: c_int = 0,

    /// Builds the view in place: its signals keep `view`'s address.
    pub fn init(view: *View, self: *App) void {
        const status = adw.adw_status_page_new();
        gtk.gtk_widget_add_css_class(status, "compact");

        const list = gtk.gtk_list_box_new();
        gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
        gtk.gtk_widget_add_css_class(list, "lyrics");
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, list), gtk.ACCESSIBLE_PROPERTY_LABEL, "Lyrics", @as(c_int, -1));
        const scroller = gtk.gtk_scrolled_window_new();
        gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
        gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);

        const plain = gtk.gtk_label_new("");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, plain), 0.0);
        gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, plain), gtk.true_);
        gtk.gtk_label_set_selectable(gtk.cast(gtk.Label, plain), gtk.true_);
        gtk.gtk_widget_set_valign(plain, gtk.ALIGN_START);
        gtk.gtk_widget_add_css_class(plain, "lyrics-plain");
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, plain), gtk.ACCESSIBLE_PROPERTY_LABEL, "Lyrics", @as(c_int, -1));
        const plain_scroller = gtk.gtk_scrolled_window_new();
        gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, plain_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
        gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, plain_scroller), plain);

        const root = gtk.gtk_stack_new();
        const stack = gtk.cast(gtk.Stack, root);
        _ = gtk.gtk_stack_add_named(stack, status, "status");
        _ = gtk.gtk_stack_add_named(stack, scroller, "synced");
        _ = gtk.gtk_stack_add_named(stack, plain_scroller, "plain");

        view.* = .{
            .self = self,
            .root = root,
            .status = status,
            .scroller = scroller,
            .list = list,
            .plain = plain,
        };
        const adjustment = gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
        _ = gtk.signalConnect(adjustment, "changed", gtk.callback(adjustmentChanged), view);
        _ = gtk.signalConnect(root, "map", gtk.callback(mappedChanged), view);
        _ = gtk.signalConnect(root, "unmap", gtk.callback(mappedChanged), view);
    }

    pub fn deinit(view: *View) void {
        view.labels.deinit(view.self.allocator);
    }
};

/// Shows the synced line being heard in `label` while `slot` is mapped, using
/// only lyrics a lyrics view loaded: it never starts a lookup or a fetch.
pub fn watchQuote(self: *App, slot: *gtk.Widget, label: *gtk.Widget) void {
    self.lyrics.quote_slot = slot;
    self.lyrics.quote = label;
    gtk.gtk_widget_set_visible(label, gtk.false_);
    _ = gtk.signalConnect(slot, "map", gtk.callback(quoteMappedChanged), self);
    _ = gtk.signalConnect(slot, "unmap", gtk.callback(quoteMappedChanged), self);
}

pub fn toggle(self: *App) void {
    details.showSidebar(self, if (details.shownMode(self) == .lyrics) .hidden else .lyrics);
}

pub fn setFetch(self: *App, fetch: bool) void {
    if (fetch == self.lyrics.fetch) return;
    self.lyrics.fetch = fetch;
    self.lyrics.stale = true;
    settings.save(self);
    sync(self);
}

pub fn trackChanged(self: *App) void {
    sync(self);
}

pub fn tick(self: *App) void {
    finishJob(self);
    follow(self);
}

pub fn shutdown(self: *App) void {
    self.lyrics.closed = true;
    stopFollowing(self);
    discard(self);
}

pub fn sync(self: *App) void {
    const state = &self.lyrics;
    if (state.closed) return;
    if (anyViewMapped(self) and (state.stale or !optionalEql(state.track_id, self.shown_track_id))) {
        resolve(self, self.shown_track_id);
        redraw(self);
    }
    follow(self);
}

fn resolve(self: *App, track_id: ?i64) void {
    const state = &self.lyrics;
    discard(self);
    state.stale = false;
    state.track_id = track_id;
    const id = track_id orelse return;
    const library = self.library orelse {
        state.resolution = .failed;
        return;
    };
    const job = self.runtime.startTrackLyrics(library, id, .{ .fetch = state.fetch }) catch {
        state.resolution = .failed;
        return;
    };
    state.resolution = .{ .resolving = job };
}

fn discard(self: *App) void {
    const state = &self.lyrics;
    switch (state.resolution) {
        .resolving => |job| self.runtime.cancelJob(job) catch {},
        .found => |found| if (found.lyrics) |owned| owned.deinit(),
        .nothing_playing, .failed => {},
    }
    state.resolution = .nothing_playing;
}

fn finishJob(self: *App) void {
    const state = &self.lyrics;
    const job = switch (state.resolution) {
        .resolving => |handle| handle,
        else => return,
    };
    const snapshot = self.runtime.jobSnapshotSynced(job) catch {
        state.resolution = .failed;
        redraw(self);
        return;
    };
    switch (snapshot.state) {
        .succeeded, .failed, .cancelled => {},
        else => return,
    }
    const found = self.runtime.jobTakeLyrics(job) catch null;
    const outcome = self.runtime.jobLyricsOutcome(job) catch liborca.LyricsOutcome.not_found;
    state.resolution = if (snapshot.state != .succeeded and found == null)
        .failed
    else
        .{ .found = .{ .outcome = outcome, .lyrics = found } };
    redraw(self);
}

fn redraw(self: *App) void {
    self.lyrics.generation +%= 1;
    showQuote(self, null, null);
    forEachMappedView(self, render);
}

fn forEachMappedView(self: *App, action: *const fn (*View) void) void {
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        if (gtk.gtk_widget_get_mapped(panel.lyrics.root) != 0) action(&panel.lyrics);
    }
}

fn anyViewMapped(self: *App) bool {
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        if (gtk.gtk_widget_get_mapped(panel.lyrics.root) != 0) return true;
    }
    return false;
}

fn mappedChanged(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(data.?));
    const self = view.self;
    if (self.lyrics.closed) return;
    sync(self);
    if (gtk.gtk_widget_get_mapped(view.root) != 0 and view.generation != self.lyrics.generation) {
        render(view);
        follow(self);
    }
}

fn quoteMapped(self: *const App) bool {
    const slot = self.lyrics.quote_slot orelse return false;
    return gtk.gtk_widget_get_mapped(slot) != 0;
}

fn quoteMappedChanged(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    if (self.lyrics.closed) return;
    follow(self);
}

fn showQuote(self: *App, lyrics: ?liborca.Lyrics, line: ?usize) void {
    const state = &self.lyrics;
    const quote = state.quote orelse return;
    if (lyrics != null and optionalEql(line, state.quote_line)) return;
    state.quote_line = line;
    const text = if (lyrics) |value| (if (line) |index| value.lines[index].text else "") else "";
    var buffer: [512]u8 = undefined;
    const shown = if (text.len != 0) strings.format(&buffer, "“{s}”", .{text}) else "";
    nowplaying.setUppercase(gtk.cast(gtk.Label, quote), shown);
    gtk.gtk_widget_set_visible(quote, if (shown.len != 0) gtk.true_ else gtk.false_);
}

fn adjustmentChanged(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(data.?));
    const half: c_int = @intFromFloat(gtk.gtk_adjustment_get_page_size(gtk.cast(gtk.Adjustment, adjustment)) / 2);
    if (half != view.margin) {
        view.margin = half;
        gtk.gtk_widget_set_margin_top(view.list, half);
        gtk.gtk_widget_set_margin_bottom(view.list, half);
    }
    centre(view);
}

fn syncedLyrics(self: *const App) ?liborca.Lyrics {
    const found = switch (self.lyrics.resolution) {
        .found => |value| value,
        else => return null,
    };
    const lyrics = found.lyrics orelse return null;
    return if (lyrics.kind == .synced) lyrics else null;
}

fn step(self: *App) bool {
    const lyrics = syncedLyrics(self) orelse return false;
    const quote_mapped = quoteMapped(self);
    if (!quote_mapped and !anyViewMapped(self)) return false;
    const status = self.runtime.playerStatus(self.player) catch return false;
    if (!optionalEql(status.track_id, self.lyrics.track_id)) {
        showQuote(self, null, null);
        return false;
    }
    const line = lyrics.lineAt(status.position_ms);
    if (quote_mapped) showQuote(self, lyrics, line);
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        const view = &panel.lyrics;
        if (gtk.gtk_widget_get_mapped(view.root) == 0 or view.generation != self.lyrics.generation) continue;
        highlight(view, line);
    }
    return status.transport == .playing;
}

fn follow(self: *App) void {
    const state = &self.lyrics;
    if (state.closed) return;
    const wanted = step(self);
    if (wanted and state.follow_timer == 0) {
        state.follow_timer = gtk.g_timeout_add(follow_interval_ms, followFired, self);
    } else if (!wanted) {
        stopFollowing(self);
    }
}

fn stopFollowing(self: *App) void {
    const state = &self.lyrics;
    if (state.follow_timer == 0) return;
    _ = gtk.g_source_remove(state.follow_timer);
    state.follow_timer = 0;
}

fn followFired(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self: *App = @ptrCast(@alignCast(data.?));
    if (step(self)) return gtk.SOURCE_CONTINUE;
    self.lyrics.follow_timer = 0;
    return gtk.SOURCE_REMOVE;
}

fn render(view: *View) void {
    const self = view.self;
    const state = &self.lyrics;
    view.generation = state.generation;
    switch (state.resolution) {
        .nothing_playing => showStatus(view, "audio-x-generic-symbolic", "Nothing Playing", "Lyrics follow the song that is playing."),
        .resolving => showStatus(view, null, "Looking for Lyrics…", null),
        .failed => showStatus(view, "dialog-warning-symbolic", "Lyrics Could Not Be Read", null),
        .found => |found| if (found.lyrics) |lyrics| switch (lyrics.kind) {
            .synced => showSynced(view, lyrics),
            .plain => showPlain(view, lyrics),
            .instrumental => showStatus(view, "media-view-subtitles-symbolic", "Instrumental", null),
        } else showMissing(view, found.outcome),
    }
}

fn showMissing(view: *View, outcome: liborca.LyricsOutcome) void {
    switch (outcome) {
        .unavailable, .busy => showStatus(view, "network-offline-symbolic", "Couldn't Reach LRCLIB", "Try again later."),
        .refused => showStatus(view, "network-offline-symbolic", "Couldn't Use LRCLIB's Answer", "Try again later."),
        .no_metadata => showStatus(view, "media-view-subtitles-symbolic", "No Lyrics", "LRCLIB needs a title and an artist to look lyrics up."),
        else => showStatus(
            view,
            "media-view-subtitles-symbolic",
            "No Lyrics",
            if (view.self.lyrics.fetch) null else "Lyrics can be fetched from LRCLIB in Settings.",
        ),
    }
}

fn showStatus(view: *View, icon: ?[*:0]const u8, title: [*:0]const u8, description: ?[*:0]const u8) void {
    const page = gtk.cast(adw.StatusPage, view.status);
    adw.adw_status_page_set_icon_name(page, icon);
    adw.adw_status_page_set_title(page, title);
    adw.adw_status_page_set_description(page, description);
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, view.root), "status");
}

fn showSynced(view: *View, lyrics: liborca.Lyrics) void {
    const allocator = view.self.allocator;
    const list = gtk.cast(gtk.ListBox, view.list);
    gtk.gtk_list_box_remove_all(list);
    view.labels.clearRetainingCapacity();
    view.line = null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (lyrics.lines) |line| {
        view.labels.ensureUnusedCapacity(allocator, 1) catch break;
        text.clearRetainingCapacity();
        text.appendSlice(allocator, if (line.text.len != 0) line.text else "♪") catch break;
        text.append(allocator, 0) catch break;
        const label = gtk.gtk_label_new(@ptrCast(text.items.ptr));
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
        gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, label), gtk.true_);
        gtk.gtk_widget_add_css_class(label, "lyrics-line");
        const row = gtk.gtk_list_box_row_new();
        gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), label);
        gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, row), gtk.false_);
        gtk.gtk_list_box_append(list, row);
        view.labels.appendAssumeCapacity(label);
    }
    gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, view.scroller)), 0.0);
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, view.root), "synced");
}

fn showPlain(view: *View, lyrics: liborca.Lyrics) void {
    const allocator = view.self.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (lyrics.lines, 0..) |line, index| {
        if (index != 0) text.append(allocator, '\n') catch break;
        text.appendSlice(allocator, line.text) catch break;
    }
    text.append(allocator, 0) catch return showStatus(view, "dialog-warning-symbolic", "Lyrics Could Not Be Shown", null);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, view.plain), @ptrCast(text.items.ptr));
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, view.root), "plain");
}

fn highlight(view: *View, line: ?usize) void {
    if (optionalEql(line, view.line)) return;
    view.line = line;
    for (view.labels.items, 0..) |label, index| {
        const reached = line orelse {
            gtk.gtk_widget_remove_css_class(label, "lyrics-current");
            gtk.gtk_widget_remove_css_class(label, "dim-label");
            continue;
        };
        setClass(label, "lyrics-current", index == reached);
        setClass(label, "dim-label", index < reached);
    }
    centre(view);
}

fn centre(view: *View) void {
    const index = view.line orelse return;
    if (index >= view.labels.items.len) return;
    var bounds: gtk.Rect = .{};
    if (gtk.gtk_widget_compute_bounds(view.labels.items[index], view.scroller, &bounds) == 0) return;
    const adjustment = gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, view.scroller));
    const page = gtk.gtk_adjustment_get_page_size(adjustment);
    const middle: f64 = bounds.y + bounds.height / 2;
    gtk.gtk_adjustment_set_value(adjustment, gtk.gtk_adjustment_get_value(adjustment) + middle - page / 2);
}

fn setClass(widget: *gtk.Widget, name: [*:0]const u8, on: bool) void {
    if (on) gtk.gtk_widget_add_css_class(widget, name) else gtk.gtk_widget_remove_css_class(widget, name);
}

fn optionalEql(a: anytype, b: @TypeOf(a)) bool {
    if (a) |left| return left == (b orelse return false);
    return b == null;
}
