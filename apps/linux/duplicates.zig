//! The Duplicates page: the groups of files the duplicate scan found to be
//! copies of one another, and the selected group's copies side by side. The
//! groups, copies and playlists are database reads on the main thread;
//! merging, keeping and ignoring are the runtime's, and no file is touched.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const health = @import("health.zig");
const jobs = @import("jobs.zig");
const ratings = @import("ratings.zig");
const signal_path = @import("signal_path.zig");

const App = app.App;

const group_limit: u32 = 512;
const minus = "−";
const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

pub const State = struct {
    list: ?*gtk.Box = null,
    empty: ?*gtk.Widget = null,
    summary: ?*gtk.Label = null,
    position: ?*gtk.Label = null,
    detail: ?*gtk.Widget = null,
    heading: ?*gtk.Label = null,
    subtitle: ?*gtk.Label = null,
    evidence: ?*gtk.Label = null,
    table: ?*gtk.Box = null,
    note: ?*gtk.Label = null,
    merge: ?*gtk.Widget = null,
    keep_both: ?*gtk.Widget = null,
    page: ?liborca.DuplicateGroupPage = null,
    totals: liborca.DuplicateGroupTotals = .{ .groups = 0, .bytes = 0 },
    selected: i64 = 0,
    copies: ?liborca.DuplicateCopyList = null,
    keep: usize = 0,
    rebuild_pending: bool = false,
    stale: bool = true,

    pub fn deinit(self: *State) void {
        if (self.page) |*page| page.deinit();
        self.page = null;
        if (self.copies) |*copies| copies.deinit();
        self.copies = null;
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
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

fn button(text: [*:0]const u8, class: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(widget, class);
    _ = gtk.signalConnect(widget, "clicked", handler, self);
    return widget;
}

fn groups(self: *App) []const liborca.DuplicateGroup {
    return if (self.duplicates.page) |page| page.items else &.{};
}

fn selectedIndex(self: *App) ?usize {
    for (groups(self), 0..) |group, index| if (group.id == self.duplicates.selected) return index;
    return null;
}

fn copyItems(self: *App) []const liborca.DuplicateCopy {
    return if (self.duplicates.copies) |list| list.items else &.{};
}

pub fn build(self: *App) *gtk.Widget {
    buildTrail(self);

    const title = page_ui.title("Duplicates");
    gtk.gtk_widget_add_css_class(title.widget, "duplicates-title");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, title.meta), "duplicates-summary");
    self.duplicates.summary = title.meta;
    const position = label("", "duplicates-position");
    gtk.gtk_widget_add_css_class(position, "numeric");
    self.duplicates.position = gtk.cast(gtk.Label, position);
    title.add(position);

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(list, "duplicates-list");
    self.duplicates.list = gtk.cast(gtk.Box, list);
    const empty = label("No files appear more than once.", "duplicates-empty");
    gtk.gtk_widget_set_visible(empty, gtk.false_);
    self.duplicates.empty = empty;
    const list_column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(list_column, &.{ list, empty });
    const list_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, list_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, list_scroller), list_column);
    gtk.gtk_widget_set_size_request(list_scroller, 264, -1);
    gtk.gtk_widget_set_hexpand(list_scroller, gtk.false_);
    gtk.gtk_widget_add_css_class(list_scroller, "duplicates-groups");

    const split = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(split, "duplicates-split");
    gtk.gtk_widget_set_vexpand(split, gtk.true_);
    const detail = buildDetail(self);
    append(split, &.{ list_scroller, detail });

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "duplicates-page");
    append(column, &.{ title.widget, split });
    const bin = page_ui.breakpointBin(column);
    page_ui.stackBelow(bin, "max-width: 700px", &.{split}, &.{ list_scroller, detail });
    return bin;
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Library Health");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(healthClicked), self);
    const separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(separator, "breadcrumb-separator");
    const current = gtk.gtk_label_new("Duplicates");
    gtk.gtk_widget_add_css_class(current, "breadcrumb-current");
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, separator, current });
    page_ui.addTrail(self, .duplicates, crumbs);
}

fn healthClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .health);
}

fn buildDetail(self: *App) *gtk.Widget {
    const heading = label("", "duplicates-heading");
    gtk.gtk_widget_set_valign(heading, gtk.ALIGN_BASELINE_FILL);
    self.duplicates.heading = gtk.cast(gtk.Label, heading);
    const subtitle = label("", "duplicates-subtitle");
    gtk.gtk_widget_set_valign(subtitle, gtk.ALIGN_BASELINE_FILL);
    self.duplicates.subtitle = gtk.cast(gtk.Label, subtitle);
    const evidence = label("", "duplicates-evidence");
    gtk.gtk_widget_set_valign(evidence, gtk.ALIGN_BASELINE_FILL);
    gtk.gtk_widget_set_hexpand(evidence, gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, evidence), 1.0);
    self.duplicates.evidence = gtk.cast(gtk.Label, evidence);
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(header, "duplicates-header");
    append(header, &.{ heading, subtitle, evidence });

    const table = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    self.duplicates.table = gtk.cast(gtk.Box, table);

    const note_text = label("", "duplicates-note-text");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, note_text), gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note_text), gtk.true_);
    gtk.gtk_widget_set_hexpand(note_text, gtk.true_);
    self.duplicates.note = gtk.cast(gtk.Label, note_text);
    const note_icon = icon("orca-info-symbolic", 16);
    gtk.gtk_widget_set_valign(note_icon, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(note_icon, "duplicates-note-icon");
    const note = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(note, "duplicates-note");
    append(note, &.{ note_icon, note_text });

    const merge = button("Merge Metadata Only", "duplicates-action", gtk.callback(mergeClicked), self);
    gtk.gtk_widget_set_tooltip_text(merge, "Give the kept copy the tags, play count and rating it lacks; no file is written");
    self.duplicates.merge = merge;
    const keep_both = button("Keep Both", "duplicates-action", gtk.callback(keepBothClicked), self);
    gtk.gtk_widget_set_tooltip_text(keep_both, "Stop reporting these files as copies until their bytes change");
    self.duplicates.keep_both = keep_both;
    const ignore = button("Ignore", "duplicates-ignore", gtk.callback(ignoreClicked), self);
    gtk.gtk_widget_add_css_class(ignore, "flat");
    gtk.gtk_widget_set_tooltip_text(ignore, "Hide this group until its files change");
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "duplicates-actions");
    append(actions, &.{ merge, keep_both, ignore });

    const detail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_add_css_class(detail, "duplicates-detail");
    append(detail, &.{ header, table, note, actions });
    self.duplicates.detail = detail;

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), detail);
    return scroller;
}

pub fn shown(self: *App) void {
    if (self.duplicates.stale) reload(self);
}

pub fn invalidate(self: *App) void {
    self.duplicates.stale = true;
    if (self.current_page == .duplicates) reload(self);
}

pub fn forgetLibrary(self: *App) void {
    self.duplicates.deinit();
    self.duplicates.totals = .{ .groups = 0, .bytes = 0 };
    self.duplicates.selected = 0;
    self.duplicates.keep = 0;
    self.duplicates.stale = true;
}

pub fn showFile(self: *App, file_id: i64) void {
    window.goTo(self, .duplicates);
    const library = self.library orelse return;
    const items = groups(self);
    var index = items.len;
    while (index > 0) {
        index -= 1;
        if (items[index].id > file_id) continue;
        var list = self.runtime.libraryDuplicateGroup(library, self.allocator, items[index].id) catch continue;
        defer list.deinit();
        for (list.items) |copy| if (copy.file_id == file_id) return select(self, items[index].id);
    }
}

fn reload(self: *App) void {
    const duplicates = &self.duplicates;
    const list = duplicates.list orelse return;
    duplicates.stale = false;
    if (duplicates.page) |*page| page.deinit();
    duplicates.page = null;
    duplicates.totals = .{ .groups = 0, .bytes = 0 };
    if (self.library) |library| {
        duplicates.page = self.runtime.libraryDuplicateGroupPage(library, self.allocator, group_limit, 0) catch null;
        duplicates.totals = self.runtime.libraryDuplicateGroupTotals(library) catch duplicates.totals;
    }

    const keep_file: ?i64 = if (duplicates.keep < copyItems(self).len) copyItems(self)[duplicates.keep].file_id else null;
    clear(list);
    const items = groups(self);
    if (selectedIndex(self) == null) duplicates.selected = if (items.len != 0) items[0].id else 0;
    for (items, 0..) |*group, index| gtk.gtk_box_append(list, row(self, group, index));
    gtk.gtk_widget_set_visible(duplicates.empty.?, @intFromBool(items.len == 0));
    showSummary(self);
    loadCopies(self, keep_file);
    showSelected(self);
}

fn showSummary(self: *App) void {
    const totals = self.duplicates.totals;
    var buffer: [256]u8 = undefined;
    const text = if (totals.groups == 0)
        strings.terminated(&buffer, "No recordings appear more than once. Orca never deletes on its own.")
    else blk: {
        const size = gtk.g_format_size(totals.bytes);
        defer gtk.g_free(size);
        break :blk strings.format(&buffer, "{d} {s} more than once · potentially {s}. Orca never deletes on its own.", .{
            totals.groups,
            if (totals.groups == 1) "recording appears" else "recordings appear",
            std.mem.span(size),
        });
    };
    gtk.gtk_label_set_text(self.duplicates.summary.?, text);
}

fn row(self: *App, group: *const liborca.DuplicateGroup, index: usize) *gtk.Widget {
    var title_buffer: [260]u8 = undefined;
    const title = label(strings.terminated(&title_buffer, group.title), "duplicates-row-title");
    var subtitle_buffer: [300]u8 = undefined;
    const subtitle = label(if (group.artist.len == 0)
        strings.format(&subtitle_buffer, "{d} copies", .{group.copies})
    else
        strings.format(&subtitle_buffer, "{s} · {d} copies", .{ group.artist, group.copies }), "duplicates-row-subtitle");
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    append(content, &.{ title, subtitle });
    const widget = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, widget), content);
    gtk.gtk_widget_add_css_class(widget, "flat");
    gtk.gtk_widget_add_css_class(widget, "duplicates-row");
    gtk.g_object_set_data(widget, "orca-group", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(widget, "clicked", gtk.callback(rowClicked), self);
    return widget;
}

fn rowClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tagged = gtk.g_object_get_data(widget.?, "orca-group") orelse return;
    const index = @intFromPtr(tagged) - 1;
    const items = groups(self);
    if (index >= items.len) return;
    select(self, items[index].id);
}

fn select(self: *App, group_id: i64) void {
    if (group_id == self.duplicates.selected and self.duplicates.copies != null) return;
    self.duplicates.selected = group_id;
    loadCopies(self, null);
    showSelected(self);
}

fn syncRows(self: *App) void {
    const list = self.duplicates.list orelse return;
    const items = groups(self);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list));
    var index: usize = 0;
    while (child) |widget| : (index += 1) {
        const selected = index < items.len and items[index].id == self.duplicates.selected;
        if (selected) gtk.gtk_widget_add_css_class(widget, "selected") else gtk.gtk_widget_remove_css_class(widget, "selected");
        child = gtk.gtk_widget_get_next_sibling(widget);
    }
}

fn loadCopies(self: *App, keep_file: ?i64) void {
    const duplicates = &self.duplicates;
    if (duplicates.copies) |*list| list.deinit();
    duplicates.copies = null;
    duplicates.keep = 0;
    const library = self.library orelse return;
    if (selectedIndex(self) == null) return;
    duplicates.copies = self.runtime.libraryDuplicateGroup(library, self.allocator, duplicates.selected) catch null;
    const wanted = keep_file orelse return;
    for (copyItems(self), 0..) |copy, index| if (copy.file_id == wanted) {
        duplicates.keep = index;
    };
}

fn showSelected(self: *App) void {
    const duplicates = &self.duplicates;
    syncRows(self);
    const items = groups(self);
    const index = selectedIndex(self);
    var buffer: [64]u8 = undefined;
    gtk.gtk_label_set_text(duplicates.position.?, if (index) |at|
        strings.format(&buffer, "Group {d} of {d}", .{ at + 1, @max(duplicates.totals.groups, items.len) })
    else
        "");

    const at = index orelse {
        gtk.gtk_widget_set_visible(duplicates.detail.?, gtk.false_);
        return;
    };
    const group = items[at];
    const list = duplicates.copies orelse {
        gtk.gtk_widget_set_visible(duplicates.detail.?, gtk.false_);
        return self.toast("Could not read this group's files");
    };
    if (list.items.len == 0) {
        gtk.gtk_widget_set_visible(duplicates.detail.?, gtk.false_);
        return;
    }
    gtk.gtk_widget_set_visible(duplicates.detail.?, gtk.true_);
    const keep = &list.items[duplicates.keep];

    var heading_buffer: [260]u8 = undefined;
    gtk.gtk_label_set_text(duplicates.heading.?, strings.terminated(&heading_buffer, group.title));
    var subtitle_buffer: [520]u8 = undefined;
    const album: []const u8 = if (keep.details) |details| details.album else "";
    gtk.gtk_label_set_text(duplicates.subtitle.?, if (album.len != 0 and group.artist.len != 0)
        strings.format(&subtitle_buffer, "{s} · {s}", .{ group.artist, album })
    else
        strings.terminated(&subtitle_buffer, if (album.len != 0) album else group.artist));
    var evidence_buffer: [64]u8 = undefined;
    gtk.gtk_label_set_text(duplicates.evidence.?, evidenceText(&evidence_buffer, list.similarity));

    showTable(self, &list);

    var note_buffer: [512]u8 = undefined;
    gtk.gtk_label_set_text(duplicates.note.?, noteText(&note_buffer, &list, duplicates.keep));
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, duplicates.keep_both.?), if (list.items.len > 2) "Keep All" else "Keep Both");
    gtk.gtk_widget_set_sensitive(duplicates.merge.?, @intFromBool(keep.track_id != null and list.items.len > 1));
    gtk.gtk_widget_set_sensitive(duplicates.keep_both.?, @intFromBool(list.items.len > 1));
}

fn evidenceText(buffer: []u8, similarity: ?f32) [:0]const u8 {
    const value = similarity orelse return strings.terminated(buffer, "Fingerprints match");
    const percent: u32 = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 100));
    if (percent >= 100) return strings.terminated(buffer, "Identical audio");
    return strings.format(buffer, "Fingerprints match · {d}%", .{percent});
}

const Field = enum {
    path,
    format,
    size,
    duration,
    album,
    track,
    date,
    loudness,
    musicbrainz,
    plays,
    playlists,

    fn title(self: Field) [*:0]const u8 {
        return switch (self) {
            .path => "Path",
            .format => "Format",
            .size => "Size",
            .duration => "Duration",
            .album => "Album",
            .track => "Track",
            .date => "Date",
            .loudness => "Loudness",
            .musicbrainz => "MusicBrainz",
            .plays => "Plays · rating",
            .playlists => "In playlists",
        };
    }

    fn measured(self: Field) bool {
        return self == .duration or self == .loudness;
    }
};

fn showTable(self: *App, list: *const liborca.DuplicateCopyList) void {
    const table = self.duplicates.table.?;
    clear(table);
    const grid = gtk.gtk_grid_new();
    gtk.gtk_widget_add_css_class(grid, "duplicates-table");
    const cells = gtk.cast(gtk.Grid, grid);
    const keep = self.duplicates.keep;
    const items = list.items;
    const prefix = commonDirectory(items);

    var group: ?*gtk.CheckButton = null;
    for (items, 0..) |copy, index| {
        const card = copyCard(self, copy, index, index == keep, items.len == 1, &group);
        if (index != 0) gtk.gtk_widget_add_css_class(card, "later");
        gtk.gtk_grid_attach(cells, card, @intCast(index + 1), 0, 1, 1);
    }

    var grid_row: c_int = 1;
    for (std.enums.values(Field)) |field| {
        const name = label(field.title(), "duplicates-field");
        gtk.gtk_widget_set_size_request(name, 152, -1);
        gtk.gtk_grid_attach(cells, name, 0, grid_row, 1, 1);
        if (field == .plays and list.same_recording) {
            var buffer: [128]u8 = undefined;
            const shared = label(fieldValue(self, &buffer, field, &items[keep], prefix), "duplicates-value");
            gtk.gtk_widget_add_css_class(shared, "kept");
            gtk.gtk_widget_set_hexpand(shared, gtk.true_);
            gtk.gtk_widget_set_tooltip_text(shared, "These copies are one recording, so they share one play count and rating");
            gtk.gtk_grid_attach(cells, shared, 1, grid_row, @intCast(items.len), 1);
        } else {
            var keep_buffer: [1024]u8 = undefined;
            const kept = fieldValue(self, &keep_buffer, field, &items[keep], prefix);
            for (items, 0..) |*copy, index| {
                var buffer: [1024]u8 = undefined;
                const text = if (index == keep) kept else fieldValue(self, &buffer, field, copy, prefix);
                const cell = label(text, "duplicates-value");
                if (index == 0) gtk.gtk_widget_set_hexpand(cell, gtk.true_) else gtk.gtk_widget_add_css_class(cell, "later");
                gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, cell), if (index == 0) 64 else 32);
                if (index == keep)
                    gtk.gtk_widget_add_css_class(cell, "kept")
                else if (!field.measured() and !std.mem.eql(u8, text, kept))
                    gtk.gtk_widget_add_css_class(cell, "differs");
                if (field == .path) {
                    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, cell), gtk.ELLIPSIZE_START);
                    if (copy.details) |details| if (details.path) |path| {
                        var path_buffer: [4096]u8 = undefined;
                        gtk.gtk_widget_set_tooltip_text(cell, strings.terminated(&path_buffer, path));
                    };
                }
                gtk.gtk_grid_attach(cells, cell, @intCast(index + 1), grid_row, 1, 1);
            }
        }
        grid_row += 1;
    }
    gtk.gtk_box_append(table, grid);
}

fn copyCard(self: *App, copy: liborca.DuplicateCopy, index: usize, kept: bool, alone: bool, group: *?*gtk.CheckButton) *gtk.Widget {
    var buffer: [32]u8 = undefined;
    const letter = letters[@min(index, letters.len - 1)];
    const text = if (kept)
        strings.format(&buffer, "Copy {c} · keep", .{letter})
    else
        strings.format(&buffer, "Copy {c}", .{letter});
    const radio = if (alone) label(text.ptr, "duplicates-copy") else gtk.gtk_check_button_new_with_label(text.ptr);
    gtk.gtk_widget_set_hexpand(radio, gtk.true_);
    if (!alone) {
        gtk.gtk_widget_add_css_class(radio, "duplicates-radio");
        const radio_button = gtk.cast(gtk.CheckButton, radio);
        gtk.gtk_check_button_set_group(radio_button, group.*);
        if (group.* == null) group.* = radio_button;
        gtk.gtk_check_button_set_active(radio_button, @intFromBool(kept));
        gtk.g_object_set_data(radio, "orca-copy", @ptrFromInt(index + 1));
        _ = gtk.signalConnect(radio, "toggled", gtk.callback(keepToggled), self);
    }

    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(card, "duplicates-card");
    if (kept) gtk.gtk_widget_add_css_class(card, "kept");
    if (index != 0) gtk.gtk_widget_set_size_request(card, 236, -1);
    gtk.gtk_widget_set_hexpand(card, @intFromBool(index == 0));
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), radio);
    if (copy.suggested_keep) {
        const suggested = label("Suggested", "duplicates-suggested");
        gtk.gtk_widget_set_valign(suggested, gtk.ALIGN_CENTER);
        gtk.gtk_box_append(gtk.cast(gtk.Box, card), suggested);
    }
    return card;
}

fn keepToggled(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, widget.?)) == 0) return;
    const tagged = gtk.g_object_get_data(widget.?, "orca-copy") orelse return;
    const index = @intFromPtr(tagged) - 1;
    if (index >= copyItems(self).len or index == self.duplicates.keep) return;
    self.duplicates.keep = index;
    if (self.duplicates.rebuild_pending) return;
    self.duplicates.rebuild_pending = true;
    _ = gtk.g_idle_add(rebuildIdle, self);
}

fn rebuildIdle(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.duplicates.rebuild_pending = false;
    showSelected(self);
    return gtk.false_;
}

fn commonDirectory(items: []const liborca.DuplicateCopy) usize {
    var common: ?[]const u8 = null;
    var paths: usize = 0;
    for (items) |copy| {
        const details = copy.details orelse continue;
        const path = details.path orelse continue;
        paths += 1;
        const directory = std.fs.path.dirname(path) orelse return 0;
        const so_far = common orelse {
            common = directory;
            continue;
        };
        var length = std.mem.indexOfDiff(u8, so_far, directory) orelse so_far.len;
        if (length < so_far.len or length < directory.len) {
            while (length > 0 and so_far[length - 1] != '/') length -= 1;
            if (length > 0) length -= 1;
        }
        common = so_far[0..length];
    }
    if (paths < 2) return 0;
    const prefix = common orelse return 0;
    return if (prefix.len > 1) prefix.len else 0;
}

fn fieldValue(self: *App, buffer: []u8, field: Field, copy: *const liborca.DuplicateCopy, prefix: usize) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeField(self, &writer, field, copy, prefix) catch {};
    if (writer.end == 0) writer.writeAll("—") catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn writeField(self: *App, writer: *std.Io.Writer, field: Field, copy: *const liborca.DuplicateCopy, prefix: usize) !void {
    switch (field) {
        .playlists => return writePlaylists(self, writer, copy.file_id),
        .track => {
            const number = copy.tagged_track_number orelse return;
            if (copy.tagged_track_total) |total| return writer.print("{d} of {d}", .{ number, total });
            return writer.print("{d}", .{number});
        },
        .date => return writer.writeAll(copy.tagged_date orelse ""),
        else => {},
    }
    const details = copy.details orelse return;
    switch (field) {
        .path => {
            const path = details.path orelse return;
            if (prefix != 0 and prefix < path.len) try writer.print("…{s}", .{path[prefix..]}) else try writer.writeAll(path);
        },
        .format => try writeFormat(writer, &details),
        .size => {
            const size = std.math.cast(u64, details.size_bytes orelse return) orelse return;
            const text = gtk.g_format_size(size);
            defer gtk.g_free(text);
            try writer.writeAll(std.mem.span(text));
        },
        .duration => {
            const length = std.math.cast(u64, details.duration_ms orelse return) orelse return;
            var buffer: [32]u8 = undefined;
            try writer.writeAll(strings.formatMs(&buffer, length));
        },
        .album => try writer.writeAll(details.album),
        .loudness => {
            const loudness = details.loudness orelse return;
            const tenths = @round(loudness.integrated_lufs * 10) / 10;
            try writer.print("{s}{d:.1} LUFS", .{ if (tenths < 0) minus else "", @abs(tenths) });
        },
        .musicbrainz => try writer.writeAll(if (details.musicbrainz_recording_id != null) "Matched" else "Not matched"),
        .plays => {
            try writer.print("{d} · ", .{details.play_count});
            const stars = ratings.starsFor(details.rating);
            if (stars == 0) return writer.writeAll("unrated");
            for (0..5) |star| try writer.writeAll(if (star < stars) "★" else "☆");
        },
        .playlists, .track, .date => unreachable,
    }
}

fn writeFormat(writer: *std.Io.Writer, details: *const liborca.TrackDetails) !void {
    try signal_path.writeCodecName(writer, details.codec);
    if (details.lossy) {
        if (details.bitrate_kbps) |kbps| try writer.print(" · {d} kbps", .{kbps});
    } else if (details.bit_depth) |depth| try writer.print(" · {d}-bit", .{depth});
    if (details.sample_rate) |rate| {
        try writer.writeAll(" · ");
        try signal_path.writeRate(writer, rate);
    }
}

fn writePlaylists(self: *App, writer: *std.Io.Writer, file_id: i64) !void {
    const library = self.library orelse return;
    const names = self.runtime.libraryDuplicateCopyPlaylists(library, self.allocator, file_id) catch return;
    defer {
        for (names) |name| self.allocator.free(name);
        self.allocator.free(names);
    }
    if (names.len == 0) return writer.writeAll("None");
    for (names, 0..) |name, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(name);
    }
}

fn better(keep: *const liborca.TrackDetails, other: *const liborca.TrackDetails) bool {
    if (!keep.lossy and other.lossy) return true;
    if (keep.lossy != other.lossy) return false;
    if ((keep.sample_rate orelse 0) > (other.sample_rate orelse 0)) return true;
    return (keep.bit_depth orelse 0) > (other.bit_depth orelse 0);
}

fn tagCount(details: *const liborca.TrackDetails) u32 {
    var count: u32 = 0;
    if (details.album.len != 0) count += 1;
    if (details.track_number != null) count += 1;
    if (details.track_total != null) count += 1;
    if (details.date != null) count += 1;
    if (details.musicbrainz_recording_id != null) count += 1;
    return count;
}

fn noteText(buffer: []u8, list: *const liborca.DuplicateCopyList, keep_index: usize) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeNote(&writer, list, keep_index) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn writeNote(writer: *std.Io.Writer, list: *const liborca.DuplicateCopyList, keep_index: usize) !void {
    const items = list.items;
    const kept = letters[@min(keep_index, letters.len - 1)];
    var lossless_over_lossy = true;
    var higher = true;
    var complete = true;
    var others: usize = 0;
    const keep_details = items[keep_index].details;
    for (items, 0..) |copy, index| {
        if (index == keep_index) continue;
        others += 1;
        const keep = keep_details orelse {
            higher = false;
            complete = false;
            lossless_over_lossy = false;
            continue;
        };
        const other = copy.details orelse continue;
        if (keep.lossy or !other.lossy) lossless_over_lossy = false;
        if (!better(&keep, &other)) higher = false;
        if (tagCount(&keep) <= tagCount(&other)) complete = false;
    }
    if (others == 0) {
        const places = items[keep_index].locations;
        if (places > 1) try writer.print("This file is stored in {d} places with identical bytes. Orca lists it once; Ignore hides the group.", .{places});
        return;
    }

    if (list.same_recording) {
        if (items.len == 2) try writer.writeAll("Both files are the same recording. ") else try writer.print("All {d} files are the same recording. ", .{items.len});
        if (lossless_over_lossy)
            try writer.print("Copy {c} is lossless", .{kept})
        else if (higher)
            try writer.print("Copy {c} has higher resolution", .{kept})
        else
            try writer.print("Copy {c} is the one you keep", .{kept});
        try writer.writeAll(if (complete) " and has complete tags. " else ". ");
        try writer.print("They share one play count and rating, so merging gives {c} only the tags it lacks.", .{kept});
        return;
    }
    if (higher and complete)
        try writer.print("Copy {c} has higher resolution and complete tags. ", .{kept})
    else if (higher)
        try writer.print("Copy {c} has higher resolution. ", .{kept})
    else if (complete)
        try writer.print("Copy {c} has complete tags. ", .{kept});
    try writer.print("Merging keeps {c}’s file and adds ", .{kept});
    var written: usize = 0;
    for (items, 0..) |_, index| {
        if (index == keep_index) continue;
        if (written != 0) try writer.writeAll(if (written + 1 == others) " and " else ", ");
        try writer.print("{c}’s", .{letters[@min(index, letters.len - 1)]});
        written += 1;
    }
    try writer.writeAll(" play count and rating.");
}

fn mergeClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const items = copyItems(self);
    if (items.len < 2) return;
    const keep = items[self.duplicates.keep];
    var keep_track = keep.track_id orelse return self.toast("The kept copy has no track to merge into");
    var others: [letters.len]?i64 = @splat(null);
    for (items, 0..) |copy, index| {
        if (index == self.duplicates.keep or index >= others.len) continue;
        others[index] = copy.track_id;
    }
    var changed = false;
    for (others) |other| {
        const from = other orelse continue;
        if (from == keep_track) continue;
        const merged = self.runtime.libraryMergeDuplicateMetadata(library, keep_track, from) catch
            return self.toast("Could not merge the metadata");
        keep_track = merged.track_id;
        if (merged.values != 0 or merged.rating or merged.feedback or merged.genres) changed = true;
    }
    jobs.reloadLibraryViews(self);
    self.toast(if (changed) "Merged metadata into the kept copy" else "The kept copy already has everything to merge");
}

fn keepBothClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const items = copyItems(self);
    if (items.len < 2) return;
    const keep = items[self.duplicates.keep].file_id;
    var others: [letters.len]i64 = undefined;
    var count: usize = 0;
    for (items, 0..) |copy, index| {
        if (index == self.duplicates.keep or count == others.len) continue;
        others[count] = copy.file_id;
        count += 1;
    }
    for (others[0..count]) |other| self.runtime.libraryKeepBoth(library, keep, other) catch
        return self.toast("Could not keep these files");
    const all = count > 1;
    advance(self);
    self.toast(if (all) "Kept every copy" else "Kept both copies");
}

fn ignoreClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    self.runtime.libraryIgnoreDuplicateGroup(library, self.duplicates.selected) catch
        return self.toast("Could not ignore this group");
    advance(self);
    self.toast("Group ignored");
}

fn advance(self: *App) void {
    const items = groups(self);
    if (selectedIndex(self)) |index| {
        if (index + 1 < items.len)
            self.duplicates.selected = items[index + 1].id
        else if (index > 0)
            self.duplicates.selected = items[index - 1].id;
    }
    health.reload(self);
}
