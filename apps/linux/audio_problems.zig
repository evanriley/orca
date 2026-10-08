//! The Audio Problems page: what analysis and the header probes found in the
//! audio itself, one category per kind of finding, with a card per file. A
//! card shows the file, re-analyzes it on its own thread, or hides the finding
//! until the file changes.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const health = @import("health.zig");
const signal_path = @import("signal_path.zig");

const App = app.App;

const Kind = liborca.HealthIssueKind;

const first_page: u32 = 50;

pub const Category = enum { clipping, decode_errors, malformed_headers, missing_replaygain };

fn kindOf(category: Category) Kind {
    return switch (category) {
        .clipping => .clipping,
        .decode_errors => .corrupt_audio,
        .malformed_headers => .unreadable_file,
        .missing_replaygain => .missing_analysis,
    };
}

fn categoryName(category: Category) [*:0]const u8 {
    return switch (category) {
        .clipping => "Possible clipping",
        .decode_errors => "Decode errors",
        .malformed_headers => "Malformed headers",
        .missing_replaygain => "Missing ReplayGain",
    };
}

fn categoryAbout(category: Category) [*:0]const u8 {
    return switch (category) {
        .clipping => "These tracks contain samples at or above digital full scale. This doesn't necessarily mean the recording is audibly distorted: many masters touch full scale on purpose. Orca counts runs of three or more full-scale samples in a row.",
        .decode_errors => "These files opened, but part of their audio would not decode. Playback may stop or skip where the damage is. Re-analyze decodes the file again, and clears the finding once the file has been replaced or repaired.",
        .malformed_headers => "Orca could not open these files or read their headers, so it knows nothing about their audio and cannot play them. A file may be incomplete, damaged, or not the format its contents suggest.",
        .missing_replaygain => "Orca decoded these files but could not measure their loudness, usually because the audio is too short or silent. They play without ReplayGain volume levelling, which is often expected for intros, interludes and gaps.",
    };
}

fn categoryIcon(category: Category) [*:0]const u8 {
    return switch (category) {
        .clipping => "orca-wave-symbolic",
        .decode_errors, .malformed_headers => "orca-file-symbolic",
        .missing_replaygain => "orca-gain-symbolic",
    };
}

fn categoryTone(category: Category) [*:0]const u8 {
    return switch (category) {
        .clipping => "caution",
        .decode_errors => "warn",
        .malformed_headers, .missing_replaygain => "neutral",
    };
}

const Item = struct {
    button: ?*gtk.Widget = null,
    count: ?*gtk.Label = null,
};

const Reanalysis = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    file_id: i64,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    outcome: ?liborca.ReanalysisOutcome = null,

    fn run(self: *Reanalysis) void {
        self.outcome = self.runtime.libraryReanalyzeFile(self.library, self.threaded.io(), self.file_id) catch null;
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn destroy(self: *Reanalysis, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

pub const State = struct {
    built: bool = false,
    stale: bool = true,
    selected: Category = .clipping,
    items: std.EnumArray(Category, Item) = .initFill(.{}),
    heading: ?*gtk.Label = null,
    about: ?*gtk.Label = null,
    note: ?*gtk.Widget = null,
    note_text: ?*gtk.Label = null,
    cards: ?*gtk.Box = null,
    empty: ?*gtk.Widget = null,
    more: ?*gtk.Widget = null,
    scroller: ?*gtk.ScrolledWindow = null,
    count: u64 = 0,
    loaded: u32 = 0,
    reanalysis: ?*Reanalysis = null,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const Finding = struct {
    self: *App,
    file_id: i64,
    kind: Kind,
};

fn findingOf(data: ?*anyopaque) *Finding {
    return @ptrCast(@alignCast(data.?));
}

fn freeFinding(data: ?*anyopaque) callconv(.c) void {
    const finding = findingOf(data);
    finding.self.allocator.destroy(finding);
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    return widget;
}

fn wrapped(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, widget), gtk.WRAP_WORD_CHAR);
    return widget;
}

fn append(box: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

fn button(text: [*:0]const u8, class: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, data: *anyopaque) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_widget_set_tooltip_text(widget, tooltip);
    _ = gtk.signalConnect(widget, "clicked", handler, data);
    return widget;
}

fn showInFolderClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const finding = findingOf(data);
    health.revealFile(finding.self, finding.file_id);
}

fn notAProblemClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const finding = findingOf(data);
    health.dismiss(finding.self, finding.file_id, finding.kind);
}

fn reanalyzeClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const finding = findingOf(data);
    const self = finding.self;
    if (self.audio_problems.reanalysis != null) return self.toast("Already re-analyzing a file");
    const library = self.library orelse return;
    const reanalysis = self.allocator.create(Reanalysis) catch return;
    reanalysis.* = .{ .runtime = self.runtime, .library = library, .file_id = finding.file_id, .waker = self.waker() };
    reanalysis.thread = std.Thread.spawn(.{}, Reanalysis.run, .{reanalysis}) catch {
        reanalysis.destroy(self.allocator);
        return self.toast("Could not re-analyze the file");
    };
    self.audio_problems.reanalysis = reanalysis;
    const pressed: *gtk.Widget = @ptrCast(@alignCast(widget.?));
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, pressed), "Re-analyzing…");
    gtk.gtk_widget_set_sensitive(pressed, gtk.false_);
}

pub fn tick(self: *App) void {
    const reanalysis = self.audio_problems.reanalysis orelse return;
    if (!reanalysis.finished.load(.acquire)) return;
    self.audio_problems.reanalysis = null;
    defer reanalysis.destroy(self.allocator);
    self.toast(if (reanalysis.outcome) |outcome| switch (outcome) {
        .measured => "Analyzed again",
        .unreadable => "The file still would not decode",
        .skipped => "The file is gone or changed; scan its folder first",
    } else "Could not re-analyze the file");
    health.reload(self);
    invalidate(self);
}

pub fn shutdown(self: *App) void {
    if (self.audio_problems.reanalysis) |reanalysis| reanalysis.destroy(self.allocator);
    self.audio_problems.reanalysis = null;
}

pub fn forgetLibrary(self: *App) void {
    shutdown(self);
    self.audio_problems.stale = true;
}

fn writeFormat(writer: *std.Io.Writer, summary: liborca.TrackSummary) std.Io.Writer.Error!void {
    if (summary.codec.len == 0) return;
    try signal_path.writeCodecName(writer, summary.codec);
    if (summary.bit_depth) |depth| try writer.print(" {d}-bit", .{depth});
    if (summary.sample_rate) |rate| {
        try writer.writeAll(" / ");
        try signal_path.writeRate(writer, rate);
    }
}

fn metaText(buffer: []u8, self: *App, item: liborca.HealthIssue) [:0]const u8 {
    const library = self.library orelse return strings.terminated(buffer, "");
    const track_id = item.track_id orelse return strings.terminated(buffer, "");
    const summary = (self.runtime.libraryTrackSummary(library, track_id) catch null) orelse return strings.terminated(buffer, "");
    defer summary.deinit(self.runtime.allocator);
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    var separate = false;
    for ([_][]const u8{ summary.artist, summary.album }) |part| {
        if (part.len == 0) continue;
        if (separate) writer.writeAll(" · ") catch {};
        writer.writeAll(part) catch {};
        separate = true;
    }
    if (summary.codec.len != 0) {
        if (separate) writer.writeAll(" · ") catch {};
        writeFormat(&writer, summary) catch {};
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn titleText(buffer: []u8, self: *App, item: liborca.HealthIssue) [:0]const u8 {
    var subtitle: [8]u8 = undefined;
    return health.issueNames(self, item, buffer, &subtitle)[0];
}

fn card(self: *App, item: liborca.HealthIssue) ?*gtk.Widget {
    const finding = self.allocator.create(Finding) catch return null;
    finding.* = .{ .self = self, .file_id = item.file_id, .kind = item.kind };

    var buffer: [1024]u8 = undefined;
    const title = label(titleText(&buffer, self, item).ptr, "audio-problems-card-title");
    const meta = label(metaText(&buffer, self, item).ptr, "audio-problems-card-meta");
    const path = label(strings.terminated(&buffer, item.path).ptr, "audio-problems-card-path");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, path), gtk.ELLIPSIZE_MIDDLE);
    if (item.path.len != 0) gtk.gtk_widget_set_tooltip_text(path, strings.terminated(&buffer, item.path).ptr);

    const show = button("Show in Folder", "audio-problems-action", "Show the file in its folder", gtk.callback(showInFolderClicked), finding);
    const reanalyze = button("Re-analyze", "audio-problems-action", "Decode the file again and measure it", gtk.callback(reanalyzeClicked), finding);
    if (self.audio_problems.reanalysis) |running| if (running.file_id == item.file_id) {
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, reanalyze), "Re-analyzing…");
        gtk.gtk_widget_set_sensitive(reanalyze, gtk.false_);
    };
    const hide = button("Not a problem", "audio-problems-dismiss", "Hide this finding until the file changes", gtk.callback(notAProblemClicked), finding);
    gtk.gtk_widget_add_css_class(hide, "flat");
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(actions, "audio-problems-card-actions");
    append(actions, &.{ show, reanalyze, hide });

    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_add_css_class(widget, "audio-problems-card");
    append(widget, &.{ title, meta, path });
    if (item.details.len != 0) {
        const note_text = if (item.kind == .clipping) health.clippingText(&buffer, item.details) else strings.terminated(&buffer, item.details);
        gtk.gtk_box_append(gtk.cast(gtk.Box, widget), wrapped(note_text.ptr, "audio-problems-card-detail"));
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), actions);
    gtk.g_object_set_data_full(widget, "orca-finding", finding, freeFinding);
    return widget;
}

fn loadMore(self: *App) void {
    const problems = &self.audio_problems;
    const cards = problems.cards orelse return;
    const library = self.library orelse return;
    const limit: u32 = if (problems.loaded == 0) first_page else app.page_size;
    var page = self.runtime.libraryHealthIssuePageOfKind(library, kindOf(problems.selected), limit, problems.loaded) catch
        return self.toast("Could not read the findings");
    defer page.deinit();
    for (page.items) |item| {
        const widget = card(self, item) orelse continue;
        gtk.gtk_box_append(cards, widget);
    }
    problems.loaded += @intCast(page.items.len);
    const exhausted = page.items.len < limit or problems.loaded >= problems.count;
    if (problems.more) |more| gtk.gtk_widget_set_visible(more, if (exhausted) gtk.false_ else gtk.true_);
}

fn showMoreClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    loadMore(state(data));
}

fn categoryClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    for (std.enums.values(Category)) |category| {
        const item_button = self.audio_problems.items.get(category).button orelse continue;
        if (@as(?*anyopaque, item_button) != widget) continue;
        self.audio_problems.selected = category;
        return reload(self);
    }
}

fn analyzeClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    jobs.startAnalysis(self);
    health.reload(self);
    reload(self);
}

fn healthClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .health);
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Library Health");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(healthClicked), self);
    const separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(separator, "breadcrumb-separator");
    const current = gtk.gtk_label_new("Audio Problems");
    gtk.gtk_widget_add_css_class(current, "breadcrumb-current");
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, separator, current });
    page_ui.addTrail(self, .audio_problems, crumbs);
}

fn categoryItem(self: *App, category: Category) *gtk.Widget {
    const name = label(categoryName(category), "audio-problems-category-name");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    const count = label("0", "audio-problems-category-count");
    gtk.gtk_widget_add_css_class(count, "numeric");
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    append(content, &.{ health.tile(categoryIcon(category), categoryTone(category), 30, 15), name, count });
    const widget = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, widget), content);
    gtk.gtk_widget_add_css_class(widget, "flat");
    gtk.gtk_widget_add_css_class(widget, "audio-problems-category");
    _ = gtk.signalConnect(widget, "clicked", gtk.callback(categoryClicked), self);
    self.audio_problems.items.set(category, .{ .button = widget, .count = gtk.cast(gtk.Label, count) });
    return widget;
}

fn buildDetail(self: *App) *gtk.Widget {
    const heading = label("", "audio-problems-heading");
    self.audio_problems.heading = gtk.cast(gtk.Label, heading);
    const about = wrapped("", "audio-problems-about");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, about), 98);
    gtk.gtk_widget_set_halign(about, gtk.ALIGN_START);
    self.audio_problems.about = gtk.cast(gtk.Label, about);

    const note_text = wrapped("", "audio-problems-note-text");
    gtk.gtk_widget_set_hexpand(note_text, gtk.true_);
    gtk.gtk_widget_set_valign(note_text, gtk.ALIGN_CENTER);
    self.audio_problems.note_text = gtk.cast(gtk.Label, note_text);
    const analyze = button("Analyze", "audio-problems-action", jobs.analysis_summary, gtk.callback(analyzeClicked), self);
    gtk.gtk_widget_set_valign(analyze, gtk.ALIGN_CENTER);
    const note = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(note, "audio-problems-note");
    append(note, &.{ note_text, analyze });
    self.audio_problems.note = note;

    const cards = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    self.audio_problems.cards = gtk.cast(gtk.Box, cards);
    const empty = label("Nothing found.", "audio-problems-empty");
    self.audio_problems.empty = empty;
    const more = gtk.gtk_button_new_with_label("Show more");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "audio-problems-more");
    gtk.gtk_widget_set_halign(more, gtk.ALIGN_START);
    gtk.gtk_widget_set_visible(more, gtk.false_);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(showMoreClicked), self);
    self.audio_problems.more = more;

    const detail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(detail, "audio-problems-detail");
    append(detail, &.{ heading, about, note, cards, empty, more });

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), detail);
    self.audio_problems.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(scrollerDestroyed), self);
    return scroller;
}

pub fn build(self: *App) *gtk.Widget {
    buildTrail(self);

    const title = page_ui.title("Audio Problems");
    gtk.gtk_widget_add_css_class(title.widget, "audio-problems-title");
    gtk.gtk_label_set_text(title.meta, "What Orca found while decoding and analyzing your files, and what each finding means.");
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, title.meta), "numeric");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, title.meta), "audio-problems-summary");

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(list, "audio-problems-categories");
    for (std.enums.values(Category)) |category| gtk.gtk_box_append(gtk.cast(gtk.Box, list), categoryItem(self, category));
    const list_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, list_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, list_scroller), list);
    gtk.gtk_widget_set_size_request(list_scroller, 284, -1);
    gtk.gtk_widget_set_hexpand(list_scroller, gtk.false_);
    gtk.gtk_widget_add_css_class(list_scroller, "audio-problems-list");

    const split = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(split, "audio-problems-split");
    gtk.gtk_widget_set_vexpand(split, gtk.true_);
    append(split, &.{ list_scroller, buildDetail(self) });

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "audio-problems-page");
    append(column, &.{ title.widget, split });
    self.audio_problems.built = true;
    return column;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.audio_problems.scroller = null;
    self.audio_problems.built = false;
}

pub fn shown(self: *App) void {
    if (self.audio_problems.stale) reload(self);
}

pub fn invalidate(self: *App) void {
    self.audio_problems.stale = true;
    if (self.current_page == .audio_problems) reload(self);
}

pub fn showCategory(self: *App, category: Category) void {
    self.audio_problems.selected = category;
    self.audio_problems.stale = true;
    window.goTo(self, .audio_problems);
    if (self.audio_problems.stale) reload(self);
}

fn reload(self: *App) void {
    const problems = &self.audio_problems;
    if (!problems.built) return;
    problems.stale = false;
    const library = self.library orelse return;
    const cards = problems.cards orelse return;

    var counts: std.EnumArray(Kind, u64) = .initFill(0);
    const summary = self.runtime.libraryHealthSummary(library) catch return self.toast("Could not read the library's health");
    for (summary.items()) |item| counts.set(item.kind, item.count);

    var buffer: [256]u8 = undefined;
    for (std.enums.values(Category)) |category| {
        const item = problems.items.get(category);
        if (item.count) |count| gtk.gtk_label_set_text(count, strings.format(&buffer, "{f}", .{strings.grouped(counts.get(kindOf(category)))}).ptr);
        const widget = item.button orelse continue;
        if (category == problems.selected) gtk.gtk_widget_add_css_class(widget, "selected") else gtk.gtk_widget_remove_css_class(widget, "selected");
    }

    const selected = problems.selected;
    if (problems.heading) |heading| gtk.gtk_label_set_text(heading, categoryName(selected));
    if (problems.about) |about| gtk.gtk_label_set_text(about, categoryAbout(selected));
    problems.count = counts.get(kindOf(selected));

    const unanalysed: u64 = if (selected == .missing_replaygain and !jobs.active(self, .analysis))
        self.runtime.libraryUnanalyzedCount(library) catch 0
    else
        0;
    if (problems.note) |note| gtk.gtk_widget_set_visible(note, if (unanalysed == 0) gtk.false_ else gtk.true_);
    if (problems.note_text) |note_text| if (unanalysed != 0) gtk.gtk_label_set_text(note_text, strings.format(&buffer, "{f} more {s} not been analyzed yet, so {s} no ReplayGain either.", .{
        strings.grouped(unanalysed),
        if (unanalysed == 1) "file has" else "files have",
        if (unanalysed == 1) "it has" else "they have",
    }).ptr);

    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, cards))) |child| gtk.gtk_box_remove(cards, child);
    problems.loaded = 0;
    if (problems.more) |more| gtk.gtk_widget_set_visible(more, gtk.false_);
    if (problems.count != 0) loadMore(self);
    if (problems.empty) |empty| gtk.gtk_widget_set_visible(empty, if (problems.loaded == 0) gtk.true_ else gtk.false_);
    if (problems.scroller) |scroller| gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), 0);
}
