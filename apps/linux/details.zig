//! The track details panel: what the library recorded about one Track and its
//! file, beside the Tracks list and beside an album's tracks.
//!
//! liborca answers `libraryTrackDetails`; this only words the answer. The
//! panels share one on/off state, kept on the `App`, and each queries only when
//! the Track it shows changes.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const signal_path = @import("signal_path.zig");
const track_model = @import("track_model.zig");

const App = app.App;
const TrackObject = track_model.TrackObject;

const panel_width: c_int = 300;
const separator = " · ";
const minus = "−";

pub const panel_limit = app.open_album_page_limit + 1;

/// Where a panel finds the Track it shows when nobody has chosen one.
pub const Source = union(enum) {
    /// The first selected row of the Tracks list.
    selection,
    /// An album page: the row last chosen, else the playing Track if it is one
    /// of these.
    ids: []const i64,
};

pub const Panel = struct {
    self: *App,
    source: Source,
    root: *gtk.Widget,
    toggle: *gtk.Widget,
    placeholder: *gtk.Widget,
    content: *gtk.Widget,
    title: *gtk.Widget,
    artist: *gtk.Widget,
    album: *gtk.Widget,
    format_group: *gtk.Widget,
    format_row: *gtk.Widget,
    duration_row: *gtk.Widget,
    file_group: *gtk.Widget,
    size_row: *gtk.Widget,
    path_row: *gtk.Widget,
    copy_button: *gtk.Widget,
    loudness_group: *gtk.Widget,
    loudness_row: *gtk.Widget,
    tags_group: *gtk.Widget,
    album_artist_row: *gtk.Widget,
    date_row: *gtk.Widget,
    track_row: *gtk.Widget,
    disc_row: *gtk.Widget,
    compilation_row: *gtk.Widget,
    now_group: *gtk.Widget,
    now_row: *gtk.Widget,
    /// The Track on screen, and whether that is stale since the library changed.
    shown: ?i64 = null,
    stale: bool = false,
    /// The playing Track the "Now Playing" section was read for.
    now_for: ?i64 = null,
    chosen: ?i64 = null,
    path: ?[:0]u8 = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn panelData(data: ?*anyopaque) *Panel {
    return @ptrCast(@alignCast(data.?));
}

// --------------------------------------------------------------- shared state

fn shownNow(self: *const App) bool {
    return self.details_visible and !self.window_narrow;
}

pub fn setNarrow(self: *App, narrow: bool) void {
    self.window_narrow = narrow;
    applyVisibility(self);
}

pub fn toggle(self: *App) void {
    setVisible(self, !self.details_visible);
}

fn setVisible(self: *App, visible: bool) void {
    self.details_visible = visible;
    applyVisibility(self);
    settings.save(self);
}

pub fn applyVisibility(self: *App) void {
    const on = shownNow(self);
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        gtk.gtk_widget_set_visible(panel.root, boolean(on));
        gtk.gtk_widget_set_visible(panel.toggle, boolean(!self.window_narrow));
        gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, panel.toggle), boolean(self.details_visible));
        update(panel);
    }
}

fn toggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const active = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
    if (active != self.details_visible) setVisible(self, active);
}

/// The library changed under the panels: what they show may no longer be true.
pub fn invalidate(self: *App) void {
    for (self.details_panels) |maybe| {
        const panel = maybe orelse continue;
        panel.stale = true;
        update(panel);
    }
}

/// The playing Track changed.
pub fn trackChanged(self: *App) void {
    for (self.details_panels) |maybe| update(maybe orelse continue);
}

pub fn selectionChanged(_: ?*anyopaque, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    for (state(data).details_panels) |maybe| {
        const panel = maybe orelse continue;
        if (panel.source == .selection) update(panel);
    }
}

pub fn choose(panel: *Panel, track_id: i64) void {
    panel.chosen = track_id;
    update(panel);
}

// -------------------------------------------------------------------- update

fn wantedTrack(panel: *Panel) ?i64 {
    const self = panel.self;
    switch (panel.source) {
        .selection => return firstSelectedTrack(self) orelse self.shown_track_id,
        .ids => |ids| {
            if (panel.chosen) |chosen| return chosen;
            const playing = self.shown_track_id orelse return null;
            for (ids) |id| if (id == playing) return playing;
            return null;
        },
    }
}

fn firstSelectedTrack(self: *App) ?i64 {
    const selection = self.selection orelse return null;
    const chosen = gtk.gtk_selection_model_get_selection(selection);
    defer gtk.gtk_bitset_unref(chosen);
    var iter: gtk.BitsetIter = .{};
    var index: c_uint = 0;
    if (gtk.gtk_bitset_iter_init_first(&iter, chosen, &index) == 0) return null;
    const item = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, selection), index) orelse return null;
    defer gtk.g_object_unref(item);
    const row: *TrackObject = @ptrCast(@alignCast(item));
    return row.id();
}

fn update(panel: *Panel) void {
    const self = panel.self;
    if (!shownNow(self)) return;
    const wanted = wantedTrack(panel);
    if (panel.stale or !optionalEql(wanted, panel.shown)) {
        panel.stale = false;
        panel.shown = wanted;
        panel.now_for = null;
        show(panel, wanted);
    }
    const playing_here: ?i64 = if (wanted != null and optionalEql(wanted, self.shown_track_id)) wanted else null;
    if (!optionalEql(playing_here, panel.now_for)) {
        panel.now_for = playing_here;
        showNow(panel, playing_here != null);
    }
}

fn show(panel: *Panel, track_id: ?i64) void {
    const self = panel.self;
    const library = self.library orelse return showPlaceholder(panel);
    const id = track_id orelse return showPlaceholder(panel);
    const details = (self.runtime.libraryTrackDetails(library, id) catch null) orelse
        return showPlaceholder(panel);
    defer details.deinit();
    populate(panel, details);
    gtk.gtk_widget_set_visible(panel.placeholder, gtk.false_);
    gtk.gtk_widget_set_visible(panel.content, gtk.true_);
}

fn showPlaceholder(panel: *Panel) void {
    gtk.gtk_widget_set_visible(panel.placeholder, gtk.true_);
    gtk.gtk_widget_set_visible(panel.content, gtk.false_);
    setPath(panel, null);
}

/// `playerSignalPath` pauses the engine briefly, so it is read when the shown or
/// playing Track changes and never from the tick.
fn showNow(panel: *Panel, playing: bool) void {
    gtk.gtk_widget_set_visible(panel.now_group, boolean(playing));
    if (!playing) return;
    const self = panel.self;
    var buffer: [1024]u8 = undefined;
    const text = if (self.runtime.playerSignalPath(self.player)) |path|
        signal_path.render(&buffer, path)
    else |_|
        "Signal path unavailable";
    _ = setRow(panel.now_row, text);
}

fn populate(panel: *Panel, details: liborca.TrackDetails) void {
    var buffer: [1024]u8 = undefined;

    setLabel(panel.title, if (details.title.len != 0) details.title else "Unknown title", &buffer);
    setLabel(panel.artist, details.artist, &buffer);
    setLabel(panel.album, details.album, &buffer);

    const format_visible = setRow(panel.format_row, formatSummary(&buffer, details));
    const duration_text: ?[:0]const u8 = if (details.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else null)
    else
        null;
    const duration_visible = setRow(panel.duration_row, duration_text);
    gtk.gtk_widget_set_visible(panel.format_group, boolean(format_visible or duration_visible));

    var size_buffer: [64]u8 = undefined;
    const size_text: ?[:0]const u8 = if (details.size_bytes) |bytes| sizeText(&size_buffer, bytes) else null;
    _ = setRow(panel.size_row, size_text);
    if (details.path) |path| {
        _ = setRow(panel.path_row, strings.terminated(&buffer, path));
        setPath(panel, path);
    } else {
        _ = setRow(panel.path_row, "File missing");
        setPath(panel, null);
    }
    gtk.gtk_widget_set_visible(panel.copy_button, boolean(panel.path != null));

    _ = setRow(panel.loudness_row, loudnessText(&buffer, details.loudness));

    var any_tag = false;
    any_tag = setRow(panel.album_artist_row, optionalText(&buffer, details.album_artist)) or any_tag;
    any_tag = setRow(panel.date_row, if (details.date) |date| optionalText(&buffer, date) else null) or any_tag;
    var track_buffer: [24]u8 = undefined;
    var disc_buffer: [24]u8 = undefined;
    any_tag = setRow(panel.track_row, numberText(&track_buffer, details.track_number)) or any_tag;
    any_tag = setRow(panel.disc_row, numberText(&disc_buffer, details.disc_number)) or any_tag;
    const compilation: ?[:0]const u8 = if (details.compilation) |flag| (if (flag) "Yes" else "No") else null;
    any_tag = setRow(panel.compilation_row, compilation) or any_tag;
    gtk.gtk_widget_set_visible(panel.tags_group, boolean(any_tag));
}

fn setPath(panel: *Panel, path: ?[]const u8) void {
    const allocator = panel.self.allocator;
    if (panel.path) |old| allocator.free(old);
    panel.path = if (path) |value| allocator.dupeZ(u8, value) catch null else null;
}

// ------------------------------------------------------------------ wording

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

fn numberText(buffer: []u8, value: ?i64) ?[:0]const u8 {
    const number = value orelse return null;
    return strings.printZ(buffer, "{d}", .{number}) catch null;
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

fn formatSummary(buffer: []u8, details: liborca.TrackDetails) ?[:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeSummary(&writer, details) catch {};
    if (writer.end == 0) return null;
    return finish(buffer, &writer);
}

fn writeSummary(writer: *std.Io.Writer, details: liborca.TrackDetails) std.Io.Writer.Error!void {
    var first = true;
    if (details.codec.len != 0) {
        try signal_path.writeCodecName(writer, details.codec);
        first = false;
    }
    if (!details.lossy) if (details.bit_depth) |depth| {
        if (!first) try writer.writeAll(separator);
        try writer.print("{d}-bit", .{depth});
        first = false;
    };
    if (details.sample_rate) |rate| {
        if (!first) try writer.writeAll(separator);
        try signal_path.writeRate(writer, rate);
        first = false;
    }
    if (details.channels) |channels| {
        if (!first) try writer.writeAll(separator);
        try writer.print("{d} ch", .{channels});
        first = false;
    }
    if (details.bitrate_kbps) |kbps| {
        if (!first) try writer.writeAll(separator);
        try writeGrouped(writer, kbps);
        try writer.writeAll(" kbps");
    }
}

fn writeGrouped(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return;
    for (text, 0..) |digit, index| {
        if (index != 0 and (text.len - index) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

fn loudnessText(buffer: []u8, loudness: ?liborca.TrackLoudness) [:0]const u8 {
    const measured = loudness orelse return "Not measured";
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeLoudness(&writer, measured) catch {};
    return finish(buffer, &writer);
}

fn writeLoudness(writer: *std.Io.Writer, loudness: liborca.TrackLoudness) std.Io.Writer.Error!void {
    try writeDecibels(writer, loudness.integrated_lufs, false);
    try writer.writeAll(" LUFS" ++ separator ++ "peak ");
    if (loudness.sample_peak > 0)
        try writeDecibels(writer, 20 * std.math.log10(loudness.sample_peak), true)
    else
        try writer.writeAll(minus ++ "∞");
    try writer.writeAll(" dBFS" ++ separator ++ "ReplayGain ");
    try writeDecibels(writer, loudness.replay_gain_db, true);
    try writer.writeAll(" dB");
}

fn writeDecibels(writer: *std.Io.Writer, value: f32, comptime signed: bool) std.Io.Writer.Error!void {
    const tenths = @round(value * 10) / 10;
    if (tenths == 0) return writer.writeAll("0.0");
    const sign: []const u8 = if (tenths < 0) minus else if (signed) "+" else "";
    try writer.print("{s}{d:.1}", .{ sign, @abs(tenths) });
}

// ------------------------------------------------------------------- widgets

fn setLabel(label: *gtk.Widget, text: []const u8, buffer: []u8) void {
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), strings.terminated(buffer, text).ptr);
    gtk.gtk_widget_set_visible(label, boolean(text.len != 0));
}

/// Shows `text` under the row's title, or hides the row when there is none.
fn setRow(row: *gtk.Widget, text: ?[:0]const u8) bool {
    const value = text orelse {
        gtk.gtk_widget_set_visible(row, gtk.false_);
        return false;
    };
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), value.ptr);
    gtk.gtk_widget_set_visible(row, gtk.true_);
    return true;
}

fn newRow(title: [*:0]const u8) *gtk.Widget {
    const row = adw.adw_action_row_new();
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title);
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, row), 0);
    gtk.gtk_widget_add_css_class(row, "property");
    return row;
}

fn newGroup(title: ?[*:0]const u8, rows: []const *gtk.Widget) *gtk.Widget {
    const group = adw.adw_preferences_group_new();
    if (title) |text| adw.adw_preferences_group_set_title(gtk.cast(adw.PreferencesGroup, group), text);
    for (rows) |row| adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, group), row);
    return group;
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

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const panel = panelData(data);
    const self = panel.self;
    for (&self.details_panels) |*slot| {
        if (slot.* == panel) slot.* = null;
    }
    setPath(panel, null);
    self.allocator.destroy(panel);
}

/// A panel and the header toggle that shows it. The caller places `root` beside
/// its content and `toggle` in its header bar.
pub fn newPanel(self: *App, source: Source) ?*Panel {
    const slot = for (&self.details_panels) |*candidate| {
        if (candidate.* == null) break candidate;
    } else return null;
    const panel = self.allocator.create(Panel) catch return null;

    const toggle_button = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, toggle_button), "sidebar-show-right-symbolic");
    gtk.gtk_widget_set_tooltip_text(toggle_button, "Track Details");
    _ = gtk.signalConnect(toggle_button, "toggled", gtk.callback(toggled), self);

    const title = newLabel("details-title");
    const artist = newLabel(null);
    const album = newLabel("dim-label");
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    for ([_]*gtk.Widget{ title, artist, album }) |label| gtk.gtk_box_append(gtk.cast(gtk.Box, heading), label);

    const format_row = newRow("Format");
    const duration_row = newRow("Duration");
    const size_row = newRow("Size");
    const path_row = newRow("Path");
    const copy_button = gtk.gtk_button_new_from_icon_name("edit-copy-symbolic");
    gtk.gtk_widget_set_valign(copy_button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(copy_button, "flat");
    gtk.gtk_widget_set_tooltip_text(copy_button, "Copy path");
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, path_row), copy_button);
    const loudness_row = newRow("Loudness");
    const album_artist_row = newRow("Album artist");
    const date_row = newRow("Date");
    const track_row = newRow("Track");
    const disc_row = newRow("Disc");
    const compilation_row = newRow("Compilation");
    const now_row = newRow("Signal path");

    const format_group = newGroup("Format", &.{ format_row, duration_row });
    const file_group = newGroup("File", &.{ size_row, path_row });
    const loudness_group = newGroup("Loudness", &.{loudness_row});
    const tags_group = newGroup("Tags", &.{ album_artist_row, date_row, track_row, disc_row, compilation_row });
    const now_group = newGroup("Now Playing", &.{now_row});
    gtk.gtk_widget_set_visible(now_group, gtk.false_);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_visible(content, gtk.false_);
    for ([_]*gtk.Widget{ heading, format_group, file_group, loudness_group, tags_group, now_group }) |section|
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), section);

    const placeholder = gtk.gtk_label_new("Select a track to see its details.");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, placeholder), gtk.true_);
    gtk.gtk_widget_add_css_class(placeholder, "dim-label");
    gtk.gtk_widget_set_margin_top(placeholder, 24);

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "details-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), placeholder);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), content);

    const root = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_add_css_class(root, "details-panel");
    gtk.gtk_widget_set_size_request(root, panel_width, -1);
    gtk.gtk_widget_set_hexpand(root, gtk.false_);
    gtk.gtk_widget_set_vexpand(root, gtk.true_);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, root), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, root), body);

    panel.* = .{
        .self = self,
        .source = source,
        .root = root,
        .toggle = toggle_button,
        .placeholder = placeholder,
        .content = content,
        .title = title,
        .artist = artist,
        .album = album,
        .format_group = format_group,
        .format_row = format_row,
        .duration_row = duration_row,
        .file_group = file_group,
        .size_row = size_row,
        .path_row = path_row,
        .copy_button = copy_button,
        .loudness_group = loudness_group,
        .loudness_row = loudness_row,
        .tags_group = tags_group,
        .album_artist_row = album_artist_row,
        .date_row = date_row,
        .track_row = track_row,
        .disc_row = disc_row,
        .compilation_row = compilation_row,
        .now_group = now_group,
        .now_row = now_row,
    };
    _ = gtk.signalConnect(copy_button, "clicked", gtk.callback(copyClicked), panel);
    _ = gtk.signalConnect(root, "destroy", gtk.callback(destroyed), panel);
    slot.* = panel;

    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle_button), boolean(self.details_visible));
    gtk.gtk_widget_set_visible(toggle_button, boolean(!self.window_narrow));
    gtk.gtk_widget_set_visible(root, boolean(shownNow(self)));
    update(panel);
    return panel;
}

pub const Placed = struct {
    widget: *gtk.Widget,
    panel: ?*Panel,
};

/// `content` with a details panel on its right, and the panel's toggle at the
/// end of `header`. Without a free panel slot, `content` alone.
pub fn besideContent(self: *App, header: *gtk.Widget, content: *gtk.Widget, source: Source) Placed {
    const panel = newPanel(self, source) orelse return .{ .widget = content, .panel = null };
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), panel.toggle);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(content, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), content);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), panel.root);
    return .{ .widget = row, .panel = panel };
}
