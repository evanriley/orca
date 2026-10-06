//! Write to Files: the engine's plan for writing Orca's values into a
//! selection's files, shown change by change before anything is written.
//!
//! Only the plan shown runs: Write starts the job with the plan's digest, so
//! a library that changed since cannot write something else.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const metadata_editor = @import("metadata_editor.zig");
const window = @import("window.zig");

const App = app.App;

const page_key = "orca-write-tags";
const files_shown = 2;
const card_spacing: c_int = 12;

const WritePage = struct {
    self: *App,
    page: *adw.NavigationPage,
    plan: liborca.TagWritePlan,
    started: bool = false,
    table: *gtk.Widget,
    more: *gtk.Label,
    return_page: ?window.Page,
};

fn writePageOf(data: ?*anyopaque) *WritePage {
    return @ptrCast(@alignCast(data.?));
}

fn writePageOfPage(page: *adw.NavigationPage) ?*WritePage {
    return @ptrCast(@alignCast(gtk.g_object_get_data(page, page_key) orelse return null));
}

pub fn pushedOf(page: *adw.NavigationPage) ?window.Pushed {
    _ = writePageOfPage(page) orelse return null;
    return .write_tags;
}

pub fn isShown(self: *App) bool {
    const page = window.pushedPage(self, self.current_page) orelse return false;
    return writePageOfPage(page) != null;
}

pub fn fieldLabel(field: liborca.MetadataField) []const u8 {
    return switch (field) {
        .title => "Title",
        .artist => "Artist",
        .album => "Album",
        .album_artist => "Album artist",
        .date => "Date",
        .track_number => "Track",
        .disc_number => "Disc",
        .composer => "Composer",
        .comment => "Comment",
        .compilation => "Compilation",
        .explicit => "Explicit",
        .musicbrainz_recording_id => "MusicBrainz recording",
        .musicbrainz_release_id => "MusicBrainz release",
        .musicbrainz_release_group_id => "MusicBrainz release group",
        .musicbrainz_release_track_id => "MusicBrainz release track",
        .musicbrainz_album_artist_id => "MusicBrainz album artist",
    };
}

fn sourceLabel(provenance: liborca.Provenance) []const u8 {
    return switch (provenance) {
        .user => "your edit",
        .provider => "match",
        else => @tagName(provenance),
    };
}

fn fieldKey(file: liborca.TagWriteFile, field: ?liborca.MetadataField) []const u8 {
    if (file.format.key(field)) |key| return key;
    return if (field) |value| fieldLabel(value) else "Genre";
}

fn allSkippedFor(skipped: []const liborca.TagWriteSkip, reason: liborca.TagWriteSkipReason) bool {
    for (skipped) |skip| if (skip.reason != reason) return false;
    return true;
}

fn skipClause(reason: liborca.TagWriteSkipReason, count: usize) []const u8 {
    return switch (reason) {
        .missing => "missing",
        .format_not_writable => "not a format Orca writes yet",
        .changed_since_scan => "changed since the last scan",
        .folder_not_writable => if (count == 1) "Orca can't create files in its folder" else "Orca can't create files in their folders",
        .file_read_only => "read-only",
    };
}

fn changeCount(file: liborca.TagWriteFile) usize {
    return file.changes.len + @intFromBool(file.genres != null);
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn namesEql(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

/// Whether two files change the same fields from the same values to the
/// same values.
fn sameChanges(a: liborca.TagWriteFile, b: liborca.TagWriteFile) bool {
    if (a.changes.len != b.changes.len) return false;
    for (a.changes, b.changes) |left, right| {
        if (left.field != right.field) return false;
        if (!optionalEql(left.before, right.before) or !optionalEql(left.after, right.after)) return false;
    }
    const left = a.genres orelse return b.genres == null;
    const right = b.genres orelse return false;
    return namesEql(left.before, right.before) and namesEql(left.after, right.after);
}

fn joinNames(buffer: []u8, names: []const []const u8) [:0]const u8 {
    if (names.len == 0) return "(none)";
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    for (names, 0..) |name, index| {
        if (index != 0) writer.writeAll(" / ") catch break;
        writer.writeAll(name) catch break;
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn cell(text: []const u8, class: [*:0]const u8, first: bool) *gtk.Widget {
    var buffer: [1024]u8 = undefined;
    const widget = gtk.gtk_label_new(strings.terminated(&buffer, text).ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, widget), gtk.WRAP_WORD_CHAR);
    gtk.gtk_widget_set_hexpand(widget, gtk.true_);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_FILL);
    gtk.gtk_label_set_yalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_widget_add_css_class(widget, "write-cell");
    gtk.gtk_widget_add_css_class(widget, class);
    if (first) gtk.gtk_widget_add_css_class(widget, "write-group-first");
    return widget;
}

fn appendRow(table: *gtk.Grid, row: c_int, cells: [4]*gtk.Widget) void {
    for (cells, 0..) |widget, column| gtk.gtk_grid_attach(table, widget, @intCast(column), row, 1, 1);
}

fn fillTable(write: *WritePage, all: bool) void {
    const table = gtk.cast(gtk.Grid, write.table);
    while (gtk.gtk_widget_get_first_child(write.table)) |child| gtk.gtk_grid_remove(table, child);
    const file_heading = cell("File", "write-heading", false);
    gtk.gtk_widget_add_css_class(file_heading, "write-file-heading");
    appendRow(table, 0, .{
        file_heading,
        cell("Field", "write-heading", false),
        cell("Before", "write-heading", false),
        cell("After", "write-heading", false),
    });
    const files = write.plan.files;
    const shown = if (all) files.len else @min(files.len, files_shown);
    var row: c_int = 1;
    var buffer: [1024]u8 = undefined;
    for (files[0..shown]) |file| {
        var first = true;
        var genres_shown = file.genres == null;
        const name = std.Io.Dir.path.basename(file.path);
        for (file.changes) |change| {
            if (!genres_shown and @backingInt(change.field) >= @backingInt(liborca.MetadataField.date)) {
                appendGenresRow(table, &row, file, name, &first);
                genres_shown = true;
            }
            appendRow(table, row, .{
                cell(if (first) name else "", "write-file", first),
                cell(fieldKey(file, change.field), "write-field", first),
                cell(change.before orelse "(none)", "write-before", first),
                cell(change.after orelse "(none)", "write-after", first),
            });
            first = false;
            row += 1;
        }
        if (!genres_shown) appendGenresRow(table, &row, file, name, &first);
    }

    const more = gtk.cast(gtk.Widget, write.more);
    if (shown == files.len) {
        gtk.gtk_widget_set_visible(more, gtk.false_);
        return;
    }
    var total: usize = 0;
    for (files) |file| total += changeCount(file);
    const rest = files[shown..];
    const same = for (rest) |file| {
        if (!sameChanges(file, files[0])) break false;
    } else true;
    const text = if (same)
        strings.format(&buffer, "and the same {d} {s} on {d} more {s} · <a href=\"all\">Show all {d} changes</a>", .{
            changeCount(files[0]),
            if (changeCount(files[0]) == 1) "change" else "changes",
            rest.len,
            if (rest.len == 1) "file" else "files",
            total,
        })
    else
        strings.format(&buffer, "and changes on {d} more {s} · <a href=\"all\">Show all {d} changes</a>", .{
            rest.len,
            if (rest.len == 1) "file" else "files",
            total,
        });
    gtk.gtk_label_set_markup(write.more, text.ptr);
    gtk.gtk_widget_set_visible(more, gtk.true_);
}

fn appendGenresRow(table: *gtk.Grid, row: *c_int, file: liborca.TagWriteFile, name: []const u8, first: *bool) void {
    const genres = file.genres orelse return;
    var before_buffer: [1024]u8 = undefined;
    var after_buffer: [1024]u8 = undefined;
    appendRow(table, row.*, .{
        cell(if (first.*) name else "", "write-file", first.*),
        cell(fieldKey(file, null), "write-field", first.*),
        cell(joinNames(&before_buffer, genres.before), "write-before", first.*),
        cell(joinNames(&after_buffer, genres.after), "write-after", first.*),
    });
    first.* = false;
    row.* += 1;
}

fn showAllActivated(_: ?*anyopaque, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    fillTable(writePageOf(data), true);
    return gtk.true_;
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_widget_add_css_class(widget, class);
    return widget;
}

fn card(title: [:0]const u8, subtitle: [:0]const u8) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_add_css_class(box, "write-card");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), label(title.ptr, "write-card-title"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), label(subtitle.ptr, "write-card-subtitle"));
    return box;
}

fn fieldsCard(plan: liborca.TagWritePlan) *gtk.Widget {
    var seen: std.EnumSet(liborca.MetadataField) = .empty;
    var genres = false;
    for (plan.files) |file| {
        for (file.changes) |change| seen.insert(change.field);
        if (file.genres != null) genres = true;
    }
    var names: [32][]const u8 = undefined;
    var count: usize = 0;
    var iterator = seen.iterator();
    while (iterator.next()) |field| {
        if (field == .date and genres) {
            names[count] = "Genre";
            count += 1;
            genres = false;
        }
        names[count] = fieldLabel(field);
        count += 1;
    }
    if (genres) {
        names[count] = "Genre";
        count += 1;
    }
    var title_buffer: [32]u8 = undefined;
    const title = strings.format(&title_buffer, "{d} {s}", .{ count, if (count == 1) "field" else "fields" });
    var subtitle_buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(subtitle_buffer[0 .. subtitle_buffer.len - 1]);
    for (names[0..count], 0..) |name, index| {
        if (index != 0) writer.writeAll(" · ") catch break;
        writer.writeAll(name) catch break;
    }
    subtitle_buffer[writer.end] = 0;
    return card(title, subtitle_buffer[0..writer.end :0]);
}

fn formatCard(plan: liborca.TagWritePlan) *gtk.Widget {
    var vorbis = false;
    var id3 = false;
    for (plan.files) |file| switch (file.format) {
        .vorbis_comment => vorbis = true,
        .id3v2 => id3 = true,
    };
    if (vorbis and id3) return card("Vorbis comments and ID3v2", "FLAC, MP3 and AAC · no audio data is touched");
    if (id3) return card("ID3v2 tags", "MP3 and AAC · no audio data is touched");
    return card("Vorbis comments", "FLAC · no audio data is touched");
}

fn notes(write: *WritePage) ?*gtk.Widget {
    const plan = write.plan;
    if (plan.conflicts.len == 0 and plan.skipped.len == 0) return null;
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    var buffer: [768]u8 = undefined;
    if (plan.conflicts.len != 0) {
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), label(strings.format(&buffer, "Not written: {d} {s} the file disagrees with", .{
            plan.conflicts.len,
            if (plan.conflicts.len == 1) "match" else "matches",
        }).ptr, "write-note"));
        for (plan.conflicts[0..@min(plan.conflicts.len, 6)]) |conflict| {
            const line = strings.format(&buffer, "{s} — {s}: file {s}, Orca {s} ({s})", .{
                std.Io.Dir.path.basename(conflict.path),
                fieldLabel(conflict.field),
                conflict.file_value,
                conflict.orca_value,
                sourceLabel(conflict.provenance),
            });
            gtk.gtk_box_append(gtk.cast(gtk.Box, box), label(line.ptr, "write-note"));
        }
        if (plan.conflicts.len > 6)
            gtk.gtk_box_append(gtk.cast(gtk.Box, box), label(strings.format(&buffer, "and {d} more", .{plan.conflicts.len - 6}).ptr, "write-note"));
    }
    var skip_counts: std.EnumArray(liborca.TagWriteSkipReason, usize) = .initFill(0);
    for (plan.skipped) |skip| skip_counts.getPtr(skip.reason).* += 1;
    for (std.enums.values(liborca.TagWriteSkipReason)) |reason| {
        const count = skip_counts.get(reason);
        if (count == 0) continue;
        const line = label(strings.format(&buffer, "{d} {s} skipped: {s}.", .{
            count,
            if (count == 1) "file is" else "files are",
            skipClause(reason, count),
        }).ptr, "write-note");
        gtk.gtk_widget_add_css_class(line, "warning");
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), line);
    }
    return box;
}

fn undoCard() *gtk.Widget {
    const words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    const title = label("Keep original tags for undo", "write-toggle-title");
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), label("Orca records this operation so you can restore every file", "write-toggle-subtitle"));
    const toggle = gtk.gtk_switch_new();
    gtk.gtk_switch_set_active(gtk.cast(gtk.Switch, toggle), gtk.true_);
    gtk.gtk_widget_set_sensitive(toggle, gtk.false_);
    gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(toggle, "first-run-switch");
    gtk.gtk_widget_add_css_class(toggle, "settings-fixed");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, toggle), gtk.ACCESSIBLE_PROPERTY_LABEL, "Keep original tags for undo", @as(c_int, -1));
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(row, "write-toggle");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), words);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), toggle);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(box, "write-toggles");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), row);
    return box;
}

fn editorBelow(write: *WritePage) ?*adw.NavigationPage {
    const navigation = window.pageNavigation(write.self, write.self.current_page) orelse return null;
    const previous = adw.adw_navigation_view_get_previous_page(navigation, write.page) orelse return null;
    return if (metadata_editor.isEditorPage(previous)) previous else null;
}

fn backClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const write = writePageOf(data);
    metadata_editor.leave(write.self, write.page, write.return_page);
}

fn writeClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const write = writePageOf(data);
    const self = write.self;
    if (write.started) return;
    if (!jobs.startTagWrite(self, write.plan.plan_id, write.plan.digest)) return;
    write.started = true;
    if (editorBelow(write)) |editor| return metadata_editor.closePage(editor);
    metadata_editor.leave(self, write.page, write.return_page);
}

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const write = writePageOf(data);
    const self = write.self;
    gtk.g_object_set_data(write.page, page_key, null);
    if (!write.started) if (self.library) |library| self.runtime.discardTagWrite(library, write.plan.plan_id) catch {};
    write.plan.deinit();
    self.allocator.destroy(write);
}

fn button(text: [*:0]const u8, icon: ?[*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    if (icon) |name| {
        const image = gtk.gtk_image_new_from_icon_name(name);
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), 16);
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), image);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(text));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, widget), content);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_widget_add_css_class(widget, "write-button");
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_END);
    return widget;
}

/// Plans writing the Tracks' Orca values into their files and shows the
/// plan on a page of its own. Nothing is written until Write is pressed.
pub fn open(self: *App, ids: []const i64) void {
    const library = self.library orelse return;
    const plan = self.runtime.planTagWrite(library, self.io, ids) catch return self.toast("Could not plan the write");
    if (plan.files.len == 0) {
        defer plan.deinit();
        return self.toast(if (plan.conflicts.len != 0)
            "The files' own tags disagree with Orca's matches; edit a field to lock your choice"
        else if (plan.skipped.len != 0 and allSkippedFor(plan.skipped, .folder_not_writable))
            "Orca can't create files in those folders; check their permissions"
        else if (plan.skipped.len != 0 and allSkippedFor(plan.skipped, .file_read_only))
            "Those files are read-only; Orca leaves read-only files as they are"
        else if (plan.skipped.len != 0)
            "Those files can't be written yet"
        else
            "No changes to write");
    }
    const editing_shown = metadata_editor.isShown(self);
    const target = metadata_editor.host(self) orelse {
        self.runtime.discardTagWrite(library, plan.plan_id) catch {};
        plan.deinit();
        return;
    };
    const write = self.allocator.create(WritePage) catch {
        self.runtime.discardTagWrite(library, plan.plan_id) catch {};
        plan.deinit();
        return self.toast("Out of memory");
    };
    const more = gtk.gtk_label_new("");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, more), 0);
    gtk.gtk_widget_add_css_class(more, "write-more");
    const table = gtk.gtk_grid_new();
    gtk.gtk_widget_add_css_class(table, "write-table");
    write.* = .{
        .self = self,
        .page = undefined,
        .plan = plan,
        .table = table,
        .more = gtk.cast(gtk.Label, more),
        .return_page = target.return_page,
    };
    _ = gtk.signalConnect(more, "activate-link", gtk.callback(showAllActivated), write);
    fillTable(write, false);

    var buffer: [64]u8 = undefined;
    const files = plan.files.len;
    const heading_words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_hexpand(heading_words, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading_words), label(strings.format(&buffer, "Write tags to {d} {s}", .{
        files,
        if (files == 1) "file" else "files",
    }).ptr, "write-heading-title"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading_words), label(
        "Review exactly what will change on disk. Nothing is written until you confirm.",
        "write-heading-subtitle",
    ));

    const back = button(if (editing_shown) "Back to Editor" else "Cancel", null, "btn-secondary");
    _ = gtk.signalConnect(back, "clicked", gtk.callback(backClicked), write);
    const write_button = button(strings.format(&buffer, "Write {d} {s}", .{
        files,
        if (files == 1) "File" else "Files",
    }).ptr, "orca-pen-symbolic", "btn-primary");
    _ = gtk.signalConnect(write_button, "clicked", gtk.callback(writeClicked), write);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_set_valign(actions, gtk.ALIGN_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), back);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), write_button);
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 24);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), heading_words);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), actions);

    const cards = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, card_spacing);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, cards), gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, cards), fieldsCard(plan));
    gtk.gtk_box_append(gtk.cast(gtk.Box, cards), formatCard(plan));

    const section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), label("CHANGES PER FILE", "write-section"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), table);
    gtk.gtk_box_append(gtk.cast(gtk.Box, section), more);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 22);
    gtk.gtk_widget_add_css_class(content, "write-tags");
    for ([_]*gtk.Widget{ header, cards, section }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, content), child);
    if (notes(write)) |box| gtk.gtk_box_append(gtk.cast(gtk.Box, content), box);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), undoCard());

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), content);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(destroyed), write);

    const page = adw.adw_navigation_page_new(scroller, "Write to Files");
    write.page = page;
    gtk.g_object_set_data(page, page_key, write);
    adw.adw_navigation_view_push(target.navigation, page);
}
