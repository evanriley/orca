//! The audible Track's lyrics, which liborca resolves on a job, followed line
//! by line while they are synced: in the details sidebar, in the Now Playing
//! page's panel and in its three-line quote.
//!
//! Every details panel carries a `View`, as does the Now Playing page; they
//! all draw the one `State`, as does the quote. A Track's lyrics are asked
//! for only while a view or the quote is on screen, and a view that was off
//! screen when they arrived is drawn when it is shown.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const details = @import("details.zig");
const strings = @import("strings.zig");

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
    quote_lines: [3]?*gtk.Widget = @splat(null),
    quote_line: ?usize = null,
    quote_drawn: bool = false,
    page_view: ?*View = null,
    /// Set at shutdown, after which widgets torn down later start nothing.
    closed: bool = false,
};

/// Where a `View` sits. The Now Playing panel's lines seek when clicked,
/// stay a third of the way down while they scroll, and are followed by a
/// footer that names their source and offset.
pub const Placement = enum { details, now_playing };

pub const View = struct {
    self: *App,
    placement: Placement,
    root: *gtk.Widget,
    stack: *gtk.Widget,
    status: *gtk.Widget,
    scroller: *gtk.Widget,
    list: *gtk.Widget,
    plain: *gtk.Widget,
    footer: ?*gtk.Widget = null,
    footer_source: ?*gtk.Label = null,
    footer_offset: ?*gtk.Label = null,
    labels: std.ArrayList(*gtk.Widget) = .empty,
    line: ?usize = null,
    generation: u64 = 0,
    margin: c_int = 0,
    margin_idle: c_uint = 0,

    /// Builds the view in place: its signals keep `view`'s address.
    pub fn init(view: *View, self: *App) void {
        build(view, self, .details);
    }

    /// Builds the Now Playing panel's view in place and draws it from now on.
    pub fn initNowPlaying(view: *View, self: *App) void {
        build(view, self, .now_playing);
        self.lyrics.page_view = view;
    }

    fn build(view: *View, self: *App, placement: Placement) void {
        const status = adw.adw_status_page_new();
        gtk.gtk_widget_add_css_class(status, "compact");

        const list = gtk.gtk_list_box_new();
        gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
        gtk.gtk_widget_add_css_class(list, "lyrics");
        if (placement == .now_playing) gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.true_);
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
            .placement = placement,
            .root = root,
            .stack = root,
            .status = status,
            .scroller = scroller,
            .list = list,
            .plain = plain,
        };
        if (placement == .now_playing) {
            _ = gtk.signalConnect(list, "row-activated", gtk.callback(lineActivated), view);
            buildFooter(view);
        }
        const adjustment = gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller));
        _ = gtk.signalConnect(adjustment, "changed", gtk.callback(adjustmentChanged), view);
        _ = gtk.signalConnect(view.root, "map", gtk.callback(mappedChanged), view);
        _ = gtk.signalConnect(view.root, "unmap", gtk.callback(mappedChanged), view);
    }

    pub fn deinit(view: *View) void {
        if (view.self.lyrics.page_view == view) view.self.lyrics.page_view = null;
        if (view.margin_idle != 0) _ = gtk.g_source_remove(view.margin_idle);
        view.margin_idle = 0;
        view.labels.deinit(view.self.allocator);
    }
};

/// Wraps the stack in fades at its edges and puts the footer under it.
fn buildFooter(view: *View) void {
    const layers = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(gtk.cast(gtk.Overlay, layers), view.stack);
    for ([_][*:0]const u8{ "now-lyrics-fade-top", "now-lyrics-fade-bottom" }, [_]c_int{ gtk.ALIGN_START, gtk.ALIGN_END }) |class, alignment| {
        const fade = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(fade, class);
        gtk.gtk_widget_set_valign(fade, alignment);
        gtk.gtk_widget_set_can_target(fade, gtk.false_);
        gtk.gtk_overlay_add_overlay(gtk.cast(gtk.Overlay, layers), fade);
    }
    gtk.gtk_widget_set_vexpand(layers, gtk.true_);

    const source = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, source), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, source), gtk.ELLIPSIZE_MIDDLE);
    gtk.gtk_widget_set_hexpand(source, gtk.true_);
    gtk.gtk_widget_add_css_class(source, "now-lyrics-source");
    const icon = gtk.gtk_image_new_from_icon_name("text-x-generic-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 14);
    const offset = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(offset, "now-lyrics-offset");
    const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(footer, "now-lyrics-footer");
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), source);
    gtk.gtk_box_append(gtk.cast(gtk.Box, footer), offset);
    gtk.gtk_widget_set_visible(footer, gtk.false_);

    const root = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(root, "now-lyrics-panel");
    gtk.gtk_box_append(gtk.cast(gtk.Box, root), layers);
    gtk.gtk_box_append(gtk.cast(gtk.Box, root), footer);
    view.root = root;
    view.footer = footer;
    view.footer_source = gtk.cast(gtk.Label, source);
    view.footer_offset = gtk.cast(gtk.Label, offset);
}

/// Shows, in `lines`, the synced line being heard between the lines before
/// and after it, or a plain text's first three lines, while `slot` is mapped.
/// `quote` is hidden while there is nothing to show.
pub fn watchQuote(self: *App, slot: *gtk.Widget, quote: *gtk.Widget, lines: [3]*gtk.Widget) void {
    self.lyrics.quote_slot = slot;
    self.lyrics.quote = quote;
    for (&self.lyrics.quote_lines, lines) |*target, line| target.* = line;
    gtk.gtk_widget_set_visible(quote, gtk.false_);
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

pub fn forgetLibrary(self: *App) void {
    discard(self);
    self.lyrics.track_id = null;
    self.lyrics.stale = true;
}

pub fn sync(self: *App) void {
    const state = &self.lyrics;
    if (state.closed) return;
    if ((anyViewMapped(self) or quoteMapped(self)) and (state.stale or !optionalEql(state.track_id, self.shown_track_id))) {
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
    drawQuote(self);
    for (views(self)) |maybe| {
        const view = maybe orelse continue;
        if (viewMapped(view)) render(view);
    }
}

fn views(self: *App) [2]?*View {
    return .{ if (self.inspector) |panel| &panel.lyrics else null, self.lyrics.page_view };
}

fn viewMapped(view: *const View) bool {
    return gtk.gtk_widget_get_mapped(view.root) != 0;
}

fn anyViewMapped(self: *App) bool {
    for (views(self)) |maybe| {
        if (viewMapped(maybe orelse continue)) return true;
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
    sync(self);
}

fn foundLyrics(self: *const App) ?liborca.Lyrics {
    const found = switch (self.lyrics.resolution) {
        .found => |value| value,
        else => return null,
    };
    return found.lyrics;
}

fn drawQuote(self: *App) void {
    const state = &self.lyrics;
    state.quote_drawn = false;
    const quote = state.quote orelse return;
    const lyrics = foundLyrics(self) orelse return gtk.gtk_widget_set_visible(quote, gtk.false_);
    switch (lyrics.kind) {
        .synced => gtk.gtk_widget_set_visible(quote, gtk.false_),
        .instrumental => gtk.gtk_widget_set_visible(quote, gtk.false_),
        .plain => {
            var texts: [3][]const u8 = @splat("");
            var count: usize = 0;
            for (lyrics.lines) |line| {
                if (count == texts.len) break;
                if (std.mem.trim(u8, line.text, " \t").len == 0) continue;
                texts[count] = line.text;
                count += 1;
            }
            setQuoteLines(self, texts);
            setClass(state.quote_lines[1].?, "now-lyric-current", false);
            gtk.gtk_widget_set_visible(quote, boolean(count != 0));
        },
    }
}

fn showQuote(self: *App, lyrics: liborca.Lyrics, line: ?usize) void {
    const state = &self.lyrics;
    const quote = state.quote orelse return;
    if (state.quote_drawn and optionalEql(line, state.quote_line)) return;
    state.quote_drawn = true;
    state.quote_line = line;
    var texts: [3][]const u8 = @splat("");
    if (line) |index| {
        if (index > 0) texts[0] = lyricText(lyrics.lines[index - 1].text);
        texts[1] = lyricText(lyrics.lines[index].text);
        if (index + 1 < lyrics.lines.len) texts[2] = lyricText(lyrics.lines[index + 1].text);
    } else {
        texts[1] = lyricText("");
        if (lyrics.lines.len != 0) texts[2] = lyricText(lyrics.lines[0].text);
    }
    setQuoteLines(self, texts);
    setClass(state.quote_lines[1].?, "now-lyric-current", true);
    gtk.gtk_widget_set_visible(quote, gtk.true_);
}

fn hideQuote(self: *App) void {
    const state = &self.lyrics;
    state.quote_drawn = false;
    if (state.quote) |quote| gtk.gtk_widget_set_visible(quote, gtk.false_);
}

fn lyricText(text: []const u8) []const u8 {
    return if (text.len != 0) text else "♪";
}

fn setQuoteLines(self: *App, texts: [3][]const u8) void {
    var buffer: [512]u8 = undefined;
    for (self.lyrics.quote_lines, texts) |maybe, text| {
        const line = maybe orelse continue;
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, line), strings.terminated(&buffer, text).ptr);
    }
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn adjustmentChanged(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(data.?));
    const half = halfPage(gtk.cast(gtk.Adjustment, adjustment));
    if (view.placement == .details and half != view.margin and view.margin_idle == 0) view.margin_idle = gtk.g_idle_add(applyMargins, view);
    centre(view);
}

fn halfPage(adjustment: *gtk.Adjustment) c_int {
    return @intFromFloat(gtk.gtk_adjustment_get_page_size(adjustment) / 2);
}

fn applyMargins(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const view: *View = @ptrCast(@alignCast(data.?));
    view.margin_idle = 0;
    const half = halfPage(gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, view.scroller)));
    if (half != view.margin) {
        view.margin = half;
        gtk.gtk_widget_set_margin_top(view.list, half);
        gtk.gtk_widget_set_margin_bottom(view.list, half);
    }
    centre(view);
    return gtk.SOURCE_REMOVE;
}

fn syncedLyrics(self: *const App) ?liborca.Lyrics {
    const lyrics = foundLyrics(self) orelse return null;
    return if (lyrics.kind == .synced) lyrics else null;
}

fn step(self: *App) bool {
    const lyrics = syncedLyrics(self) orelse return false;
    const quote_mapped = quoteMapped(self);
    if (!quote_mapped and !anyViewMapped(self)) return false;
    const status = self.runtime.playerStatus(self.player) catch return false;
    if (!optionalEql(status.track_id, self.lyrics.track_id)) {
        hideQuote(self);
        return false;
    }
    const line = lyrics.lineAt(status.position_ms);
    if (quote_mapped) showQuote(self, lyrics, line);
    for (views(self)) |maybe| {
        const view = maybe orelse continue;
        if (viewMapped(view) and view.generation == self.lyrics.generation) highlight(view, line);
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
    showFooter(view);
    switch (state.resolution) {
        .nothing_playing => showStatus(view, "audio-x-generic-symbolic", "Nothing Playing", "Lyrics follow the track that is playing."),
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
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, view.stack), "status");
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
        gtk.gtk_list_box_row_set_activatable(gtk.cast(gtk.ListBoxRow, row), boolean(view.placement == .now_playing));
        gtk.gtk_list_box_append(list, row);
        view.labels.appendAssumeCapacity(label);
    }
    gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, view.scroller)), 0.0);
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, view.stack), "synced");
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
    gtk.gtk_stack_set_visible_child_name(gtk.cast(gtk.Stack, view.stack), "plain");
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
    const anchor: f64 = switch (view.placement) {
        .details => page / 2,
        .now_playing => page / 3,
    };
    gtk.gtk_adjustment_set_value(adjustment, gtk.gtk_adjustment_get_value(adjustment) + middle - anchor);
}

fn showFooter(view: *View) void {
    const footer = view.footer orelse return;
    const lyrics = foundLyrics(view.self) orelse return gtk.gtk_widget_set_visible(footer, gtk.false_);
    var source_buffer: [512]u8 = undefined;
    gtk.gtk_label_set_text(view.footer_source.?, sourceText(&source_buffer, lyrics).ptr);
    var offset_buffer: [64]u8 = undefined;
    const offset = offsetText(&offset_buffer, lyrics.offset_ms);
    gtk.gtk_label_set_text(view.footer_offset.?, offset.ptr);
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, view.footer_offset.?), boolean(offset.len != 0));
    gtk.gtk_widget_set_visible(footer, gtk.true_);
}

fn sourceText(buffer: []u8, lyrics: liborca.Lyrics) [:0]const u8 {
    const kind = switch (lyrics.kind) {
        .synced => "Synced",
        .plain => "Plain",
        .instrumental => "Instrumental",
    };
    const name = lyrics.source_name orelse return strings.format(buffer, "{s}", .{kind});
    if (lyrics.source == .embedded) return strings.format(buffer, "{s} · {s}", .{ kind, name });
    return strings.format(buffer, "{s} · from {s}", .{ kind, name });
}

/// "Offset −0.2 s", with a minus sign and no trailing zeros; empty for none.
fn offsetText(buffer: []u8, offset_ms: i64) [:0]const u8 {
    if (offset_ms == 0) return strings.format(buffer, "", .{});
    const magnitude = @abs(offset_ms);
    var fraction_buffer: [3]u8 = undefined;
    const fraction = std.fmt.bufPrint(&fraction_buffer, "{d:0>3}", .{magnitude % 1000}) catch unreachable;
    const digits = std.mem.trimEnd(u8, fraction, "0");
    const sign = if (offset_ms < 0) "\u{2212}" else "+";
    if (digits.len == 0) return strings.format(buffer, "Offset {s}{d} s", .{ sign, magnitude / 1000 });
    return strings.format(buffer, "Offset {s}{d}.{s} s", .{ sign, magnitude / 1000, digits });
}

fn lineActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(data.?));
    const self = view.self;
    if (view.generation != self.lyrics.generation) return;
    const lyrics = syncedLyrics(self) orelse return;
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row.?));
    if (index < 0 or index >= lyrics.lines.len) return;
    const status = self.runtime.playerStatus(self.player) catch return;
    if (!optionalEql(status.track_id, self.lyrics.track_id)) return;
    _ = self.runtime.playerSeekMs(self.player, lyrics.lines[@intCast(index)].start_ms orelse 0) catch return;
    self.mpris.notify();
    self.requestTick();
}

fn setClass(widget: *gtk.Widget, name: [*:0]const u8, on: bool) void {
    if (on) gtk.gtk_widget_add_css_class(widget, name) else gtk.gtk_widget_remove_css_class(widget, name);
}

fn optionalEql(a: anytype, b: @TypeOf(a)) bool {
    if (a) |left| return left == (b orelse return false);
    return b == null;
}
