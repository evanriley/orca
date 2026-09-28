//! Edit Tags: Orca's own values for one or more tracks, and writing them into
//! the files.
//!
//! Saving is a library edit only. Writing is a separate, confirmed step: the
//! engine plans the write, the plan is shown, and only an approved plan runs,
//! as a job whose result can be undone.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");

const App = app.App;

const Field = struct {
    field: liborca.MetadataField,
    label: [*:0]const u8,
    /// Shown only when editing a single track: a title or a track number
    /// shared by a whole selection is never what anyone means.
    single_only: bool = false,
};

const fields = [_]Field{
    .{ .field = .title, .label = "Title", .single_only = true },
    .{ .field = .artist, .label = "Artist" },
    .{ .field = .album, .label = "Album" },
    .{ .field = .album_artist, .label = "Album Artist" },
    .{ .field = .date, .label = "Date" },
    .{ .field = .track_number, .label = "Track", .single_only = true },
    .{ .field = .disc_number, .label = "Disc" },
};

const Editor = struct {
    self: *App,
    dialog: *adw.Dialog,
    ids: []i64,
    rows: [fields.len]?*gtk.Widget = @splat(null),
    /// What each field showed when the dialog opened, or null when the
    /// selection disagreed or the value is unknown.
    initial: [fields.len]?[:0]u8 = @splat(null),

    fn destroy(editor: *Editor) void {
        const allocator = editor.self.allocator;
        for (editor.initial) |value| if (value) |text| allocator.free(text);
        allocator.free(editor.ids);
        allocator.destroy(editor);
    }
};

fn editorOf(data: ?*anyopaque) *Editor {
    return @ptrCast(@alignCast(data.?));
}

fn summaryValue(allocator: std.mem.Allocator, summary: liborca.TrackSummary, field: liborca.MetadataField) ?[]u8 {
    return switch (field) {
        .title => allocator.dupe(u8, summary.title) catch null,
        .artist => allocator.dupe(u8, summary.artist) catch null,
        .album => allocator.dupe(u8, summary.album) catch null,
        .album_artist => allocator.dupe(u8, summary.album_artist) catch null,
        .track_number => if (summary.track_number) |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch null else null,
        .disc_number => if (summary.disc_number) |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch null else null,
        else => null,
    };
}

/// The value every selected track shares, or null.
fn sharedValue(self: *App, ids: []const i64, field: liborca.MetadataField) ?[:0]u8 {
    const library = self.library orelse return null;
    var shared: ?[]u8 = null;
    defer if (shared) |value| self.allocator.free(value);
    for (ids, 0..) |id, index| {
        var value: ?[]u8 = null;
        if (self.runtime.libraryTrackSummary(library, id) catch null) |summary| {
            defer summary.deinit(self.allocator);
            value = summaryValue(self.allocator, summary, field);
        }
        if (value == null and field == .date) {
            if (self.runtime.libraryTrackEdits(library, id)) |page_value| {
                var page = page_value;
                defer page.deinit();
                for (page.items) |item| {
                    if (item.field == .date) value = self.allocator.dupe(u8, item.text) catch null;
                }
            } else |_| {}
        }
        const current = value orelse return null;
        if (index == 0) {
            shared = current;
            continue;
        }
        defer self.allocator.free(current);
        if (!std.mem.eql(u8, shared.?, current)) return null;
    }
    const value = shared orelse return null;
    if (value.len == 0) return null;
    return self.allocator.dupeSentinel(u8, value, 0) catch null;
}

fn collectEdits(editor: *Editor, edits: *std.ArrayList(liborca.TrackEdit)) !void {
    const allocator = editor.self.allocator;
    for (fields, editor.rows, editor.initial) |spec, row_value, initial| {
        const row = row_value orelse continue;
        const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, row)));
        const trimmed = std.mem.trim(u8, text, " ");
        if (initial) |before| {
            if (std.mem.eql(u8, before, trimmed)) continue;
        } else if (trimmed.len == 0) continue;
        try edits.append(allocator, .{
            .field = spec.field,
            .value = if (trimmed.len == 0) null else trimmed,
        });
    }
}

/// Applies the edits. An edit can move tracks to new ids, so the ids that now
/// hold the edited files replace the editor's.
fn save(editor: *Editor) bool {
    const self = editor.self;
    const library = self.library orelse return false;
    var edits: std.ArrayList(liborca.TrackEdit) = .empty;
    defer edits.deinit(self.allocator);
    collectEdits(editor, &edits) catch return false;
    if (edits.items.len == 0) return true;
    const edited = self.runtime.libraryEditTracks(library, editor.ids, edits.items) catch |err| {
        self.toast(if (err == error.InvalidEditValue) "Track and disc must be whole numbers" else "Could not save the tags");
        return false;
    };
    defer edited.deinit();
    if (self.allocator.dupe(i64, edited.ids)) |ids| {
        self.allocator.free(editor.ids);
        editor.ids = ids;
    } else |_| {}
    jobs.reloadLibraryViews(self);
    popPages(self);
    return true;
}

/// Album and artist pages show what they were opened with; after an edit
/// that may have moved tracks between them, they go back to their lists.
fn popPages(self: *App) void {
    if (self.albums_navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, "albums");
    if (self.artists_navigation) |navigation| _ = adw.adw_navigation_view_pop_to_tag(navigation, "artists");
}

fn saveClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    if (!save(editor)) return;
    editor.self.toast("Saved to the library");
    _ = adw.adw_dialog_close(editor.dialog);
}

fn saveAndWriteClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    if (!save(editor)) return;
    const self = editor.self;
    const ids = self.allocator.dupe(i64, editor.ids) catch return;
    defer self.allocator.free(ids);
    _ = adw.adw_dialog_close(editor.dialog);
    confirmWrite(self, ids);
}

fn cancelClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = adw.adw_dialog_close(editorOf(data).dialog);
}

fn editorClosed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    editorOf(data).destroy();
}

pub fn edit(self: *App, ids: []const i64) void {
    if (ids.len == 0) return;
    const editor = self.allocator.create(Editor) catch return;
    editor.* = .{ .self = self, .dialog = undefined, .ids = self.allocator.dupe(i64, ids) catch {
        self.allocator.destroy(editor);
        return;
    } };

    const group = adw.adw_preferences_group_new();
    for (fields, 0..) |spec, index| {
        if (spec.single_only and ids.len > 1) continue;
        const row = adw.adw_entry_row_new();
        editor.rows[index] = row;
        editor.initial[index] = sharedValue(self, ids, spec.field);
        var title_buffer: [64]u8 = undefined;
        const title: [:0]const u8 = if (editor.initial[index] == null and ids.len > 1)
            strings.printZ(&title_buffer, "{s} (mixed)", .{std.mem.span(spec.label)}) catch "Field"
        else
            std.mem.span(spec.label);
        adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title.ptr);
        if (editor.initial[index]) |value| gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, row), value.ptr);
        adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, group), row);
    }
    adw.adw_preferences_group_set_description(
        gtk.cast(adw.PreferencesGroup, group),
        "Saving changes Orca's library only. Clear a field to go back to what the file says.",
    );

    const write = gtk.gtk_button_new_with_label("Save and Write to Files…");
    gtk.gtk_widget_add_css_class(write, "pill");
    gtk.gtk_widget_set_halign(write, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_margin_top(write, 18);
    _ = gtk.signalConnect(write, "clicked", gtk.callback(saveAndWriteClicked), editor);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_margin_start(content, 18);
    gtk.gtk_widget_set_margin_end(content, 18);
    gtk.gtk_widget_set_margin_top(content, 12);
    gtk.gtk_widget_set_margin_bottom(content, 24);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), group);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), write);

    const header = adw.adw_header_bar_new();
    const cancel = gtk.gtk_button_new_with_label("Cancel");
    _ = gtk.signalConnect(cancel, "clicked", gtk.callback(cancelClicked), editor);
    const save_button = gtk.gtk_button_new_with_label("Save");
    gtk.gtk_widget_add_css_class(save_button, "suggested-action");
    _ = gtk.signalConnect(save_button, "clicked", gtk.callback(saveClicked), editor);
    adw.adw_header_bar_pack_start(gtk.cast(adw.HeaderBar, header), cancel);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), save_button);
    adw.adw_header_bar_set_show_end_title_buttons(gtk.cast(adw.HeaderBar, header), gtk.false_);
    adw.adw_header_bar_set_show_start_title_buttons(gtk.cast(adw.HeaderBar, header), gtk.false_);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), content);

    const dialog = adw.adw_dialog_new();
    editor.dialog = dialog;
    var heading_buffer: [48]u8 = undefined;
    const heading: [:0]const u8 = if (ids.len == 1) "Edit Tags" else strings.printZ(&heading_buffer, "Edit {d} Tracks", .{ids.len}) catch "Edit Tags";
    adw.adw_dialog_set_title(dialog, heading.ptr);
    adw.adw_dialog_set_content_width(dialog, 480);
    adw.adw_dialog_set_child(dialog, view);
    _ = gtk.signalConnect(dialog, "closed", gtk.callback(editorClosed), editor);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

// -------------------------------------------------------------------- write

const PendingWrite = struct {
    self: *App,
    plan_id: u64,
    digest: liborca.TagWriteDigest,
};

fn fieldLabel(field: liborca.MetadataField) []const u8 {
    for (fields) |spec| if (spec.field == field) return std.mem.span(spec.label);
    return @tagName(field);
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn writeResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const pending: *PendingWrite = @ptrCast(@alignCast(data.?));
    const self = pending.self;
    defer self.allocator.destroy(pending);
    if (std.mem.eql(u8, std.mem.span(response), "write")) {
        jobs.startTagWrite(self, pending.plan_id, pending.digest);
        return;
    }
    if (self.library) |library| self.runtime.discardTagWrite(library, pending.plan_id) catch {};
}

/// Plans writing the tracks' Orca values into their files and asks before
/// doing it. Files that cannot be written are listed with why.
pub fn confirmWrite(self: *App, ids: []const i64) void {
    const library = self.library orelse return;
    const plan = self.runtime.planTagWrite(library, self.io, ids) catch return self.toast("Could not plan the write");
    defer plan.deinit();
    if (plan.files.len == 0) {
        return self.toast(if (plan.skipped.len != 0)
            "Those files can't be written yet"
        else
            "The files already say this");
    }

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    var buffer: [768]u8 = undefined;
    for (plan.files[0..@min(plan.files.len, 6)]) |file| {
        const name = gtk.gtk_label_new(strings.terminated(&buffer, basename(file.path)).ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_MIDDLE);
        gtk.gtk_widget_add_css_class(name, "heading");
        gtk.gtk_box_append(gtk.cast(gtk.Box, list), name);
        for (file.changes) |change| {
            const line = strings.printZ(&buffer, "{s}: {s} → {s}", .{
                fieldLabel(change.field),
                change.before orelse "(none)",
                change.after orelse "(the file's own)",
            }) catch continue;
            const label = gtk.gtk_label_new(line.ptr);
            gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
            gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
            gtk.gtk_widget_add_css_class(label, "dim-label");
            gtk.gtk_box_append(gtk.cast(gtk.Box, list), label);
        }
    }
    if (plan.files.len > 6) {
        const more = gtk.gtk_label_new(strings.format(&buffer, "and {d} more", .{plan.files.len - 6}).ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, more), 0.0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, list), more);
    }
    if (plan.skipped.len != 0) {
        const skipped = gtk.gtk_label_new(strings.format(&buffer, "{d} {s} skipped: not a format Orca writes yet, missing, or changed since the last scan.", .{
            plan.skipped.len,
            if (plan.skipped.len == 1) "file is" else "files are",
        }).ptr);
        gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, skipped), gtk.true_);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, skipped), 0.0);
        gtk.gtk_widget_add_css_class(skipped, "warning");
        gtk.gtk_widget_set_margin_top(skipped, 6);
        gtk.gtk_box_append(gtk.cast(gtk.Box, list), skipped);
    }
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(gtk.cast(gtk.ScrolledWindow, scroller), 280);

    const heading: [:0]const u8 = strings.printZ(&buffer, "Write tags to {d} {s}?", .{
        plan.files.len,
        if (plan.files.len == 1) "file" else "files",
    }) catch "Write tags?";
    const dialog = adw.adw_alert_dialog_new(heading.ptr, "Orca keeps each file's original, so you can undo this afterwards.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, scroller);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "write", "Write");
    adw.adw_alert_dialog_set_response_appearance(alert, "write", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "write");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    const pending = self.allocator.create(PendingWrite) catch return;
    pending.* = .{ .self = self, .plan_id = plan.plan_id, .digest = plan.digest };
    _ = gtk.signalConnect(dialog, "response", gtk.callback(writeResponse), pending);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

/// Restores the files the last tag write changed.
pub fn undoLastWrite(self: *App) void {
    const library = self.library orelse return;
    if (self.tag_write_group == 0) return;
    self.runtime.undoTagWrite(library, self.io, self.tag_write_group) catch return self.toast("Could not undo that write");
    self.tag_write_group = 0;
    jobs.reloadLibraryViews(self);
    self.toast("The files are back as they were");
}
