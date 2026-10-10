//! Library Radio in the window: the Queue page's Radio panel, its seed and
//! focus pickers, and starting and stopping Radio from menus and the player
//! bar. What it shows comes from the Player's Radio snapshot on each tick.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const transport = @import("transport.zig");
const page_ui = @import("page.zig");
const details = @import("details.zig");
const jobs = @import("jobs.zig");
const analysis_notice = @import("analysis_notice.zig");
const main_window = @import("window.zig");

const App = app.App;

const seed_cover_pixels: c_int = 48;
const picker_rows = 12;
const explore_settle_ms: c_uint = 300;
const newest_decade: i64 = 2020;
const oldest_decade: i64 = 1950;
const subject_capacity = 256;

const Snapshot = struct {
    on: bool = false,
    seed: liborca.RadioSeed = .recent,
    title_hash: u64 = 0,
    options: liborca.RadioOptions = .{},
    state: liborca.RadioState = .active,
    counts: liborca.RadioCounts = .{},
    pending: u32 = 0,
    picks_hash: u64 = 0,
};

const PickerMode = enum { seed, focus, home_artist, home_genre, home_decade };
const Tab = enum { artist, genre, decade, energy };

const Choice = union(enum) {
    artist: i64,
    genre: i64,
    decade: i64,
    low_energy,
    high_energy,
};

const Picker = struct {
    button: ?*gtk.Widget = null,
    popover: ?*gtk.Widget = null,
    entry: ?*gtk.Widget = null,
    list: ?*gtk.Widget = null,
    tab: Tab,
    choices: [picker_rows]Choice = undefined,
    count: usize = 0,
};

pub const State = struct {
    shown: Snapshot = .{},
    revision: u32 = 0,
    stale: bool = true,
    painting: bool = false,
    split: ?*gtk.Widget = null,
    content: ?*gtk.Widget = null,
    on_switch: ?*gtk.Widget = null,
    seed_cover: ?*gtk.Widget = null,
    seed_title: ?*gtk.Label = null,
    seed_kind: ?*gtk.Label = null,
    explore: ?*gtk.Widget = null,
    explore_note: ?*gtk.Label = null,
    explore_timer: c_uint = 0,
    focus_box: ?*gtk.Widget = null,
    unplayed_switch: ?*gtk.Widget = null,
    avoid_switch: ?*gtk.Widget = null,
    avoid_note: ?*gtk.Label = null,
    live_switch: ?*gtk.Widget = null,
    notice: ?*gtk.Widget = null,
    notice_text: ?*gtk.Label = null,
    notice_analyze: ?*gtk.Widget = null,
    session: ?*gtk.Label = null,
    undo: ?*gtk.Widget = null,
    subject: [subject_capacity]u8 = undefined,
    subject_len: usize = 0,
    subject_is_artist: bool = false,
    seed_picker: Picker = .{ .tab = .artist },
    focus_picker: Picker = .{ .tab = .genre },
    home_pickers: [3]Picker = .{ .{ .tab = .artist }, .{ .tab = .genre }, .{ .tab = .decade } },
};

pub const HomeSeed = enum { artist, genre, decade };

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

pub fn isOn(self: *const App) bool {
    return self.radio.shown.on;
}

/// Forces the next tick to repaint the panel, for when a setting it reads changed.
pub fn invalidate(self: *App) void {
    self.radio.stale = true;
    self.requestTick();
}

fn hashPicks(picks: []const liborca.RadioQueuePick) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (picks) |pick| {
        hasher.update(std.mem.asBytes(&pick.entry_id));
        hasher.update(std.mem.asBytes(&pick.position));
    }
    return hasher.final();
}

fn snapshot(self: *App) Snapshot {
    const status = (self.runtime.playerRadio(self.player) catch return .{}) orelse return .{};
    var picks: [liborca.max_radio_reported_picks]liborca.RadioQueuePick = undefined;
    const count = self.runtime.playerRadioPicks(self.player, &picks) catch 0;
    return .{
        .on = true,
        .seed = status.seed,
        .title_hash = std.hash.Wyhash.hash(0, status.title()),
        .options = status.options,
        .state = status.state,
        .counts = status.counts,
        .pending = status.pending,
        .picks_hash = hashPicks(picks[0..count]),
    };
}

pub fn tick(self: *App) void {
    const next = snapshot(self);
    const radio = &self.radio;
    if (!radio.stale and std.meta.eql(next, radio.shown)) return;
    const was_on = radio.shown.on;
    const seed_changed = radio.stale or !std.meta.eql(next.seed, radio.shown.seed) or next.title_hash != radio.shown.title_hash;
    const focus_changed = radio.stale or !radio.shown.on or !std.meta.eql(next.options.focus, radio.shown.options.focus);
    radio.shown = next;
    radio.stale = false;
    radio.revision +%= 1;
    if (next.on) repaint(self, seed_changed, focus_changed);
    transport.showRadio(self, next.on);
    if (was_on != next.on) placePanel(self);
}

fn startError(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.UnknownRadioSeed => "That is no longer in your library",
        error.LibraryNotBound, error.PlayerLibraryMismatch => "Radio plays from the open library",
        else => "Could not start Radio",
    };
}

fn start(self: *App, seed: liborca.RadioSeed, options: liborca.RadioOptions) bool {
    const library = self.library orelse {
        self.toast("No library is open");
        return false;
    };
    if (!transport.ensureOutput(self)) {
        self.toast("No audio output is available");
        return false;
    }
    self.runtime.playerStartRadio(self.player, library, seed, options) catch |err| {
        self.toast(startError(err));
        return false;
    };
    self.mpris.notify();
    self.requestTick();
    return true;
}

fn stop(self: *App) void {
    self.runtime.playerStopRadio(self.player) catch return self.toast("Could not stop Radio");
    self.mpris.notify();
    self.requestTick();
}

fn playingSeed(self: *App) liborca.RadioSeed {
    const status = self.runtime.playerStatus(self.player) catch return .recent;
    return if (status.track_id) |track_id| .{ .track = track_id } else .recent;
}

/// The player bar's Radio button: stops Radio, or starts it from the playing
/// Track, else from recent listening.
pub fn toggle(self: *App) void {
    if (isOn(self)) return stop(self);
    _ = start(self, playingSeed(self), .{});
}

pub fn stopClicked(self: *App) void {
    stop(self);
}

fn contextSeed(context: anytype) ?liborca.RadioSeed {
    return switch (context.kind) {
        .album => if (context.release_id) |id| .{ .release = id } else null,
        .artist => if (context.artist_id) |id| .{ .artist = id } else null,
        .tracks, .playlist, .queue => if (context.tracks.items.len == 1) .{ .track = context.tracks.items[0] } else null,
    };
}

/// "Start Radio" from a context menu: seeds from the Track, album or artist
/// the menu was opened on and shows the Queue.
pub fn startFromContext(self: *App) void {
    const seed = contextSeed(&self.context) orelse return;
    if (start(self, seed, .{})) main_window.goTo(self, .queue);
}

pub fn startShowingQueue(self: *App, seed: liborca.RadioSeed) void {
    if (start(self, seed, .{})) main_window.goTo(self, .queue);
}

pub fn startFromPlaying(self: *App) void {
    startShowingQueue(self, playingSeed(self));
}

pub fn startFromLoved(self: *App) void {
    startShowingQueue(self, .loved);
}

pub fn buildHomePicker(self: *App, seed: HomeSeed, button: *gtk.Widget) void {
    const index: usize = @backingInt(seed);
    const mode: PickerMode = switch (seed) {
        .artist => .home_artist,
        .genre => .home_genre,
        .decade => .home_decade,
    };
    const tab: Tab = switch (seed) {
        .artist => .artist,
        .genre => .genre,
        .decade => .decade,
    };
    buildPicker(self, &self.radio.home_pickers[index], mode, &.{tab}, button);
}

fn currentStatus(self: *App) ?liborca.RadioStatus {
    return self.runtime.playerRadio(self.player) catch null;
}

fn setOptions(self: *App, options: liborca.RadioOptions) void {
    self.runtime.playerSetRadioOptions(self.player, options) catch |err| {
        self.toast(switch (err) {
            error.RadioNotActive => "Radio is off",
            else => "Could not change Radio",
        });
        self.radio.stale = true;
    };
    self.mpris.notify();
    self.requestTick();
}

fn currentOptions(self: *App) ?liborca.RadioOptions {
    const status = currentStatus(self) orelse return null;
    return status.options;
}

fn discoverySettings(self: *App) liborca.DiscoverySettings {
    const library = self.library orelse return .{};
    return self.runtime.libraryDiscoverySettings(library) catch .{};
}

fn avoidDays(settings: liborca.DiscoverySettings) u8 {
    return if (settings.avoid_days == .none) 3 else @backingInt(settings.avoid_days);
}

fn label(text: ?[*:0]const u8, css: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, css);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    return widget;
}

fn wrapped(text: ?[*:0]const u8, css: [*:0]const u8) *gtk.Widget {
    const widget = label(text, css);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, widget), gtk.WRAP_WORD_CHAR);
    return widget;
}

fn ellipsized(css: [*:0]const u8) *gtk.Widget {
    const widget = label(null, css);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    return widget;
}

fn append(box: *gtk.Widget, parts: []const *gtk.Widget) void {
    for (parts) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, box), part);
}

fn vertical(spacing: c_int, css: ?[*:0]const u8) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, spacing);
    if (css) |name| gtk.gtk_widget_add_css_class(box, name);
    return box;
}

fn setAccessibleName(widget: *gtk.Widget, text: [*:0]const u8) void {
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, widget), gtk.ACCESSIBLE_PROPERTY_LABEL, text, @as(c_int, -1));
}

fn newSwitch(accessible: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const widget = gtk.gtk_switch_new();
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    setAccessibleName(widget, accessible);
    _ = gtk.signalConnect(widget, "notify::active", handler, self);
    return widget;
}

fn switchRow(title: [*:0]const u8, note: ?*gtk.Widget, toggle_widget: *gtk.Widget) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "radio-switch-row");
    const text = vertical(2, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{wrapped(title, "radio-switch-title")});
    if (note) |widget| append(text, &.{widget});
    append(row, &.{ text, toggle_widget });
    return row;
}

fn switchActive(widget: ?*anyopaque) bool {
    return gtk.gtk_switch_get_active(gtk.cast(gtk.Switch, widget.?)) != 0;
}

fn setSwitch(widget: ?*gtk.Widget, active: bool) void {
    if (widget) |value| gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, value), boolean(active));
}

fn onSwitched(widget: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.radio.painting) return;
    const active = switchActive(widget);
    if (active == isOn(self)) return;
    if (active) {
        if (!start(self, playingSeed(self), .{})) setSwitch(self.radio.on_switch, false);
    } else stop(self);
}

fn unplayedSwitched(widget: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.radio.painting) return;
    var options = currentOptions(self) orelse return;
    options.include_unplayed = switchActive(widget);
    setOptions(self, options);
}

fn avoidSwitched(widget: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.radio.painting) return;
    var options = currentOptions(self) orelse return;
    options.avoid_recent = switchActive(widget);
    setOptions(self, options);
}

fn liveSwitched(widget: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.radio.painting) return;
    var options = currentOptions(self) orelse return;
    options.include_live = switchActive(widget);
    setOptions(self, options);
}

fn exploreValue(self: *App) u8 {
    const scale = self.radio.explore orelse return 35;
    const value = gtk.gtk_range_get_value(gtk.cast(gtk.Range, scale));
    return @intFromFloat(std.math.clamp(@round(value), 0, 100));
}

fn exploreChanged(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.radio.painting) return;
    showExplore(self, exploreValue(self));
    if (self.radio.explore_timer != 0) _ = gtk.g_source_remove(self.radio.explore_timer);
    self.radio.explore_timer = gtk.g_timeout_add(explore_settle_ms, exploreSettled, self);
}

fn exploreSettled(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.radio.explore_timer = 0;
    var options = currentOptions(self) orelse return gtk.SOURCE_REMOVE;
    const explore = exploreValue(self);
    if (options.explore == explore) return gtk.SOURCE_REMOVE;
    options.explore = explore;
    setOptions(self, options);
    return gtk.SOURCE_REMOVE;
}

const ExploreBand = enum { close, mostly_close, balanced, explore };

fn band(explore: u8) ExploreBand {
    if (explore <= 20) return .close;
    if (explore <= 45) return .mostly_close;
    if (explore <= 70) return .balanced;
    return .explore;
}

fn describeExplore(buffer: []u8, explore: u8, subject: []const u8, is_artist: bool) [:0]const u8 {
    const who = if (subject.len == 0) "the starting track" else subject;
    return switch (band(explore)) {
        .close => if (is_artist)
            strings.format(buffer, "Only {s} and the artists closest to them.", .{who})
        else
            strings.format(buffer, "Only {s} and its closest matches.", .{who}),
        .mostly_close => if (is_artist)
            strings.format(buffer, "Mostly {s} and closely related artists, with an occasional detour.", .{who})
        else
            strings.format(buffer, "Mostly {s} and close matches, with an occasional detour.", .{who}),
        .balanced => if (is_artist)
            strings.format(buffer, "A balance of {s}, related artists and tracks with a similar sound.", .{who})
        else
            strings.format(buffer, "A balance of {s} and tracks with a similar sound.", .{who}),
        .explore => strings.format(buffer, "Wanders from {s} into similar sounds and what you play together, across genres.", .{who}),
    };
}

fn bandText(explore: u8) [*:0]const u8 {
    return switch (band(explore)) {
        .close => "Close",
        .mostly_close => "Mostly close",
        .balanced => "Balanced",
        .explore => "Exploring",
    };
}

fn showExplore(self: *App, explore: u8) void {
    const radio = &self.radio;
    var buffer: [subject_capacity + 128]u8 = undefined;
    const text = describeExplore(&buffer, explore, radio.subject[0..radio.subject_len], radio.subject_is_artist);
    if (radio.explore_note) |note| gtk.gtk_label_set_text(note, text.ptr);
    if (radio.explore) |scale|
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, scale), gtk.ACCESSIBLE_PROPERTY_VALUE_TEXT, bandText(explore), @as(c_int, -1));
}

fn keepSubject(self: *App, text: []const u8, is_artist: bool) void {
    const radio = &self.radio;
    var length = @min(text.len, subject_capacity);
    while (length != 0 and !std.unicode.utf8ValidateSlice(text[0..length])) length -= 1;
    @memcpy(radio.subject[0..length], text[0..length]);
    radio.subject_len = length;
    radio.subject_is_artist = is_artist;
}

fn decadeText(buffer: []u8, year: i64) [:0]const u8 {
    return strings.format(buffer, "{d}s", .{@as(u64, @intCast(@max(year, 0)))});
}

fn paintSeed(self: *App, status: *const liborca.RadioStatus) void {
    const radio = &self.radio;
    const title_label = radio.seed_title orelse return;
    const kind_label = radio.seed_kind orelse return;
    const cover = radio.seed_cover orelse return;
    var title_buffer: [1024]u8 = undefined;
    var kind_buffer: [1024]u8 = undefined;
    var title: [:0]const u8 = strings.terminated(&title_buffer, status.title());
    var kind: [:0]const u8 = "";
    const library = status.library;
    switch (status.seed) {
        .track => |track_id| {
            kind = "Track";
            keepSubject(self, status.title(), false);
            if (self.runtime.libraryTrackSummary(library, track_id) catch null) |summary| {
                defer summary.deinit(self.allocator);
                if (summary.artist.len != 0) {
                    kind = strings.format(&kind_buffer, "{s} · track", .{summary.artist});
                    keepSubject(self, summary.artist, true);
                }
                art.show(self, cover, if (summary.release_id) |release| art.Key.release(release, .thumb) else art.Key.track(track_id, .thumb));
            } else art.clear(self, cover);
        },
        .release => |release_id| {
            kind = "Album";
            keepSubject(self, status.title(), false);
            if (self.runtime.libraryRelease(library, release_id) catch null) |release| {
                defer release.deinit(self.allocator);
                if (release.album_artist.len != 0) {
                    kind = strings.format(&kind_buffer, "{s} · album", .{release.album_artist});
                    keepSubject(self, release.album_artist, true);
                }
            }
            art.show(self, cover, art.Key.release(release_id, .thumb));
        },
        .artist => |artist_id| {
            kind = "Artist";
            keepSubject(self, status.title(), true);
            art.showArtist(self, cover, artist_id, .unknown, null, .thumb);
        },
        .genre => {
            kind = "Genre";
            keepSubject(self, status.title(), false);
            art.clear(self, cover);
        },
        .decade => |year| {
            title = decadeText(&title_buffer, year);
            kind = "Decade";
            var subject_buffer: [32]u8 = undefined;
            keepSubject(self, strings.format(&subject_buffer, "the {d}s", .{@as(u64, @intCast(@max(year, 0)))}), false);
            art.clear(self, cover);
        },
        .loved => {
            title = "Loved tracks";
            kind = "Loved";
            keepSubject(self, "your loved tracks", false);
            art.clear(self, cover);
        },
        .recent => {
            title = "Recent listening";
            kind = "Your last five tracks";
            keepSubject(self, "what you played lately", false);
            art.clear(self, cover);
        },
    }
    gtk.gtk_label_set_text(title_label, title.ptr);
    gtk.gtk_label_set_text(kind_label, kind.ptr);
}

fn focusText(self: *App, buffer: []u8, focus: liborca.RadioFocus) [:0]const u8 {
    return switch (focus) {
        .genre => |genre_id| blk: {
            const library = self.library orelse break :blk "Genre";
            const genre = (self.runtime.libraryGenre(library, genre_id) catch null) orelse break :blk "Genre";
            defer genre.deinit(self.allocator);
            break :blk strings.terminated(buffer, genre.name);
        },
        .decade => |year| decadeText(buffer, year),
        .low_energy => "Low energy",
        .high_energy => "High energy",
    };
}

fn chip(self: *App, text: [:0]const u8, slot: usize) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(box, "radio-chip");
    const chip_label = gtk.gtk_label_new(text.ptr);
    gtk.gtk_widget_set_valign(chip_label, gtk.ALIGN_CENTER);
    const remove = gtk.gtk_button_new_from_icon_name("orca-close-symbolic");
    gtk.gtk_widget_add_css_class(remove, "flat");
    gtk.gtk_widget_add_css_class(remove, "radio-chip-remove");
    gtk.gtk_widget_set_valign(remove, gtk.ALIGN_CENTER);
    var buffer: [320]u8 = undefined;
    const accessible = strings.format(&buffer, "Remove {s}", .{text});
    setAccessibleName(remove, accessible.ptr);
    gtk.gtk_widget_set_tooltip_text(remove, accessible.ptr);
    gtk.g_object_set_data(remove, "orca-focus-slot", @ptrFromInt(slot + 1));
    _ = gtk.signalConnect(remove, "clicked", gtk.callback(chipRemoved), self);
    append(box, &.{ chip_label, remove });
    return box;
}

fn chipRemoved(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const stored = gtk.g_object_get_data(button.?, "orca-focus-slot") orelse return;
    const slot = @intFromPtr(stored) - 1;
    var options = currentOptions(self) orelse return;
    if (slot >= options.focus.len) return;
    options.focus[slot] = null;
    setOptions(self, options);
}

fn paintFocus(self: *App, options: liborca.RadioOptions) void {
    const radio = &self.radio;
    const box = radio.focus_box orelse return;
    const add = radio.focus_picker.button orelse return;
    _ = gtk.g_object_ref(add);
    defer gtk.g_object_unref(add);
    adw.adw_wrap_box_remove_all(gtk.cast(adw.WrapBox, box));
    var count: usize = 0;
    for (options.focus, 0..) |maybe_focus, slot| {
        const focus = maybe_focus orelse continue;
        var buffer: [256]u8 = undefined;
        adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, box), chip(self, focusText(self, &buffer, focus), slot));
        count += 1;
    }
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, box), add);
    gtk.gtk_widget_set_visible(add, boolean(count < options.focus.len));
}

fn paintSession(self: *App, counts: liborca.RadioCounts) void {
    const radio = &self.radio;
    if (radio.session) |session| {
        var buffer: [128]u8 = undefined;
        const text = if (counts.less_like_this == 0 and counts.skips == 0)
            "No feedback yet"
        else
            strings.format(&buffer, "{d} marked “Less like this” · {d} skipped", .{ counts.less_like_this, counts.skips });
        gtk.gtk_label_set_text(session, text.ptr);
    }
    if (radio.undo) |undo| gtk.gtk_widget_set_sensitive(undo, boolean(counts.less_like_this != 0 or counts.skips != 0));
}

fn hasEnergyFocus(options: liborca.RadioOptions) bool {
    for (options.focus) |maybe_focus| {
        const focus = maybe_focus orelse continue;
        switch (focus) {
            .low_energy, .high_energy => return true,
            .genre, .decade => {},
        }
    }
    return false;
}

fn needsAnalysis(self: *const App) bool {
    return analysis_notice.lacksFeatures(self) orelse false;
}

fn paintNotice(self: *App, status: *const liborca.RadioStatus) void {
    const radio = &self.radio;
    const notice = radio.notice orelse return;
    const text = radio.notice_text orelse return;
    const exhausted = status.state == .exhausted;
    const analysis = exhausted and hasEnergyFocus(status.options) and needsAnalysis(self);
    const analyzing = analysis and jobs.active(self, .analysis);
    gtk.gtk_widget_set_visible(notice, boolean(exhausted));
    if (radio.notice_analyze) |button| gtk.gtk_widget_set_visible(button, boolean(analysis and !analyzing));
    if (!exhausted) return;
    gtk.gtk_label_set_text(text, if (analyzing)
        "Energy needs analyzed music. Analyzing your music…"
    else if (analysis)
        "Energy needs analyzed music. Analyze your music to find the energy of each track."
    else
        "Nothing in your library matches these options.");
}

fn analyzeClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startAnalysis(state(data));
}

fn repaint(self: *App, seed_changed: bool, focus_changed: bool) void {
    const status = currentStatus(self) orelse return;
    const radio = &self.radio;
    radio.painting = true;
    defer radio.painting = false;
    setSwitch(radio.on_switch, true);
    if (seed_changed) paintSeed(self, &status);
    const options = status.options;
    if (radio.explore_timer == 0) {
        if (radio.explore) |scale| gtk.gtk_range_set_value(gtk.cast(gtk.Range, scale), @floatFromInt(options.explore));
        showExplore(self, options.explore);
    }
    if (focus_changed) paintFocus(self, options);
    const settings = discoverySettings(self);
    setSwitch(radio.unplayed_switch, options.include_unplayed orelse settings.include_unplayed);
    setSwitch(radio.avoid_switch, options.avoid_recent orelse (settings.avoid_days != .none));
    setSwitch(radio.live_switch, options.include_live);
    if (radio.avoid_note) |note| {
        const days = avoidDays(settings);
        var buffer: [64]u8 = undefined;
        const text = strings.format(&buffer, "Skips anything from the last {d} {s}", .{ days, if (days == 1) "day" else "days" });
        gtk.gtk_label_set_text(note, text.ptr);
    }
    paintNotice(self, &status);
    paintSession(self, status.counts);
}

fn undoClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.runtime.playerRadioUndoFeedback(self.player) catch return self.toast("Could not undo the feedback");
    self.requestTick();
}

fn modeOf(widget: *anyopaque) PickerMode {
    const stored = @intFromPtr(gtk.g_object_get_data(widget, "orca-radio-picker"));
    if (stored == 0) return .seed;
    return @fromBackingInt(@intCast(stored - 1));
}

fn pickerOf(self: *App, widget: *anyopaque) *Picker {
    return switch (modeOf(widget)) {
        .seed => &self.radio.seed_picker,
        .focus => &self.radio.focus_picker,
        .home_artist => &self.radio.home_pickers[0],
        .home_genre => &self.radio.home_pickers[1],
        .home_decade => &self.radio.home_pickers[2],
    };
}

fn markPicker(widget: *gtk.Widget, mode: PickerMode) void {
    gtk.g_object_set_data(widget, "orca-radio-picker", @ptrFromInt(@as(usize, @backingInt(mode)) + 1));
}

fn tabTitle(tab: Tab) [*:0]const u8 {
    return switch (tab) {
        .artist => "Artist",
        .genre => "Genre",
        .decade => "Decade",
        .energy => "Energy",
    };
}

fn tabSearches(tab: Tab) bool {
    return tab == .artist or tab == .genre;
}

fn tabToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) == 0) return;
    const picker = pickerOf(self, button.?);
    const stored = @intFromPtr(gtk.g_object_get_data(button.?, "orca-radio-tab"));
    if (stored == 0) return;
    picker.tab = @fromBackingInt(@intCast(stored - 1));
    if (picker.entry) |entry| {
        gtk.gtk_widget_set_visible(entry, boolean(tabSearches(picker.tab)));
        gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), "");
    }
    fill(self, picker);
}

fn searchChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    fill(self, pickerOf(self, entry.?));
}

fn pickerShown(popover: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const picker = pickerOf(self, popover.?);
    if (picker.entry) |entry| gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), "");
    fill(self, picker);
    if (picker.entry) |entry| if (tabSearches(picker.tab)) {
        _ = gtk.gtk_widget_grab_focus(entry);
    };
}

fn addRow(picker: *Picker, text: [:0]const u8, choice: Choice) void {
    const list = picker.list orelse return;
    if (picker.count == picker_rows) return;
    const row_label = label(text.ptr, "radio-picker-row");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, row_label), gtk.ELLIPSIZE_END);
    gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list), row_label);
    picker.choices[picker.count] = choice;
    picker.count += 1;
}

fn fill(self: *App, picker: *Picker) void {
    const list = picker.list orelse return;
    gtk.gtk_list_box_remove_all(gtk.cast(gtk.ListBox, list));
    picker.count = 0;
    const filter: []const u8 = if (picker.entry) |entry| std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry))) else "";
    var buffer: [512]u8 = undefined;
    switch (picker.tab) {
        .artist => if (self.library) |library| {
            const page = self.runtime.libraryArtistPage(library, .{ .filter = filter, .sort = .track_count, .limit = picker_rows }) catch return;
            defer page.deinit();
            for (page.items) |artist| addRow(picker, strings.terminated(&buffer, artist.name), .{ .artist = artist.id });
        },
        .genre => if (self.library) |library| {
            const page = self.runtime.libraryGenrePage(library, .{ .filter = filter, .sort = .track_count, .limit = picker_rows }) catch return;
            defer page.deinit();
            for (page.items) |genre| addRow(picker, strings.terminated(&buffer, genre.name), .{ .genre = genre.id });
        },
        .decade => {
            var year = newest_decade;
            while (year >= oldest_decade) : (year -= 10) addRow(picker, decadeText(&buffer, year), .{ .decade = year });
        },
        .energy => {
            addRow(picker, "Low energy", .low_energy);
            addRow(picker, "High energy", .high_energy);
        },
    }
    if (picker.count == 0) {
        const empty = label("No matches", "radio-picker-empty");
        gtk.gtk_list_box_append(gtk.cast(gtk.ListBox, list), empty);
        if (gtk.gtk_list_box_get_row_at_index(gtk.cast(gtk.ListBox, list), 0)) |row| {
            gtk.gtk_list_box_row_set_activatable(row, gtk.false_);
            gtk.gtk_widget_set_focusable(gtk.cast(gtk.Widget, row), gtk.false_);
        }
    }
}

fn focusOf(choice: Choice) liborca.RadioFocus {
    return switch (choice) {
        .artist, .genre => |id| .{ .genre = id },
        .decade => |year| .{ .decade = year },
        .low_energy => .low_energy,
        .high_energy => .high_energy,
    };
}

fn seedOf(choice: Choice) liborca.RadioSeed {
    return switch (choice) {
        .artist => |id| .{ .artist = id },
        .genre => |id| .{ .genre = id },
        .decade => |year| .{ .decade = year },
        .low_energy, .high_energy => .loved,
    };
}

fn addFocus(self: *App, focus: liborca.RadioFocus) void {
    var options = currentOptions(self) orelse return;
    for (options.focus) |existing| if (existing) |value| if (std.meta.eql(value, focus)) return;
    for (&options.focus) |*slot| if (slot.* == null) {
        slot.* = focus;
        return setOptions(self, options);
    };
    self.toast("Radio takes up to four focus filters");
}

fn rowActivated(list: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const picker = pickerOf(self, list.?);
    const index = gtk.gtk_list_box_row_get_index(gtk.cast(gtk.ListBoxRow, row.?));
    if (index < 0 or @as(usize, @intCast(index)) >= picker.count) return;
    const choice = picker.choices[@intCast(index)];
    if (picker.popover) |popover| gtk.gtk_popover_popdown(gtk.cast(gtk.Popover, popover));
    switch (modeOf(list.?)) {
        .focus => return addFocus(self, focusOf(choice)),
        .home_artist, .home_genre, .home_decade => return startShowingQueue(self, seedOf(choice)),
        .seed => {},
    }
    const options = currentOptions(self) orelse liborca.RadioOptions{};
    _ = start(self, seedOf(choice), options);
}

fn buildPicker(self: *App, picker: *Picker, mode: PickerMode, tabs: []const Tab, button: *gtk.Widget) void {
    const column = vertical(8, "radio-picker");
    const tab_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(tab_row, "radio-picker-tabs");
    var group: ?*gtk.ToggleButton = null;
    for (tabs) |tab| {
        const tab_button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, tab_button), tabTitle(tab));
        gtk.gtk_widget_add_css_class(tab_button, "radio-picker-tab");
        gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, tab_button), group);
        group = group orelse gtk.cast(gtk.ToggleButton, tab_button);
        if (tab == picker.tab) gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, tab_button), gtk.true_);
        markPicker(tab_button, mode);
        gtk.g_object_set_data(tab_button, "orca-radio-tab", @ptrFromInt(@as(usize, @backingInt(tab)) + 1));
        _ = gtk.signalConnect(tab_button, "toggled", gtk.callback(tabToggled), self);
        append(tab_row, &.{tab_button});
    }
    gtk.gtk_widget_set_visible(tab_row, boolean(tabs.len > 1));
    const entry = gtk.gtk_search_entry_new();
    gtk.gtk_search_entry_set_placeholder_text(gtk.cast(gtk.SearchEntry, entry), "Search");
    gtk.gtk_search_entry_set_search_delay(gtk.cast(gtk.SearchEntry, entry), 150);
    gtk.gtk_widget_set_visible(entry, boolean(tabSearches(picker.tab)));
    markPicker(entry, mode);
    _ = gtk.signalConnect(entry, "search-changed", gtk.callback(searchChanged), self);
    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "radio-picker-list");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.true_);
    markPicker(list, mode);
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(rowActivated), self);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 320);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    append(column, &.{ tab_row, entry, scroller });

    const popover = gtk.gtk_popover_new();
    gtk.gtk_widget_add_css_class(popover, "radio-picker-popover");
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), column);
    markPicker(popover, mode);
    _ = gtk.signalConnect(popover, "show", gtk.callback(pickerShown), self);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    picker.* = .{ .button = button, .popover = popover, .entry = entry, .list = list, .tab = picker.tab };
}

fn heading(text: [*:0]const u8) *gtk.Widget {
    return label(text, "radio-panel-label");
}

fn buildSeed(self: *App) *gtk.Widget {
    const radio = &self.radio;
    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(card, "radio-seed");
    const cover = art.newCover(self, art.iconPlaceholder(seed_cover_pixels), seed_cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "radio-seed-cover");
    gtk.gtk_widget_set_valign(cover, gtk.ALIGN_CENTER);
    radio.seed_cover = cover;
    const text = vertical(2, null);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    const title = ellipsized("radio-seed-title");
    const kind = ellipsized("radio-seed-kind");
    radio.seed_title = gtk.cast(gtk.Label, title);
    radio.seed_kind = gtk.cast(gtk.Label, kind);
    append(text, &.{ title, kind });
    const change = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, change), gtk.gtk_label_new("Change"));
    gtk.gtk_widget_add_css_class(change, "radio-link");
    gtk.gtk_widget_set_valign(change, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(change, "Start Radio from an artist, genre or decade");
    buildPicker(self, &radio.seed_picker, .seed, &.{ .artist, .genre, .decade }, change);
    append(card, &.{ cover, text, change });
    const group = vertical(8, null);
    append(group, &.{ heading("Started from"), card });
    return group;
}

fn buildExplore(self: *App) *gtk.Widget {
    const radio = &self.radio;
    const ends = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    const close = heading("Stay close");
    gtk.gtk_widget_set_hexpand(close, gtk.true_);
    append(ends, &.{ close, heading("Explore") });
    const adjustment = gtk.gtk_adjustment_new(35, 0, 100, 1, 10, 0);
    const scale = gtk.gtk_scale_new(gtk.ORIENTATION_HORIZONTAL, adjustment);
    gtk.gtk_scale_set_draw_value(gtk.cast(gtk.Scale, scale), gtk.false_);
    gtk.gtk_widget_add_css_class(scale, "radio-explore");
    setAccessibleName(scale, "How far Radio wanders from the starting track");
    radio.explore = scale;
    _ = gtk.signalConnect(scale, "value-changed", gtk.callback(exploreChanged), self);
    const note = wrapped(null, "radio-panel-note");
    radio.explore_note = gtk.cast(gtk.Label, note);
    const group = vertical(10, null);
    append(group, &.{ ends, scale, note });
    return group;
}

fn buildFocus(self: *App) *gtk.Widget {
    const radio = &self.radio;
    const chips = adw.adw_wrap_box_new();
    adw.adw_wrap_box_set_child_spacing(gtk.cast(adw.WrapBox, chips), 6);
    adw.adw_wrap_box_set_line_spacing(gtk.cast(adw.WrapBox, chips), 6);
    radio.focus_box = chips;
    const add = gtk.gtk_menu_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 5);
    const plus = gtk.gtk_image_new_from_icon_name("orca-plus-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, plus), 13);
    append(content, &.{ plus, gtk.gtk_label_new("Genre, decade, energy") });
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, add), content);
    gtk.gtk_widget_add_css_class(add, "radio-add-focus");
    setAccessibleName(add, "Add a genre, decade or energy focus");
    buildPicker(self, &radio.focus_picker, .focus, &.{ .genre, .decade, .energy }, add);
    adw.adw_wrap_box_append(gtk.cast(adw.WrapBox, chips), add);
    const group = vertical(8, null);
    append(group, &.{ heading("Focus"), chips });
    return group;
}

fn buildSwitches(self: *App) *gtk.Widget {
    const radio = &self.radio;
    const unplayed = newSwitch("Include tracks you've never played", gtk.callback(unplayedSwitched), self);
    const avoid = newSwitch("Avoid recently played", gtk.callback(avoidSwitched), self);
    const live = newSwitch("Include live recordings", gtk.callback(liveSwitched), self);
    radio.unplayed_switch = unplayed;
    radio.avoid_switch = avoid;
    radio.live_switch = live;
    const avoid_note = wrapped("Skips anything from the last 3 days", "radio-switch-note");
    radio.avoid_note = gtk.cast(gtk.Label, avoid_note);
    const group = vertical(12, "radio-panel-divided");
    append(group, &.{
        switchRow("Include tracks you've never played", wrapped("Up to 1 in 4 picks", "radio-switch-note"), unplayed),
        switchRow("Avoid recently played", avoid_note, avoid),
        switchRow("Include live recordings", null, live),
    });
    return group;
}

fn buildSession(self: *App) *gtk.Widget {
    const radio = &self.radio;
    const session = label(null, "radio-session");
    radio.session = gtk.cast(gtk.Label, session);
    const undo = gtk.gtk_button_new_with_label("Undo feedback");
    gtk.gtk_widget_add_css_class(undo, "radio-undo");
    gtk.gtk_widget_set_halign(undo, gtk.ALIGN_START);
    radio.undo = undo;
    _ = gtk.signalConnect(undo, "clicked", gtk.callback(undoClicked), self);
    const group = vertical(8, "radio-panel-divided");
    append(group, &.{ heading("This session"), session, undo });
    return group;
}

fn buildNotice(self: *App) *gtk.Widget {
    const radio = &self.radio;
    const box = vertical(8, "radio-info");
    gtk.gtk_widget_add_css_class(box, "radio-notice");
    const text = wrapped(null, "radio-info-text");
    const analyze = gtk.gtk_button_new_with_label("Analyze music");
    gtk.gtk_widget_add_css_class(analyze, "radio-undo");
    gtk.gtk_widget_set_halign(analyze, gtk.ALIGN_START);
    _ = gtk.signalConnect(analyze, "clicked", gtk.callback(analyzeClicked), self);
    append(box, &.{ text, analyze });
    gtk.gtk_widget_set_visible(box, gtk.false_);
    gtk.gtk_widget_set_visible(analyze, gtk.false_);
    radio.notice = box;
    radio.notice_text = gtk.cast(gtk.Label, text);
    radio.notice_analyze = analyze;
    return box;
}

fn buildInfo() *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(box, "radio-info");
    const icon = gtk.gtk_image_new_from_icon_name("orca-info-symbolic");
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_START);
    const text = wrapped(
        "Radio picks from your library using genre tags, ListenBrainz related artists, audio analysis (tempo, key, energy) and what you tend to play together. It runs on this computer.",
        "radio-info-text",
    );
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    append(box, &.{ icon, text });
    return box;
}

fn buildPanel(self: *App) *gtk.Widget {
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const title = label("Radio", "radio-panel-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const on_switch = newSwitch("Radio", gtk.callback(onSwitched), self);
    self.radio.on_switch = on_switch;
    append(header, &.{ title, on_switch });

    const column = vertical(20, "radio-panel");
    append(column, &.{ header, buildNotice(self), buildSeed(self), buildExplore(self), buildFocus(self), buildSwitches(self), buildSession(self), buildInfo() });
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_add_css_class(scroller, "radio-panel-frame");
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    return scroller;
}

/// Puts the Radio panel beside the Queue page's `view`.
pub fn wrap(self: *App, view: *gtk.Widget) *gtk.Widget {
    const split = adw.adw_overlay_split_view_new();
    const split_view = gtk.cast(adw.OverlaySplitView, split);
    adw.adw_overlay_split_view_set_sidebar_position(split_view, gtk.PACK_END);
    adw.adw_overlay_split_view_set_enable_show_gesture(split_view, gtk.false_);
    adw.adw_overlay_split_view_set_min_sidebar_width(split_view, 0);
    adw.adw_overlay_split_view_set_max_sidebar_width(split_view, @floatFromInt(page_ui.side_panel_width));
    adw.adw_overlay_split_view_set_show_sidebar(split_view, gtk.false_);
    adw.adw_overlay_split_view_set_content(split_view, view);
    adw.adw_overlay_split_view_set_sidebar(split_view, buildPanel(self));
    self.radio.split = split;
    self.radio.content = view;
    return split;
}

fn overlaid(self: *const App) bool {
    return self.window_narrow or self.header_compact or self.inspector_crowded or details.shownMode(self) != .hidden;
}

/// Docks the panel beside the Queue while Radio is on and the window has room;
/// otherwise the Queue's Radio options button shows it over the page.
pub fn placePanel(self: *App) void {
    const split = self.radio.split orelse return;
    const split_view = gtk.cast(adw.OverlaySplitView, split);
    const collapsed = overlaid(self);
    adw.adw_overlay_split_view_set_collapsed(split_view, boolean(collapsed));
    adw.adw_overlay_split_view_set_show_sidebar(split_view, boolean(isOn(self) and !collapsed));
    if (self.queue.options_button) |button| gtk.gtk_widget_set_visible(button, boolean(isOn(self) and collapsed));
    page_ui.fitToPage(self);
}

pub fn showOptions(self: *App) void {
    const split = self.radio.split orelse return;
    adw.adw_overlay_split_view_set_show_sidebar(gtk.cast(adw.OverlaySplitView, split), gtk.true_);
}

pub fn optionsOverlaid(self: *const App) bool {
    return isOn(self) and overlaid(self);
}

/// Whether the panel stands beside the Queue, reaching up under the top bar.
pub fn docked(self: *const App) bool {
    return self.radio.split != null and isOn(self) and !overlaid(self);
}

/// Keeps the Queue clear of the top bar while the docked panel reaches under it.
pub fn fitUnderBar(self: *App, height: c_int) void {
    const content = self.radio.content orelse return;
    gtk.gtk_widget_set_margin_top(content, height);
}
