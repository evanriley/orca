//! The Change History page: every tag write Orca has made, newest first, and
//! the selected one's changed fields. The list is `libraryTagWriteGroupPage`;
//! the detail is `libraryTagWriteGroup`, read on its own thread because it
//! reads every changed file's tags. Undoing and exporting are the runtime's.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const tags = @import("tags.zig");

const App = app.App;

const group_limit: u32 = 500;

const Loader = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    group_id: u64,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    detail: ?liborca.TagWriteGroupDetail = null,

    fn run(self: *Loader) void {
        self.detail = self.runtime.libraryTagWriteGroup(
            self.library,
            std.heap.smp_allocator,
            self.threaded.io(),
            self.group_id,
        ) catch null;
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn destroy(self: *Loader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.detail) |detail| detail.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

pub const State = struct {
    list: ?*gtk.Box = null,
    empty: ?*gtk.Widget = null,
    detail: ?*gtk.Widget = null,
    scope: ?*gtk.Label = null,
    heading: ?*gtk.Label = null,
    subtitle: ?*gtk.Label = null,
    table: ?*gtk.Box = null,
    more: ?*gtk.Label = null,
    undo: ?*gtk.Widget = null,
    page: ?liborca.TagWriteGroupPage = null,
    selected: u64 = 0,
    shown_detail: ?liborca.TagWriteGroupDetail = null,
    loader: ?*Loader = null,
    wanted: u64 = 0,
    stale: bool = true,

    pub fn deinit(self: *State) void {
        if (self.page) |page| page.deinit();
        self.page = null;
        if (self.shown_detail) |detail| detail.deinit();
        self.shown_detail = null;
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

fn wrapped(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    return widget;
}

fn heightForWidth(_: *gtk.Widget) callconv(.c) c_int {
    return 0;
}

fn Limited(comptime max_width: c_int) type {
    return struct {
        fn measure(
            widget: *gtk.Widget,
            orientation: c_int,
            for_size: c_int,
            minimum: *c_int,
            natural: *c_int,
            minimum_baseline: *c_int,
            natural_baseline: *c_int,
        ) callconv(.c) void {
            minimum.* = 0;
            natural.* = 0;
            minimum_baseline.* = -1;
            natural_baseline.* = -1;
            const child = gtk.gtk_widget_get_first_child(widget) orelse return;
            if (orientation == gtk.ORIENTATION_HORIZONTAL) {
                gtk.gtk_widget_measure(child, orientation, for_size, minimum, natural, null, null);
                natural.* = @max(minimum.*, @min(natural.*, max_width));
            } else {
                const width = if (for_size >= 0) @min(for_size, max_width) else max_width;
                gtk.gtk_widget_measure(child, orientation, width, minimum, natural, null, null);
            }
        }

        fn allocate(widget: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
            const child = gtk.gtk_widget_get_first_child(widget) orelse return;
            var child_minimum: c_int = 0;
            gtk.gtk_widget_measure(child, gtk.ORIENTATION_HORIZONTAL, -1, &child_minimum, null, null, null);
            const child_width = @min(width, @max(max_width, child_minimum));
            gtk.gtk_widget_size_allocate(child, &.{ .x = 0, .y = 0, .width = child_width, .height = height }, -1);
        }
    };
}

fn limited(child: *gtk.Widget, comptime max_width: c_int) *gtk.Widget {
    const layout = Limited(max_width);
    const wrapper = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_layout_manager(wrapper, gtk.gtk_custom_layout_new(@ptrCast(&heightForWidth), layout.measure, layout.allocate));
    gtk.gtk_box_append(gtk.cast(gtk.Box, wrapper), child);
    return wrapper;
}

fn groups(self: *App) []const liborca.TagWriteGroup {
    return if (self.changes.page) |page| page.items else &.{};
}

fn selectedGroup(self: *App) ?*const liborca.TagWriteGroup {
    for (groups(self)) |*group| if (group.group_id == self.changes.selected) return group;
    return null;
}

fn stateLabel(group: *const liborca.TagWriteGroup) [*:0]const u8 {
    return switch (group.state) {
        .needs_reconciliation => "Needs attention",
        .failed => "Failed",
        .undoing => "Undoing",
        .rolled_back => "Rolled back",
        .undone => "Undone",
        .applied => if (group.can_undo) "Can undo" else if (group.expired) "Expired" else "Needs attention",
    };
}

fn dayKey(buffer: []u8, moment: *gtk.GDateTime) []const u8 {
    const text = gtk.g_date_time_format(moment, "%F") orelse return "";
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

const Day = enum { today, yesterday, this_year, earlier };

fn dayOf(unix_seconds: i64) Day {
    const now = gtk.g_date_time_new_now_local() orelse return .earlier;
    defer gtk.g_date_time_unref(now);
    var day_buffer: [16]u8 = undefined;
    var other_buffer: [16]u8 = undefined;
    const day = localTime(&day_buffer, unix_seconds, "%F");
    if (std.mem.eql(u8, day, dayKey(&other_buffer, now))) return .today;
    if (gtk.g_date_time_add_days(now, -1)) |yesterday| {
        defer gtk.g_date_time_unref(yesterday);
        if (std.mem.eql(u8, day, dayKey(&other_buffer, yesterday))) return .yesterday;
    }
    const today = dayKey(&other_buffer, now);
    if (day.len >= 4 and today.len >= 4 and std.mem.eql(u8, day[0..4], today[0..4])) return .this_year;
    return .earlier;
}

fn localTime(buffer: []u8, unix_seconds: i64, pattern: [*:0]const u8) [:0]const u8 {
    const moment = gtk.g_date_time_new_from_unix_local(unix_seconds) orelse return "";
    defer gtk.g_date_time_unref(moment);
    const text = gtk.g_date_time_format(moment, pattern) orelse return "";
    defer gtk.g_free(text);
    return strings.terminated(buffer, std.mem.span(text));
}

fn when(buffer: []u8, unix_seconds: i64) [:0]const u8 {
    return switch (dayOf(unix_seconds)) {
        .today => localTime(buffer, unix_seconds, "%H:%M"),
        .yesterday => strings.terminated(buffer, "Yesterday"),
        .this_year => localTime(buffer, unix_seconds, "%b %-d"),
        .earlier => localTime(buffer, unix_seconds, "%b %-d, %Y"),
    };
}

fn scopeText(buffer: []u8, unix_seconds: i64) [:0]const u8 {
    var time_buffer: [16]u8 = undefined;
    const time = localTime(&time_buffer, unix_seconds, "%H:%M");
    var day_buffer: [32]u8 = undefined;
    const day: []const u8 = switch (dayOf(unix_seconds)) {
        .today => "today",
        .yesterday => "yesterday",
        .this_year => localTime(&day_buffer, unix_seconds, "%b %-d"),
        .earlier => localTime(&day_buffer, unix_seconds, "%b %-d, %Y"),
    };
    return strings.format(buffer, "Files on disk · {s} {s}", .{ day, time });
}

fn wroteText(buffer: []u8, files: u64) [:0]const u8 {
    return strings.format(buffer, "Wrote tags to {d} {s}", .{ files, if (files == 1) "file" else "files" });
}

fn fieldName(subject: liborca.TagWriteDiffSubject) [*:0]const u8 {
    return switch (subject) {
        .genres => "GENRE",
        .unknown => "All tags",
        .field => |field| switch (field) {
            .title => "TITLE",
            .artist => "ARTIST",
            .album => "ALBUM",
            .track_number => "TRACKNUMBER",
            .album_artist => "ALBUMARTIST",
            .disc_number => "DISCNUMBER",
            .date => "DATE",
            .compilation => "COMPILATION",
            .musicbrainz_recording_id => "MUSICBRAINZ_TRACKID",
            .musicbrainz_release_id => "MUSICBRAINZ_ALBUMID",
            .musicbrainz_release_group_id => "MUSICBRAINZ_RELEASEGROUPID",
            .musicbrainz_release_track_id => "MUSICBRAINZ_RELEASETRACKID",
            .musicbrainz_album_artist_id => "MUSICBRAINZ_ALBUMARTISTID",
            .explicit => "ITUNESADVISORY",
            .composer => "COMPOSER",
            .comment => "COMMENT",
        },
    };
}

pub fn build(self: *App) *gtk.Widget {
    buildTrail(self);

    const title = page_ui.title("Change History");
    gtk.gtk_widget_add_css_class(title.widget, "changes-title");
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, title.meta), gtk.false_);
    const description = wrapped("Every change Orca has made, newest first. Database changes can always be undone. File changes can be undone while their original tags are kept (90 days by default).", "changes-description");
    gtk.gtk_widget_add_css_class(description, "meta");
    const text_box = gtk.gtk_widget_get_parent(gtk.cast(gtk.Widget, title.meta)) orelse unreachable;
    gtk.gtk_box_append(gtk.cast(gtk.Box, text_box), limited(description, 720));

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(list, "changes-list");
    self.changes.list = gtk.cast(gtk.Box, list);
    const empty = label("Orca hasn't written tags to any files yet.", "changes-empty");
    gtk.gtk_widget_set_visible(empty, gtk.false_);
    self.changes.empty = empty;
    const list_column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(list_column, &.{ list, empty });
    const list_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, list_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, list_scroller), list_column);
    gtk.gtk_widget_set_size_request(list_scroller, 487, -1);
    gtk.gtk_widget_set_hexpand(list_scroller, gtk.false_);
    gtk.gtk_widget_add_css_class(list_scroller, "changes-operations");

    const split = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(split, "changes-split");
    gtk.gtk_widget_set_vexpand(split, gtk.true_);
    const detail = buildDetail(self);
    append(split, &.{ list_scroller, detail });

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "changes-page");
    append(column, &.{ title.widget, split });
    const bin = page_ui.breakpointBin(column);
    page_ui.stackBelow(bin, "max-width: 880px", &.{split}, &.{ list_scroller, detail });
    return bin;
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Activity");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(activityClicked), self);
    const separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(separator, "breadcrumb-separator");
    const current = gtk.gtk_label_new("Change History");
    gtk.gtk_widget_add_css_class(current, "breadcrumb-current");
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, separator, current });
    page_ui.addTrail(self, .changes, crumbs);
}

fn activityClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .activity);
}

fn buildDetail(self: *App) *gtk.Widget {
    const scope = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 7);
    gtk.gtk_widget_add_css_class(scope, "changes-scope");
    const scope_label = label("", "changes-scope-label");
    self.changes.scope = gtk.cast(gtk.Label, scope_label);
    append(scope, &.{ icon("orca-file-symbolic", 14), scope_label });
    const heading = label("", "changes-heading");
    self.changes.heading = gtk.cast(gtk.Label, heading);
    const subtitle = label("", "changes-subtitle");
    self.changes.subtitle = gtk.cast(gtk.Label, subtitle);
    const header = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    append(header, &.{ scope, heading, subtitle });

    const table = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    self.changes.table = gtk.cast(gtk.Box, table);
    const more = label("", "changes-more");
    self.changes.more = gtk.cast(gtk.Label, more);

    const note_text = wrapped("Undo writes the original tags back and restores the previous artwork. If a file has changed since (for example, edited in another app), Orca skips it and lists it so nothing you did elsewhere is overwritten.", "changes-note-text");
    gtk.gtk_widget_set_hexpand(note_text, gtk.true_);
    const note_icon = icon("orca-info-symbolic", 16);
    gtk.gtk_widget_set_valign(note_icon, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(note_icon, "changes-note-icon");
    const note = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(note, "changes-note");
    append(note, &.{ note_icon, note_text });

    const undo_content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    append(undo_content, &.{ icon("orca-undo-symbolic", 16), gtk.gtk_label_new("Undo This Change…") });
    const undo = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, undo), undo_content);
    gtk.gtk_widget_add_css_class(undo, "changes-undo");
    _ = gtk.signalConnect(undo, "clicked", gtk.callback(undoClicked), self);
    self.changes.undo = undo;
    const export_log = gtk.gtk_button_new_with_label("Export Log");
    gtk.gtk_widget_add_css_class(export_log, "flat");
    gtk.gtk_widget_add_css_class(export_log, "changes-export");
    _ = gtk.signalConnect(export_log, "clicked", gtk.callback(exportClicked), self);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "changes-actions");
    append(actions, &.{ undo, export_log });

    const detail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_add_css_class(detail, "changes-detail");
    append(detail, &.{ header, table, more, limited(note, 760), actions });
    self.changes.detail = detail;

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), detail);
    return scroller;
}

pub fn shown(self: *App) void {
    if (self.changes.stale) reload(self);
}

pub fn invalidate(self: *App) void {
    self.changes.stale = true;
    if (self.current_page == .changes) reload(self);
}

fn reload(self: *App) void {
    const changes = &self.changes;
    const list = changes.list orelse return;
    changes.stale = false;
    if (changes.page) |page| page.deinit();
    changes.page = null;
    if (self.library) |library|
        changes.page = self.runtime.libraryTagWriteGroupPage(library, self.allocator, group_limit, 0) catch null;

    clear(list);
    const items = groups(self);
    if (selectedGroup(self) == null) changes.selected = if (items.len != 0) items[0].group_id else 0;
    for (items, 0..) |*group, index| gtk.gtk_box_append(list, row(self, group, index));
    gtk.gtk_widget_set_visible(changes.empty.?, @intFromBool(items.len == 0));
    showSelected(self, true);
}

fn row(self: *App, group: *const liborca.TagWriteGroup, index: usize) *gtk.Widget {
    const tile = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tile, "changes-tile");
    gtk.gtk_widget_set_valign(tile, gtk.ALIGN_CENTER);
    const tile_icon = icon("orca-file-symbolic", 16);
    gtk.gtk_widget_set_valign(tile_icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_halign(tile_icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_size_request(tile_icon, 30, 30);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tile), tile_icon);

    var title_buffer: [64]u8 = undefined;
    const title = label(wroteText(&title_buffer, group.file_count), "changes-row-title");
    var subtitle_buffer: [260]u8 = undefined;
    const subtitle = label(strings.terminated(&subtitle_buffer, group.title.slice()), "changes-row-subtitle");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ title, subtitle });

    var when_buffer: [32]u8 = undefined;
    const time = label(when(&when_buffer, group.written_at), "changes-row-time");
    const status = label(stateLabel(group), "changes-row-status");
    for ([_]*gtk.Widget{ time, status }) |widget| gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 1.0);
    const end = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_set_valign(end, gtk.ALIGN_CENTER);
    append(end, &.{ time, status });

    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    append(content, &.{ tile, text, end });
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "changes-row");
    if (group.expired and !group.can_undo) gtk.gtk_widget_add_css_class(button, "expired");
    gtk.g_object_set_data(button, "orca-group", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(button, "clicked", gtk.callback(rowClicked), self);
    return button;
}

fn rowClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tagged = gtk.g_object_get_data(button.?, "orca-group") orelse return;
    const index = @intFromPtr(tagged) - 1;
    const items = groups(self);
    if (index >= items.len or items[index].group_id == self.changes.selected) return;
    self.changes.selected = items[index].group_id;
    showSelected(self, false);
}

fn syncRows(self: *App) void {
    const list = self.changes.list orelse return;
    const items = groups(self);
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list));
    var index: usize = 0;
    while (child) |widget| : (index += 1) {
        const selected = index < items.len and items[index].group_id == self.changes.selected;
        if (selected) gtk.gtk_widget_add_css_class(widget, "selected") else gtk.gtk_widget_remove_css_class(widget, "selected");
        child = gtk.gtk_widget_get_next_sibling(widget);
    }
}

fn showSelected(self: *App, reload_detail: bool) void {
    const changes = &self.changes;
    syncRows(self);
    if (changes.shown_detail) |detail| {
        if (reload_detail or detail.group.group_id != changes.selected) {
            detail.deinit();
            changes.shown_detail = null;
        }
    }
    const group = selectedGroup(self) orelse {
        gtk.gtk_widget_set_visible(changes.detail.?, gtk.false_);
        return;
    };
    gtk.gtk_widget_set_visible(changes.detail.?, gtk.true_);
    var buffer: [128]u8 = undefined;
    gtk.gtk_label_set_text(changes.scope.?, scopeText(&buffer, group.written_at));
    gtk.gtk_label_set_text(changes.heading.?, wroteText(&buffer, group.file_count));
    gtk.gtk_widget_set_sensitive(changes.undo.?, @intFromBool(group.can_undo));
    showDetail(self);
    if (changes.shown_detail == null) load(self, group.group_id);
}

fn showDetail(self: *App) void {
    const changes = &self.changes;
    const group = selectedGroup(self) orelse return;
    const detail: ?*const liborca.TagWriteGroupDetail = if (changes.shown_detail) |*shown_detail| shown_detail else null;

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (group.title.slice().len != 0) writer.print("{s} · ", .{group.title.slice()}) catch {};
    if (detail) |loaded|
        writer.print("{d} field {s} · ", .{ loaded.field_count, if (loaded.field_count == 1) "change" else "changes" }) catch {};
    writer.print("operation #{f}", .{strings.grouped(group.group_id)}) catch {};
    buffer[writer.end] = 0;
    gtk.gtk_label_set_text(changes.subtitle.?, buffer[0..writer.end :0]);

    const table = changes.table.?;
    clear(table);
    const more_files = if (detail) |loaded| loaded.more_files else 0;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, changes.more.?), @intFromBool(more_files != 0));
    var more_buffer: [96]u8 = undefined;
    gtk.gtk_label_set_text(changes.more.?, strings.format(&more_buffer, "and {d} more {s} with the same changes", .{ more_files, if (more_files == 1) "file" else "files" }));
    const loaded = detail orelse return;

    const grid = gtk.gtk_grid_new();
    gtk.gtk_widget_add_css_class(grid, "changes-table");
    const cells = gtk.cast(gtk.Grid, grid);
    const headers = [_][*:0]const u8{ "File", "Field", "Undo restores", "Current" };
    for (headers, 0..) |text, column| {
        const header = label(text, "changes-column");
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, header), gtk.ELLIPSIZE_NONE);
        gtk.gtk_grid_attach(cells, header, @intCast(column), 0, 1, 1);
    }
    var grid_row: c_int = 1;
    var previous: []const u8 = "";
    for (loaded.diffs) |diff| {
        const first = !std.mem.eql(u8, diff.file, previous) or grid_row == 1;
        previous = diff.file;
        if (first) {
            const divider = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
            gtk.gtk_widget_add_css_class(divider, "changes-divider");
            gtk.gtk_grid_attach(cells, divider, 0, grid_row, 4, 1);
            grid_row += 1;
        }
        var file_buffer: [512]u8 = undefined;
        const file = label(if (first) strings.terminated(&file_buffer, std.fs.path.basename(diff.file)) else "", "changes-file");
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, file), gtk.ELLIPSIZE_MIDDLE);
        gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, file), 34);
        if (first) gtk.gtk_widget_set_tooltip_text(file, strings.terminated(&file_buffer, diff.file));
        const unknown = diff.subject == .unknown;
        var restores_buffer: [512]u8 = undefined;
        var current_buffer: [512]u8 = undefined;
        const restores = label(value(&restores_buffer, diff.restores, unknown), "changes-restores");
        const current = label(value(&current_buffer, diff.current, unknown), "changes-current");
        for ([_]*gtk.Widget{ restores, current }) |widget| {
            gtk.gtk_widget_set_hexpand(widget, gtk.true_);
            gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, widget), 36);
        }
        const cells_row = [_]*gtk.Widget{ file, label(fieldName(diff.subject), "changes-field"), restores, current };
        for (cells_row, 0..) |cell, column| gtk.gtk_grid_attach(cells, cell, @intCast(column), grid_row, 1, 1);
        grid_row += 1;
    }
    gtk.gtk_box_append(table, grid);
}

fn value(buffer: []u8, text: []const u8, unknown: bool) [:0]const u8 {
    if (unknown or text.len == 0) return strings.terminated(buffer, "—");
    return strings.terminated(buffer, text);
}

fn load(self: *App, group_id: u64) void {
    const changes = &self.changes;
    if (changes.loader != null) {
        changes.wanted = group_id;
        return;
    }
    changes.wanted = 0;
    const library = self.library orelse return;
    const loader = self.allocator.create(Loader) catch return;
    loader.* = .{ .runtime = self.runtime, .library = library, .group_id = group_id, .waker = self.waker() };
    loader.thread = std.Thread.spawn(.{}, Loader.run, .{loader}) catch {
        loader.destroy(self.allocator);
        return self.toast("Could not load that change");
    };
    changes.loader = loader;
}

pub fn tick(self: *App) void {
    const changes = &self.changes;
    const loader = changes.loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    changes.loader = null;
    defer loader.destroy(self.allocator);
    const wanted = changes.wanted;
    if (wanted != 0) {
        changes.wanted = 0;
        if (wanted == changes.selected and changes.shown_detail == null) load(self, wanted);
        return;
    }
    if (loader.group_id != changes.selected or changes.shown_detail != null) return;
    changes.shown_detail = loader.detail;
    loader.detail = null;
    showDetail(self);
}

pub fn shutdown(self: *App) void {
    if (self.changes.loader) |loader| loader.destroy(self.allocator);
    self.changes.loader = null;
}

pub fn forgetLibrary(self: *App) void {
    shutdown(self);
    self.changes.deinit();
    self.changes.selected = 0;
    self.changes.wanted = 0;
    self.changes.stale = true;
}

const UndoRequest = struct {
    self: *App,
    group_id: u64,
};

fn undoClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const group = selectedGroup(self) orelse return;
    if (!group.can_undo) return;
    const request = self.allocator.create(UndoRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .group_id = group.group_id };
    var buffer: [160]u8 = undefined;
    const body = strings.format(&buffer, "Orca writes the original tags back to {d} {s}. Files changed since are skipped.", .{
        group.file_count,
        if (group.file_count == 1) "file" else "files",
    });
    const dialog = adw.adw_alert_dialog_new("Undo this change?", body.ptr);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "undo", "Undo");
    adw.adw_alert_dialog_set_response_appearance(alert, "undo", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "undo");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(undoResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn undoResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *UndoRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    defer self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "undo")) return;
    if (!tags.undoWrite(self, request.group_id)) invalidate(self);
}

fn exportClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.library == null) return self.toast("No library is open");
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Export Change Log");
    gtk.gtk_file_dialog_set_initial_name(dialog, "Orca Change History.txt");
    gtk.gtk_file_dialog_save(dialog, self.window, null, exportChosen, self);
    gtk.g_object_unref(dialog);
}

fn exportChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_save_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse return self.toast("That file is not on the local filesystem");
    defer gtk.g_free(path_pointer);
    const library = self.library orelse return;
    const exported = self.runtime.exportTagWriteHistory(library, self.io, std.mem.span(path_pointer), .{ .replace = true }) catch
        return self.toast("Could not export the change log");
    var buffer: [96]u8 = undefined;
    self.toast(strings.format(&buffer, "Exported {d} {s}", .{ exported.groups, if (exported.groups == 1) "change" else "changes" }));
}
