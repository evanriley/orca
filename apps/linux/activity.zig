//! The Activity page, the activity widget at the foot of the sidebar and the
//! popover it opens: the open Library's running and waiting Jobs, and the
//! Jobs it has finished. Everything shown is read from `jobQueuePage`, each
//! Job's snapshot, `libraryJobsPaused` and `jobHistoryPage`; pausing,
//! cancelling, undoing and retrying are the runtime's.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const jobs = @import("jobs.zig");
const tags = @import("tags.zig");

const App = app.App;

pub const max_cards = liborca.max_waiting_jobs + 1;
const history_page: u32 = 100;
const recent_count: u32 = 3;

const Entry = struct {
    queued: liborca.QueuedJob,
    snapshot: liborca.JobSnapshot,

    fn waiting(self: Entry) bool {
        return self.snapshot.state == .waiting or self.snapshot.state == .queued;
    }
};

const Card = struct {
    job: liborca.JobHandle,
    waiting: bool,
    title: *gtk.Label,
    subtitle: *gtk.Label,
    percent: ?*gtk.Label,
    eta: ?*gtk.Label,
    bar: ?*gtk.ProgressBar,
    pause: ?*gtk.Widget,
};

pub const State = struct {
    widget: ?*gtk.Revealer = null,
    summary: ?*gtk.Label = null,
    percent: ?*gtk.Label = null,
    bar: ?*gtk.ProgressBar = null,
    popover: ?*gtk.Popover = null,
    running_label: ?*gtk.Widget = null,
    running: ?*gtk.Box = null,
    waiting_label: ?*gtk.Widget = null,
    waiting: ?*gtk.Box = null,
    recent_label: ?*gtk.Widget = null,
    recent: ?*gtk.Box = null,
    popover_pause: ?*gtk.Button = null,
    page_pause_icon: ?*gtk.Image = null,
    page_pause_label: ?*gtk.Label = null,
    now: ?*gtk.Box = null,
    now_empty: ?*gtk.Widget = null,
    history: ?*gtk.Box = null,
    history_more: ?*gtk.Widget = null,
    history_empty: ?*gtk.Widget = null,
    filter: liborca.JobHistoryFilter = .all,
    history_limit: u32 = history_page,
    history_entries: []liborca.JobHistoryEntry = &.{},
    page_cards: [max_cards]Card = undefined,
    page_card_count: usize = 0,
    popover_cards: [max_cards]Card = undefined,
    popover_card_count: usize = 0,
    signature: [max_cards]Shown = undefined,
    signature_count: usize = 0,
    built: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.history_entries);
        self.history_entries = &.{};
    }
};

const Shown = struct { job: liborca.JobHandle, waiting: bool };

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn boolean(value: bool) gtk.gboolean {
    return if (value) gtk.true_ else gtk.false_;
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    return widget;
}

fn icon(name: [*:0]const u8, pixels: c_int) *gtk.Widget {
    const image = gtk.gtk_image_new_from_icon_name(name);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), pixels);
    return image;
}

fn append(box: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

fn clear(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn iconButton(name: [*:0]const u8, pixels: c_int, class: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), icon(name, pixels));
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, class);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    return button;
}

fn setIconButton(button: *gtk.Widget, name: [*:0]const u8, tooltip: [*:0]const u8) void {
    if (gtk.gtk_widget_get_first_child(button)) |image| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, image), name);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
}

fn textButton(icon_name: ?[*:0]const u8, pixels: c_int, text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 7);
    if (icon_name) |name| gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon(name, pixels));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(text));
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, class);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

fn tile(kind: liborca.JobKind, class: [*:0]const u8, pixels: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, class);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(box, gtk.false_);
    const image = icon(kindIcon(kind), pixels);
    gtk.gtk_widget_set_halign(image, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(image, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_vexpand(image, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), image);
    return box;
}

fn kindIcon(kind: liborca.JobKind) [*:0]const u8 {
    return switch (kind) {
        .analysis => "orca-gain-symbolic",
        .metadata_lookup, .acoustid_submission => "orca-matches-symbolic",
        .mutation => "orca-pen-symbolic",
        .duplicate_scan, .consistency => "orca-health-symbolic",
        .release_info => "orca-genres-symbolic",
        .artwork => "orca-image-symbolic",
        .lyrics => "orca-tracks-symbolic",
        .artist_info => "orca-artists-symbolic",
        .scan, .reconcile, .projection, .property_backfill, .conversion, .ripping, .dummy => "orca-folders-symbolic",
    };
}

fn taskTitle(buffer: []u8, kind: liborca.JobKind, total: ?u64, waiting: bool) [:0]const u8 {
    return switch (kind) {
        .scan => if (waiting) "Scan your music" else "Scanning your music",
        .reconcile => if (waiting) "Scan a folder" else "Scanning a folder",
        .projection => if (waiting) "Update the library" else "Updating the library",
        .property_backfill => if (waiting) "Read file properties" else "Reading file properties",
        .analysis => if (waiting) "Analyze loudness" else "Analyzing loudness",
        .duplicate_scan => if (waiting) "Find duplicates" else "Finding duplicates",
        .consistency => if (waiting) "Check metadata" else "Checking metadata",
        .metadata_lookup => if (waiting) "Match with MusicBrainz" else "Matching with MusicBrainz",
        .acoustid_submission => if (waiting) "Submit to AcoustID" else "Submitting to AcoustID",
        .mutation => if (total) |files| strings.format(buffer, "{s} tags to {f} {s}", .{
            if (waiting) "Write" else "Writing",
            strings.grouped(files),
            if (files == 1) "file" else "files",
        }) else if (waiting) "Write tags" else "Writing tags",
        .release_info => if (waiting) "Fill in genres" else "Filling in genres",
        .artwork => if (waiting) "Fetch cover art" else "Fetching cover art",
        .lyrics => if (waiting) "Fetch lyrics" else "Fetching lyrics",
        .artist_info => if (waiting) "Fetch artist information" else "Fetching artist information",
        .conversion => if (waiting) "Convert" else "Converting",
        .ripping => if (waiting) "Rip a CD" else "Ripping a CD",
        .dummy => if (waiting) "Work" else "Working",
    };
}

fn kindNoun(kind: liborca.JobKind) []const u8 {
    return switch (kind) {
        .scan => "the library scan",
        .reconcile => "the folder scan",
        .projection => "the library update",
        .property_backfill => "reading file properties",
        .analysis => "loudness analysis",
        .duplicate_scan => "the duplicate search",
        .consistency => "the metadata check",
        .metadata_lookup => "MusicBrainz matching",
        .acoustid_submission => "the AcoustID submission",
        .mutation => "the tag write",
        .release_info => "the genre fill",
        .artwork => "the cover art fetch",
        .lyrics => "the lyrics fetch",
        .artist_info => "the artist fetch",
        .conversion => "the conversion",
        .ripping => "the CD rip",
        .dummy => "the current task",
    };
}

fn historyName(kind: liborca.JobKind) []const u8 {
    return switch (kind) {
        .scan => "Library scan",
        .reconcile => "Folder scan",
        .projection => "Library update",
        .property_backfill => "File properties",
        .analysis => "Loudness analysis",
        .duplicate_scan => "Duplicate search",
        .consistency => "Metadata check",
        .metadata_lookup => "MusicBrainz matching",
        .acoustid_submission => "AcoustID submission",
        .mutation => "Tag write",
        .release_info => "Genre fill",
        .artwork => "Cover art fetch",
        .lyrics => "Lyrics fetch",
        .artist_info => "Artist fetch",
        .conversion => "Conversion",
        .ripping => "CD rip",
        .dummy => "Task",
    };
}

fn unitName(kind: liborca.JobKind, count: u64) []const u8 {
    const plural: []const u8 = switch (kind) {
        .metadata_lookup, .projection, .ripping, .lyrics => "tracks",
        .release_info, .consistency => "releases",
        .artist_info => "artists",
        .artwork => "covers",
        .dummy => "items",
        .scan, .reconcile, .property_backfill, .analysis, .duplicate_scan, .acoustid_submission, .mutation, .conversion => "files",
    };
    return if (count == 1) plural[0 .. plural.len - 1] else plural;
}

fn progressText(buffer: []u8, snapshot: liborca.JobSnapshot, with_detail: bool) [:0]const u8 {
    const detail = snapshot.detail.slice();
    const separator: []const u8 = if (with_detail and detail.len != 0) " · " else "";
    const shown_detail = if (with_detail) detail else "";
    if (snapshot.total_units) |total| return strings.format(buffer, "{f} of {f} {s}{s}{s}", .{
        strings.grouped(@min(snapshot.completed_units, total)),
        strings.grouped(total),
        unitName(snapshot.kind, total),
        separator,
        shown_detail,
    });
    return strings.format(buffer, "{f} {s}{s}{s}", .{
        strings.grouped(snapshot.completed_units),
        unitName(snapshot.kind, snapshot.completed_units),
        separator,
        shown_detail,
    });
}

fn fraction(snapshot: liborca.JobSnapshot) ?f64 {
    const total = snapshot.total_units orelse return null;
    if (total == 0) return null;
    const done = @min(snapshot.completed_units, total);
    return @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total));
}

fn percentText(buffer: []u8, snapshot: liborca.JobSnapshot) [:0]const u8 {
    const total = snapshot.total_units orelse return "";
    if (total == 0) return "";
    return strings.format(buffer, "{d}%", .{@min(snapshot.completed_units, total) * 100 / total});
}

fn etaText(buffer: []u8, remaining_ms: ?u64, long: bool) [:0]const u8 {
    const value = remaining_ms orelse return "";
    if (value < std.time.ms_per_min) return if (long) "less than a minute" else "<1 min";
    const minutes = (value + std.time.ms_per_min - 1) / std.time.ms_per_min;
    const prefix: []const u8 = if (long) "about " else "";
    if (minutes < 60) return strings.format(buffer, "{s}{d} min", .{ prefix, minutes });
    return strings.format(buffer, "{s}{d} hr {d} min", .{ prefix, minutes / 60, minutes % 60 });
}

fn afterKind(entries: []const Entry, after: ?liborca.JobHandle) ?liborca.JobKind {
    const job = after orelse return null;
    for (entries) |entry| {
        if (entry.queued.job.eql(job)) return entry.snapshot.kind;
    }
    return null;
}

fn waitingText(buffer: []u8, entries: []const Entry, entry: Entry, paused: bool, long: bool) [:0]const u8 {
    if (paused) return if (long) "Waiting · paused" else "Paused";
    const kind = afterKind(entries, entry.queued.after) orelse
        return if (long) "Waiting · starts shortly" else "Starts shortly";
    return if (long)
        strings.format(buffer, "Waiting · starts after {s}", .{kindNoun(kind)})
    else
        strings.format(buffer, "Starts when {s} finishes", .{kindNoun(kind)});
}

fn capitalized(buffer: []u8, text: []const u8) []const u8 {
    if (text.len == 0) return text;
    const length = @min(text.len, buffer.len);
    @memcpy(buffer[0..length], text[0..length]);
    buffer[0] = std.ascii.toUpper(buffer[0]);
    return buffer[0..length];
}

fn historyTitle(buffer: []u8, entry: *const liborca.JobHistoryEntry, recent: bool) [:0]const u8 {
    switch (entry.state) {
        .succeeded => {},
        .cancelled => return strings.format(buffer, "{s} stopped", .{historyName(entry.kind)}),
        else => return strings.format(buffer, "{s} failed", .{historyName(entry.kind)}),
    }
    if (entry.kind == .mutation) return strings.format(buffer, "Wrote tags to {f} {s}", .{
        strings.grouped(entry.completed_units),
        if (entry.completed_units == 1) "file" else "files",
    });
    if (!recent) return strings.format(buffer, "{s}", .{historyName(entry.kind)});
    if (entry.kind == .scan) return "Scan finished";
    return strings.format(buffer, "{s} finished", .{historyName(entry.kind)});
}

fn historyDetail(buffer: []u8, entry: *const liborca.JobHistoryEntry) []const u8 {
    const summary = entry.summary.slice();
    const reason = entry.error_text.slice();
    const generic = std.mem.eql(u8, reason, "cancelled") or std.mem.eql(u8, reason, "failed");
    if (entry.state == .succeeded or reason.len == 0 or generic) return summary;
    const phrase = capitalized(buffer, reason);
    if (summary.len == 0) return phrase;
    var tail = std.Io.Writer.fixed(buffer[phrase.len..]);
    tail.print(" · {s}", .{summary}) catch {};
    return buffer[0 .. phrase.len + tail.end];
}

fn durationText(buffer: []u8, entry: *const liborca.JobHistoryEntry) [:0]const u8 {
    if (entry.state != .succeeded) return "—";
    const seconds: u64 = @intCast(@max(entry.finished_at - entry.started_at, 0));
    if (seconds == 0) return "instant";
    if (seconds < 60) return strings.format(buffer, "{d} s", .{seconds});
    const minutes = seconds / 60;
    if (minutes < 60) {
        if (seconds % 60 == 0) return strings.format(buffer, "{d} min", .{minutes});
        return strings.format(buffer, "{d} min {d} s", .{ minutes, seconds % 60 });
    }
    return strings.format(buffer, "{d} hr {d} min", .{ minutes / 60, minutes % 60 });
}

pub fn agoText(buffer: []u8, now_s: i64, then_s: i64) [:0]const u8 {
    const minutes: u64 = @intCast(@divFloor(@max(now_s - then_s, 0), 60));
    if (minutes < 1) return "just now";
    if (minutes < 60) return strings.format(buffer, "{d} min ago", .{minutes});
    const hours = minutes / 60;
    if (hours < 24) return strings.format(buffer, "{d} hr ago", .{hours});
    const days = hours / 24;
    return strings.format(buffer, "{d} {s} ago", .{ days, if (days == 1) "day" else "days" });
}

fn nowSeconds(self: *App) i64 {
    return std.Io.Clock.real.now(self.io).toSeconds();
}

/// `pattern` applied to `unix_seconds` in local time, or empty.
pub fn localTime(buffer: []u8, unix_seconds: i64, pattern: [*:0]const u8) [:0]const u8 {
    const moment = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return "";
    defer gtk.g_date_time_unref(moment);
    const text = gtk.g_date_time_format(moment, pattern) orelse return "";
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

fn dayKey(buffer: []u8, moment: *gtk.GDateTime) []const u8 {
    const text = gtk.g_date_time_format(moment, "%F") orelse return "";
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

fn dayLabel(buffer: []u8, unix_seconds: i64) [:0]const u8 {
    const now = gtk.g_date_time_new_now_local() orelse return "";
    defer gtk.g_date_time_unref(now);
    var day_buffer: [16]u8 = undefined;
    var other_buffer: [16]u8 = undefined;
    const day = localTime(&day_buffer, unix_seconds, "%F");
    if (std.mem.eql(u8, day, dayKey(&other_buffer, now))) return "Today";
    if (gtk.g_date_time_add_days(now, -1)) |yesterday| {
        defer gtk.g_date_time_unref(yesterday);
        if (std.mem.eql(u8, day, dayKey(&other_buffer, yesterday))) return "Yesterday";
    }
    return localTime(buffer, unix_seconds, "%-d %B %Y");
}

fn viewAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.activity.popover) |popover| gtk.gtk_popover_popdown(popover);
    window.goTo(self, .activity);
}

fn pauseAllClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const paused = self.runtime.libraryJobsPaused(library) catch return;
    (if (paused) self.runtime.resumeAll(library) else self.runtime.pauseAll(library)) catch
        return self.toast(if (paused) "Could not resume the tasks" else "Could not pause the tasks");
    refresh(self);
    self.requestTick();
}

fn popoverShown(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    reloadRecent(self);
    refresh(self);
}

fn popoverSection(text: [*:0]const u8) *gtk.Widget {
    const widget = label(text, "section-label");
    gtk.gtk_widget_add_css_class(widget, "activity-popover-section");
    return widget;
}

fn buildPopover(self: *App) *gtk.Widget {
    const title = label("Activity", "activity-popover-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const view_all_content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    append(view_all_content, &.{ gtk.gtk_label_new("View all"), icon("orca-chevron-right-symbolic", 13) });
    const view_all = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, view_all), view_all_content);
    gtk.gtk_widget_add_css_class(view_all, "flat");
    gtk.gtk_widget_add_css_class(view_all, "activity-view-all");
    _ = gtk.signalConnect(view_all, "clicked", gtk.callback(viewAllClicked), self);
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(header, "activity-popover-header");
    append(header, &.{ title, view_all });

    const running_label = popoverSection("Running");
    const running = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    const waiting_label = popoverSection("Waiting");
    const waiting = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    const recent_label = popoverSection("Recently finished");
    const recent = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    self.activity.running_label = running_label;
    self.activity.running = gtk.cast(gtk.Box, running);
    self.activity.waiting_label = waiting_label;
    self.activity.waiting = gtk.cast(gtk.Box, waiting);
    self.activity.recent_label = recent_label;
    self.activity.recent = gtk.cast(gtk.Box, recent);
    const sections = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(sections, "activity-popover-sections");
    append(sections, &.{ running_label, running, waiting_label, waiting, recent_label, recent });
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 520);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), sections);

    const pause = gtk.gtk_button_new_with_label("Pause all");
    gtk.gtk_widget_add_css_class(pause, "flat");
    gtk.gtk_widget_add_css_class(pause, "activity-footer-button");
    _ = gtk.signalConnect(pause, "clicked", gtk.callback(pauseAllClicked), self);
    self.activity.popover_pause = gtk.cast(gtk.Button, pause);
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const history = gtk.gtk_button_new_with_label("Change history");
    gtk.gtk_widget_add_css_class(history, "flat");
    gtk.gtk_widget_add_css_class(history, "activity-footer-button");
    _ = gtk.signalConnect(history, "clicked", gtk.callback(popoverHistoryClicked), self);
    const footer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(footer, "activity-popover-footer");
    append(footer, &.{ pause, spacer, history });

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(content, 380, -1);
    append(content, &.{ header, scroller, footer });
    const popover = gtk.gtk_popover_new();
    self.activity.popover = gtk.cast(gtk.Popover, popover);
    gtk.gtk_popover_set_child(self.activity.popover.?, content);
    gtk.gtk_popover_set_has_arrow(self.activity.popover.?, gtk.false_);
    gtk.gtk_popover_set_position(self.activity.popover.?, gtk.POS_TOP);
    gtk.gtk_popover_set_offset(self.activity.popover.?, 0, -12);
    gtk.gtk_widget_set_halign(popover, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(popover, "activity-popover");
    _ = gtk.signalConnect(popover, "show", gtk.callback(popoverShown), self);
    return popover;
}

/// The widget at the foot of the sidebar, shown while a Job runs or waits.
pub fn buildWidget(self: *App) *gtk.Widget {
    const summary = label("", "activity-summary");
    self.activity.summary = gtk.cast(gtk.Label, summary);
    gtk.gtk_widget_set_hexpand(summary, gtk.true_);
    const percent = gtk.gtk_label_new("");
    self.activity.percent = gtk.cast(gtk.Label, percent);
    gtk.gtk_widget_add_css_class(percent, "numeric");
    gtk.gtk_widget_add_css_class(percent, "activity-percent");
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    append(line, &.{ summary, percent });
    const bar = gtk.gtk_progress_bar_new();
    self.activity.bar = gtk.cast(gtk.ProgressBar, bar);
    gtk.gtk_progress_bar_set_pulse_step(self.activity.bar.?, 0.08);
    gtk.gtk_widget_add_css_class(bar, "activity-bar");
    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 7);
    append(body, &.{ line, bar });
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), body);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), buildPopover(self));
    gtk.gtk_widget_set_tooltip_text(button, "Show activity");
    gtk.gtk_widget_add_css_class(button, "activity");

    const revealer = gtk.gtk_revealer_new();
    self.activity.widget = gtk.cast(gtk.Revealer, revealer);
    gtk.gtk_revealer_set_transition_type(self.activity.widget.?, gtk.REVEALER_TRANSITION_SLIDE_UP);
    gtk.gtk_revealer_set_child(self.activity.widget.?, button);
    return revealer;
}

fn cardIndex(button: ?*anyopaque) ?usize {
    const tagged = gtk.g_object_get_data(button.?, "orca-card") orelse return null;
    return @intFromPtr(tagged) - 1;
}

fn cardJob(self: *App, button: ?*anyopaque) ?liborca.JobHandle {
    const index = cardIndex(button) orelse return null;
    const in_popover = gtk.g_object_get_data(button.?, "orca-popover") != null;
    const count = if (in_popover) self.activity.popover_card_count else self.activity.page_card_count;
    if (index >= count) return null;
    return if (in_popover) self.activity.popover_cards[index].job else self.activity.page_cards[index].job;
}

fn pauseClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const job = cardJob(self, button) orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch return;
    if (snapshot.paused) {
        self.runtime.resumeJob(job) catch return self.toast("Could not resume the task");
    } else {
        self.runtime.pauseJob(job) catch |err| return self.toast(switch (err) {
            error.JobNotPausable => "This task cannot be paused",
            error.JobAlreadyFinished => "This task has already finished",
            else => "Could not pause the task",
        });
    }
    refresh(self);
    self.requestTick();
}

fn cancelClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const job = cardJob(self, button) orelse return;
    self.runtime.cancelJob(job) catch return;
    refresh(self);
    self.requestTick();
}

fn tagButton(self: *App, button: *gtk.Widget, index: usize, in_popover: bool, handler: gtk.GCallback) void {
    gtk.g_object_set_data(button, "orca-card", @ptrFromInt(index + 1));
    if (in_popover) gtk.g_object_set_data(button, "orca-popover", @ptrFromInt(1));
    _ = gtk.signalConnect(button, "clicked", handler, self);
}

fn progressBar(class: [*:0]const u8) *gtk.ProgressBar {
    const bar = gtk.gtk_progress_bar_new();
    gtk.gtk_progress_bar_set_pulse_step(gtk.cast(gtk.ProgressBar, bar), 0.08);
    gtk.gtk_widget_add_css_class(bar, class);
    return gtk.cast(gtk.ProgressBar, bar);
}

fn pageCard(self: *App, entry: Entry, index: usize) *gtk.Widget {
    const waiting = entry.waiting();
    const title = label("", "activity-card-title");
    const subtitle = label("", "activity-card-subtitle");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ title, subtitle });

    const percent = label("", "activity-card-percent");
    gtk.gtk_widget_add_css_class(percent, "numeric");
    gtk.gtk_widget_set_hexpand(percent, gtk.true_);
    const eta = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(eta, "activity-card-eta");
    gtk.gtk_widget_add_css_class(eta, "numeric");
    const numbers = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    append(numbers, &.{ percent, eta });
    const bar = progressBar("activity-card-bar");
    const progress = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_size_request(progress, 180, -1);
    gtk.gtk_widget_set_hexpand(progress, gtk.false_);
    gtk.gtk_widget_set_valign(progress, gtk.ALIGN_CENTER);
    append(progress, &.{ numbers, gtk.cast(gtk.Widget, bar) });

    const pause = iconButton("orca-pause-symbolic", 16, "activity-card-button", "Pause");
    tagButton(self, pause, index, false, gtk.callback(pauseClicked));
    const pause_slot = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_size_request(pause_slot, 34, 34);
    gtk.gtk_widget_set_valign(pause_slot, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, pause_slot), pause);
    gtk.gtk_widget_set_visible(pause, boolean(!waiting));
    const cancel = iconButton("orca-close-symbolic", 15, "activity-card-button", if (waiting) "Remove from the queue" else "Stop");
    tagButton(self, cancel, index, false, gtk.callback(cancelClicked));
    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    append(buttons, &.{ pause_slot, cancel });

    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(card, "activity-card");
    gtk.gtk_widget_add_css_class(card, if (waiting) "waiting" else "running");
    append(card, &.{ tile(entry.snapshot.kind, "activity-card-tile", 17), text, progress, buttons });
    self.activity.page_cards[index] = .{
        .job = entry.queued.job,
        .waiting = waiting,
        .title = gtk.cast(gtk.Label, title),
        .subtitle = gtk.cast(gtk.Label, subtitle),
        .percent = gtk.cast(gtk.Label, percent),
        .eta = gtk.cast(gtk.Label, eta),
        .bar = bar,
        .pause = pause,
    };
    return card;
}

fn popoverCard(self: *App, entry: Entry, index: usize) *gtk.Widget {
    const waiting = entry.waiting();
    const title = label("", "activity-row-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    const subtitle = label("", "activity-row-subtitle");
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, if (waiting) 2 else 5);
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_CENTER);
    var eta: ?*gtk.Label = null;
    var bar: ?*gtk.ProgressBar = null;
    var pause: ?*gtk.Widget = null;
    if (waiting) {
        append(column, &.{ title, subtitle });
    } else {
        const eta_label = gtk.gtk_label_new("");
        gtk.gtk_widget_add_css_class(eta_label, "activity-row-eta");
        gtk.gtk_widget_add_css_class(eta_label, "numeric");
        const top = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
        append(top, &.{ title, eta_label });
        const progress = progressBar("activity-bar");
        append(column, &.{ top, gtk.cast(gtk.Widget, progress), subtitle });
        eta = gtk.cast(gtk.Label, eta_label);
        bar = progress;
        const button = iconButton("orca-pause-symbolic", 15, "activity-row-button", "Pause");
        tagButton(self, button, index, true, gtk.callback(pauseClicked));
        pause = button;
    }
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "activity-row");
    gtk.gtk_widget_add_css_class(row, if (waiting) "waiting" else "running");
    append(row, &.{ tile(entry.snapshot.kind, "activity-row-tile", 16), column });
    if (pause) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
    self.activity.popover_cards[index] = .{
        .job = entry.queued.job,
        .waiting = waiting,
        .title = gtk.cast(gtk.Label, title),
        .subtitle = gtk.cast(gtk.Label, subtitle),
        .percent = null,
        .eta = eta,
        .bar = bar,
        .pause = pause,
    };
    return row;
}

fn rebuild(self: *App, entries: []const Entry) void {
    const activity = &self.activity;
    if (activity.now) |now| clear(now);
    if (activity.running) |box| clear(box);
    if (activity.waiting) |box| clear(box);
    activity.page_card_count = 0;
    activity.popover_card_count = 0;
    for (entries, 0..) |entry, index| {
        if (activity.now) |now| {
            gtk.gtk_box_append(now, pageCard(self, entry, index));
            activity.page_card_count = index + 1;
        }
        const box = (if (entry.waiting()) activity.waiting else activity.running) orelse continue;
        gtk.gtk_box_append(box, popoverCard(self, entry, index));
        activity.popover_card_count = index + 1;
    }
    for (entries, 0..) |entry, index| activity.signature[index] = .{ .job = entry.queued.job, .waiting = entry.waiting() };
    activity.signature_count = entries.len;
}

fn changed(self: *App, entries: []const Entry) bool {
    const activity = &self.activity;
    if (!activity.built or activity.signature_count != entries.len) return true;
    for (entries, activity.signature[0..entries.len]) |entry, known| {
        if (!entry.queued.job.eql(known.job) or entry.waiting() != known.waiting) return true;
    }
    return false;
}

fn showCard(card: Card, entries: []const Entry, entry: Entry, library_paused: bool, on_page: bool) void {
    var title_buffer: [128]u8 = undefined;
    var text_buffer: [320]u8 = undefined;
    const snapshot = entry.snapshot;
    gtk.gtk_label_set_text(card.title, taskTitle(&title_buffer, snapshot.kind, snapshot.total_units, card.waiting).ptr);
    if (card.waiting) {
        gtk.gtk_label_set_text(card.subtitle, waitingText(&text_buffer, entries, entry, library_paused or snapshot.paused, on_page).ptr);
        if (card.percent) |percent| gtk.gtk_label_set_text(percent, "Queued");
        if (card.eta) |eta| gtk.gtk_label_set_text(eta, "");
        if (card.bar) |bar| gtk.gtk_progress_bar_set_fraction(bar, 0);
        return;
    }
    gtk.gtk_label_set_text(card.subtitle, progressText(&text_buffer, snapshot, on_page).ptr);
    var percent_buffer: [8]u8 = undefined;
    if (card.percent) |percent| gtk.gtk_label_set_text(percent, percentText(&percent_buffer, snapshot).ptr);
    var eta_buffer: [32]u8 = undefined;
    if (card.eta) |eta| gtk.gtk_label_set_text(eta, if (snapshot.paused)
        "Paused"
    else if (snapshot.state == .cancelling)
        "Stopping…"
    else
        etaText(&eta_buffer, snapshot.estimated_remaining_ms, on_page).ptr);
    if (card.bar) |bar| {
        if (fraction(snapshot)) |value|
            gtk.gtk_progress_bar_set_fraction(bar, value)
        else if (!snapshot.paused)
            gtk.gtk_progress_bar_pulse(bar);
    }
    if (card.pause) |button| setIconButton(
        button,
        if (snapshot.paused) "orca-play-symbolic" else "orca-pause-symbolic",
        if (snapshot.paused) "Resume" else "Pause",
    );
}

fn showWidget(self: *App, entries: []const Entry, library_paused: bool) void {
    const activity = &self.activity;
    var running: usize = 0;
    var waiting: usize = 0;
    var running_paused: usize = 0;
    var lead: ?liborca.JobSnapshot = null;
    for (entries) |entry| {
        if (entry.waiting()) {
            waiting += 1;
            continue;
        }
        running += 1;
        if (entry.snapshot.paused) running_paused += 1;
        if (lead == null) lead = entry.snapshot;
    }
    const visible = running + waiting != 0;
    if (!visible) if (activity.popover) |popover| gtk.gtk_popover_popdown(popover);
    if (activity.widget) |revealer| gtk.gtk_revealer_set_reveal_child(revealer, boolean(visible));
    if (!visible) return;
    const paused = library_paused or (running != 0 and running_paused == running);
    var buffer: [64]u8 = undefined;
    const text: [:0]const u8 = if (paused)
        (if (waiting == 0) "Paused" else strings.format(&buffer, "Paused · {d} waiting", .{waiting}))
    else if (running == 0)
        strings.format(&buffer, "{d} {s} waiting", .{ waiting, if (waiting == 1) "task" else "tasks" })
    else if (running == 1 and waiting == 0 and lead.?.kind == .scan)
        "Scanning library"
    else if (waiting == 0)
        strings.format(&buffer, "{d} {s} running", .{ running, if (running == 1) "task" else "tasks" })
    else
        strings.format(&buffer, "{d} {s} running · {d} waiting", .{ running, if (running == 1) "task" else "tasks", waiting });
    if (activity.summary) |summary| gtk.gtk_label_set_text(summary, text.ptr);
    var percent_buffer: [8]u8 = undefined;
    const snapshot = lead orelse {
        if (activity.percent) |percent| gtk.gtk_label_set_text(percent, "");
        if (activity.bar) |bar| gtk.gtk_progress_bar_set_fraction(bar, 0);
        return;
    };
    if (activity.percent) |percent| gtk.gtk_label_set_text(percent, percentText(&percent_buffer, snapshot).ptr);
    if (activity.bar) |bar| {
        if (fraction(snapshot)) |value|
            gtk.gtk_progress_bar_set_fraction(bar, value)
        else if (!paused)
            gtk.gtk_progress_bar_pulse(bar);
    }
}

fn showPauseAll(self: *App, paused: bool) void {
    const activity = &self.activity;
    if (activity.popover_pause) |button| gtk.gtk_button_set_label(button, if (paused) "Resume all" else "Pause all");
    if (activity.page_pause_label) |text| gtk.gtk_label_set_text(text, if (paused) "Resume All" else "Pause All");
    if (activity.page_pause_icon) |image| gtk.gtk_image_set_from_icon_name(image, if (paused) "orca-play-symbolic" else "orca-pause-symbolic");
}

/// Rereads the open Library's Jobs and shows them, rebuilding the cards only
/// when a Job arrived, left or started.
pub fn refresh(self: *App) void {
    const library = self.library orelse {
        if (self.activity.widget) |revealer| gtk.gtk_revealer_set_reveal_child(revealer, gtk.false_);
        return;
    };
    const queued = self.runtime.jobQueuePage(library, self.allocator) catch return;
    defer self.allocator.free(queued);
    var buffer: [max_cards]Entry = undefined;
    var count: usize = 0;
    for (queued) |item| {
        if (count == max_cards) break;
        const snapshot = self.runtime.jobSnapshotSynced(item.job) catch continue;
        buffer[count] = .{ .queued = item, .snapshot = snapshot };
        count += 1;
    }
    const entries = buffer[0..count];
    const paused = self.runtime.libraryJobsPaused(library) catch false;
    if (changed(self, entries)) {
        const first = !self.activity.built;
        self.activity.built = true;
        rebuild(self, entries);
        if (!first) {
            reloadHistory(self);
            reloadRecent(self);
        }
    }
    const activity = &self.activity;
    for (entries[0..activity.page_card_count], activity.page_cards[0..activity.page_card_count]) |entry, card|
        showCard(card, entries, entry, paused, true);
    for (entries[0..activity.popover_card_count], activity.popover_cards[0..activity.popover_card_count]) |entry, card|
        showCard(card, entries, entry, paused, false);
    var running = false;
    var waiting = false;
    for (entries) |entry| {
        if (entry.waiting()) waiting = true else running = true;
    }
    if (activity.running_label) |widget| gtk.gtk_widget_set_visible(widget, boolean(running));
    if (activity.waiting_label) |widget| gtk.gtk_widget_set_visible(widget, boolean(waiting));
    if (activity.now_empty) |widget| gtk.gtk_widget_set_visible(widget, boolean(entries.len == 0));
    showPauseAll(self, paused);
    showWidget(self, entries, paused);
}

fn undoClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const group = @intFromPtr(gtk.g_object_get_data(button.?, "orca-undo") orelse return);
    if (tags.undoWrite(self, group)) gtk.gtk_widget_set_sensitive(gtk.cast(gtk.Widget, button.?), gtk.false_);
}

fn retryClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const id: i64 = @intCast(@intFromPtr(gtk.g_object_get_data(button.?, "orca-retry") orelse return));
    if (self.activity.popover) |popover| gtk.gtk_popover_popdown(popover);
    jobs.retry(self, id);
}

fn historyActions(self: *App, entry: *const liborca.JobHistoryEntry, class: [*:0]const u8) ?*gtk.Widget {
    if (entry.undo_group_id) |group| {
        const button = textButton("orca-undo-symbolic", 13, "Undo", class);
        gtk.g_object_set_data(button, "orca-undo", @ptrFromInt(@as(usize, @intCast(group))));
        _ = gtk.signalConnect(button, "clicked", gtk.callback(undoClicked), self);
        return button;
    }
    if (entry.retryable and entry.id > 0) {
        const button = textButton("orca-refresh-symbolic", 13, "Retry", class);
        gtk.g_object_set_data(button, "orca-retry", @ptrFromInt(@as(usize, @intCast(entry.id))));
        _ = gtk.signalConnect(button, "clicked", gtk.callback(retryClicked), self);
        return button;
    }
    return null;
}

fn statusIcon(entry: *const liborca.JobHistoryEntry, pixels: c_int) *gtk.Widget {
    const succeeded = entry.state == .succeeded;
    const image = icon(if (succeeded) "orca-check-symbolic" else "orca-alert-symbolic", pixels);
    gtk.gtk_widget_add_css_class(image, if (succeeded) "activity-ok" else "activity-problem");
    gtk.gtk_widget_set_valign(image, gtk.ALIGN_CENTER);
    return image;
}

fn unparentWithParent(_: ?*anyopaque, popover: ?*anyopaque) callconv(.c) void {
    const widget = gtk.cast(gtk.Widget, popover.?);
    if (gtk.gtk_widget_get_parent(widget) != null) gtk.gtk_widget_unparent(widget);
}

fn unparentLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const widget = gtk.cast(gtk.Widget, data.?);
    if (gtk.gtk_widget_get_parent(widget) != null) gtk.gtk_widget_unparent(widget);
    gtk.g_object_unref(widget);
    return gtk.SOURCE_REMOVE;
}

fn detailsClosed(popover: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    _ = gtk.g_idle_add(unparentLater, gtk.g_object_ref(popover));
}

fn detailRow(grid: *gtk.Widget, row: c_int, name: [*:0]const u8, value: [*:0]const u8) void {
    const key = label(name, "activity-details-key");
    const text = gtk.gtk_label_new(value);
    gtk.gtk_widget_add_css_class(text, "activity-details-value");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, text), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, text), gtk.true_);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, text), 40);
    gtk.gtk_label_set_selectable(gtk.cast(gtk.Label, text), gtk.true_);
    gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), key, 0, row, 1, 1);
    gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), text, 1, row, 1, 1);
}

fn detailsClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = @intFromPtr(gtk.g_object_get_data(button.?, "orca-history") orelse return) - 1;
    if (index >= self.activity.history_entries.len) return;
    const entry = &self.activity.history_entries[index];
    const grid = gtk.gtk_grid_new();
    gtk.gtk_grid_set_column_spacing(gtk.cast(gtk.Grid, grid), 16);
    gtk.gtk_grid_set_row_spacing(gtk.cast(gtk.Grid, grid), 6);
    gtk.gtk_widget_add_css_class(grid, "activity-details");
    var row: c_int = 0;
    var title_buffer: [128]u8 = undefined;
    const heading = label(historyTitle(&title_buffer, entry, false).ptr, "activity-details-title");
    gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), heading, 0, row, 2, 1);
    row += 1;
    var started: [64]u8 = undefined;
    detailRow(grid, row, "Started", localTime(&started, entry.started_at, "%-d %B %Y, %H:%M:%S").ptr);
    row += 1;
    var finished: [64]u8 = undefined;
    detailRow(grid, row, "Finished", localTime(&finished, entry.finished_at, "%-d %B %Y, %H:%M:%S").ptr);
    row += 1;
    detailRow(grid, row, "Result", switch (entry.state) {
        .succeeded => "Finished",
        .cancelled => "Stopped",
        else => "Failed",
    });
    row += 1;
    var progress: [96]u8 = undefined;
    detailRow(grid, row, "Progress", if (entry.total_units) |total|
        strings.format(&progress, "{f} of {f} {s}", .{ strings.grouped(entry.completed_units), strings.grouped(total), unitName(entry.kind, total) }).ptr
    else
        strings.format(&progress, "{f} {s}", .{ strings.grouped(entry.completed_units), unitName(entry.kind, entry.completed_units) }).ptr);
    row += 1;
    var reason: [260]u8 = undefined;
    if (entry.error_text.len != 0) {
        var first: [256]u8 = undefined;
        detailRow(grid, row, "Reason", strings.terminated(&reason, capitalized(&first, entry.error_text.slice())).ptr);
        row += 1;
    }
    var summary: [260]u8 = undefined;
    if (entry.summary.len != 0) {
        detailRow(grid, row, "Summary", strings.terminated(&summary, entry.summary.slice()).ptr);
        row += 1;
    }
    const popover = gtk.gtk_popover_new();
    gtk.gtk_popover_set_child(gtk.cast(gtk.Popover, popover), grid);
    gtk.gtk_popover_set_has_arrow(gtk.cast(gtk.Popover, popover), gtk.false_);
    gtk.gtk_popover_set_position(gtk.cast(gtk.Popover, popover), gtk.POS_BOTTOM);
    gtk.gtk_widget_add_css_class(popover, "activity-details-popover");
    const anchor = gtk.cast(gtk.Widget, button.?);
    gtk.gtk_widget_set_parent(popover, anchor);
    _ = gtk.g_signal_connect_object(anchor, "destroy", gtk.callback(unparentWithParent), popover, 0);
    _ = gtk.signalConnect(popover, "closed", gtk.callback(detailsClosed), null);
    gtk.gtk_popover_popup(gtk.cast(gtk.Popover, popover));
}

fn historyRow(self: *App, entry: *const liborca.JobHistoryEntry, index: usize) *gtk.Widget {
    var time_buffer: [16]u8 = undefined;
    const time = label(localTime(&time_buffer, entry.finished_at, "%H:%M").ptr, "activity-history-time");
    gtk.gtk_widget_add_css_class(time, "numeric");
    gtk.gtk_widget_set_size_request(time, 64, -1);
    const status = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_size_request(status, 26, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, status), statusIcon(entry, 17));
    var title_buffer: [128]u8 = undefined;
    const title = label(historyTitle(&title_buffer, entry, false).ptr, "activity-history-title");
    var detail_buffer: [600]u8 = undefined;
    var detail_text: [600]u8 = undefined;
    const detail = label(strings.terminated(&detail_text, historyDetail(&detail_buffer, entry)).ptr, "activity-history-detail");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, title), 1);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, detail), 1);
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ title, detail });
    var duration_buffer: [32]u8 = undefined;
    const duration = label(durationText(&duration_buffer, entry).ptr, "activity-history-duration");
    gtk.gtk_widget_add_css_class(duration, "numeric");
    gtk.gtk_widget_set_size_request(duration, 120, -1);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_size_request(actions, 150, -1);
    gtk.gtk_widget_set_hexpand(actions, gtk.false_);
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_END);
    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), spacer);
    if (historyActions(self, entry, "activity-history-action")) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, actions), button);
    const details = gtk.gtk_button_new_with_label("Details");
    gtk.gtk_widget_add_css_class(details, "flat");
    gtk.gtk_widget_add_css_class(details, "activity-details-link");
    gtk.gtk_widget_set_valign(details, gtk.ALIGN_CENTER);
    gtk.g_object_set_data(details, "orca-history", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(details, "clicked", gtk.callback(detailsClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), details);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(row, "activity-history-row");
    append(row, &.{ time, status, text, duration, actions });
    return row;
}

fn reloadHistory(self: *App) void {
    const activity = &self.activity;
    const box = activity.history orelse return;
    const library = self.library orelse return;
    const entries = self.runtime.jobHistoryPage(library, self.allocator, activity.filter, activity.history_limit, 0) catch return;
    activity.deinit(self.allocator);
    activity.history_entries = entries;
    clear(box);
    var shown_day: [64]u8 = undefined;
    var shown_day_len: usize = 0;
    for (entries, 0..) |*entry, index| {
        var day_buffer: [64]u8 = undefined;
        const day = dayLabel(&day_buffer, entry.finished_at);
        if (index == 0 or !std.mem.eql(u8, day, shown_day[0..shown_day_len])) {
            const heading = label(day.ptr, "activity-day");
            gtk.gtk_box_append(box, heading);
            @memcpy(shown_day[0..day.len], day);
            shown_day_len = day.len;
        }
        gtk.gtk_box_append(box, historyRow(self, entry, index));
    }
    if (activity.history_more) |more| gtk.gtk_widget_set_visible(more, boolean(entries.len == activity.history_limit));
    if (activity.history_empty) |empty| gtk.gtk_widget_set_visible(empty, boolean(entries.len == 0));
}

fn reloadRecent(self: *App) void {
    const box = self.activity.recent orelse return;
    const library = self.library orelse return;
    const entries = self.runtime.jobHistoryPage(library, self.allocator, .all, recent_count, 0) catch return;
    defer self.allocator.free(entries);
    clear(box);
    const now = nowSeconds(self);
    for (entries) |*entry| {
        var title_buffer: [128]u8 = undefined;
        const title = label(historyTitle(&title_buffer, entry, true).ptr, "activity-row-title");
        var detail_buffer: [600]u8 = undefined;
        var ago_buffer: [32]u8 = undefined;
        const detail = historyDetail(&detail_buffer, entry);
        const ago = agoText(&ago_buffer, now, entry.finished_at);
        var line_buffer: [640]u8 = undefined;
        const line = if (detail.len == 0)
            strings.terminated(&line_buffer, ago)
        else
            strings.format(&line_buffer, "{s} · {s}", .{ detail, ago });
        const subtitle = label(line.ptr, "activity-row-subtitle");
        const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
        gtk.gtk_widget_set_hexpand(column, gtk.true_);
        gtk.gtk_widget_set_valign(column, gtk.ALIGN_CENTER);
        append(column, &.{ title, subtitle });
        const status = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_add_css_class(status, "activity-row-status");
        gtk.gtk_box_append(gtk.cast(gtk.Box, status), statusIcon(entry, 16));
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
        gtk.gtk_widget_add_css_class(row, "activity-row");
        append(row, &.{ status, column });
        if (historyActions(self, entry, "activity-row-action")) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
        gtk.gtk_box_append(box, row);
    }
    if (self.activity.recent_label) |widget| gtk.gtk_widget_set_visible(widget, boolean(entries.len != 0));
}

fn filterToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) == 0) return;
    const index = @intFromPtr(gtk.g_object_get_data(button.?, "orca-filter") orelse return) - 1;
    self.activity.filter = @enumFromInt(@as(std.meta.Tag(liborca.JobHistoryFilter), @intCast(index)));
    self.activity.history_limit = history_page;
    reloadHistory(self);
}

fn moreClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.activity.history_limit += history_page;
    reloadHistory(self);
}

fn filterChips(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    var group: ?*gtk.ToggleButton = null;
    const filters = [_]struct { filter: liborca.JobHistoryFilter, text: [*:0]const u8 }{
        .{ .filter = .all, .text = "All" },
        .{ .filter = .scans, .text = "Scans" },
        .{ .filter = .analysis, .text = "Analysis" },
        .{ .filter = .file_changes, .text = "File changes" },
        .{ .filter = .problems, .text = "Problems" },
    };
    for (filters) |item| {
        const button = gtk.gtk_toggle_button_new();
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), item.text);
        gtk.gtk_widget_add_css_class(button, "chip");
        gtk.gtk_widget_add_css_class(button, "activity-chip");
        const toggle = gtk.cast(gtk.ToggleButton, button);
        gtk.gtk_toggle_button_set_group(toggle, group);
        group = group orelse toggle;
        gtk.g_object_set_data(button, "orca-filter", @ptrFromInt(@as(usize, @intFromEnum(item.filter)) + 1));
        if (item.filter == self.activity.filter) gtk.gtk_toggle_button_set_active(toggle, gtk.true_);
        _ = gtk.signalConnect(button, "toggled", gtk.callback(filterToggled), self);
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), button);
    }
    return row;
}

fn changeHistoryClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .changes);
}

fn popoverHistoryClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.activity.popover) |popover| gtk.gtk_popover_popdown(popover);
    window.goTo(self, .changes);
}

pub fn build(self: *App) *gtk.Widget {
    const title = page_ui.title("Activity");
    gtk.gtk_widget_add_css_class(title.widget, "activity-title");
    gtk.gtk_label_set_text(title.meta, "Everything Orca is doing in the background, and everything it has done.");
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, title.meta), "numeric");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, title.meta), "activity-tagline");
    const change_history = textButton("orca-undo-symbolic", 15, "Change History", "activity-button");
    _ = gtk.signalConnect(change_history, "clicked", gtk.callback(changeHistoryClicked), self);
    title.add(change_history);
    const pause = textButton("orca-pause-symbolic", 15, "Pause All", "activity-button");
    const pause_content = gtk.gtk_button_get_child(gtk.cast(gtk.Button, pause)).?;
    self.activity.page_pause_icon = gtk.cast(gtk.Image, gtk.gtk_widget_get_first_child(pause_content).?);
    self.activity.page_pause_label = gtk.cast(gtk.Label, gtk.gtk_widget_get_last_child(pause_content).?);
    _ = gtk.signalConnect(pause, "clicked", gtk.callback(pauseAllClicked), self);
    title.add(pause);

    const now_heading = label("Now", "section-label");
    gtk.gtk_widget_add_css_class(now_heading, "activity-section");
    const now = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    self.activity.now = gtk.cast(gtk.Box, now);
    const now_empty = label("Nothing is running.", "activity-empty");
    self.activity.now_empty = now_empty;
    const now_section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    append(now_section, &.{ now_heading, now, now_empty });

    const history_heading = label("History", "section-label");
    gtk.gtk_widget_add_css_class(history_heading, "activity-section");
    gtk.gtk_widget_set_hexpand(history_heading, gtk.true_);
    gtk.gtk_widget_set_valign(history_heading, gtk.ALIGN_CENTER);
    const history_header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    append(history_header, &.{ history_heading, filterChips(self) });
    const history = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(history, "activity-history");
    self.activity.history = gtk.cast(gtk.Box, history);
    const history_empty = label("Nothing has finished yet.", "activity-empty");
    self.activity.history_empty = history_empty;
    const more = textButton(null, 0, "Show Older", "activity-button");
    gtk.gtk_widget_set_halign(more, gtk.ALIGN_START);
    gtk.gtk_widget_set_visible(more, gtk.false_);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    self.activity.history_more = more;
    const history_section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    append(history_section, &.{ history_header, history, history_empty, more });

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 26);
    gtk.gtk_widget_add_css_class(body, "activity-body");
    append(body, &.{ now_section, history_section });
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(column, &.{ title.widget, body });

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    gtk.gtk_widget_add_css_class(scroller, "activity-page");
    return scroller;
}

pub fn forgetLibrary(self: *App) void {
    self.activity.history_limit = history_page;
    self.activity.built = false;
    refresh(self);
    reloadHistory(self);
    reloadRecent(self);
}

/// The page came into view: its history may have grown since it was built.
pub fn shown(self: *App) void {
    self.activity.built = false;
    refresh(self);
    reloadHistory(self);
}
