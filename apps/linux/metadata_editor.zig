//! Edit Metadata: Orca's own values for a selection of Tracks, as a page.
//!
//! Applying is a library edit only. Write to Files… opens the Write page,
//! which shows the engine's plan before anything is written.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const jobs = @import("jobs.zig");
const tags = @import("tags.zig");
const window = @import("window.zig");
const write_tags = @import("write_tags.zig");

const App = app.App;

const editor_key = "orca-metadata-editor";
const cover_pixels = 220;
const max_tracks = 512;
const genre_separator = " / ";
const liborca_genre_separator = "; ";

const Spec = struct {
    label: [*:0]const u8,
    field: liborca.MetadataField,
    /// Null for the genres, which are not one metadata field.
    state: ?liborca.EditableTrackField,
    wide: bool = false,
    single_only: bool = false,
    numeric: bool = false,
};

const specs = [_]Spec{
    .{ .label = "Title", .field = .title, .state = .title, .wide = true },
    .{ .label = "Artist", .field = .artist, .state = .artist },
    .{ .label = "Album", .field = .album, .state = .album },
    .{ .label = "Album artist", .field = .album_artist, .state = .album_artist },
    .{ .label = "Genre", .field = .title, .state = .genre },
    .{ .label = "Date", .field = .date, .state = .date, .numeric = true },
    .{ .label = "Track", .field = .track_number, .state = .track_number, .numeric = true },
    .{ .label = "Disc", .field = .disc_number, .state = .disc_number, .numeric = true },
    .{ .label = "Composer", .field = .composer, .state = .composer },
    .{ .label = "Comment", .field = .comment, .state = .comment },
    .{ .label = "MusicBrainz recording", .field = .musicbrainz_recording_id, .state = null, .single_only = true },
};

fn isGenre(spec: Spec) bool {
    return spec.state == .genre;
}

const Row = struct {
    entry: ?*gtk.Widget = null,
    badge: ?*gtk.Widget = null,
    /// What the field showed when the selection last changed, or null when
    /// the Tracks disagree or none has a value.
    initial: ?[:0]u8 = null,
    mixed: bool = false,
    /// Typed into since the selection last changed.
    touched: bool = false,
};

const Editor = struct {
    self: *App,
    page: *adw.NavigationPage,
    /// The Tracks listed, in the order they were given.
    ids: []i64,
    checks: []*gtk.Widget,
    rows: [specs.len]Row = @splat(.{}),
    list: *gtk.Widget,
    count: *gtk.Label,
    select: *gtk.Button,
    cover: *gtk.Widget,
    cover_caption: *gtk.Label,
    loading: bool = false,
    /// The page to go back to when the editor closes, when it had to be
    /// shown in another section's navigation.
    return_page: ?window.Page,

    fn freeInitial(editor: *Editor) void {
        for (&editor.rows) |*row| if (row.initial) |text| {
            editor.self.allocator.free(text);
            row.initial = null;
        };
    }
};

fn editorOf(data: ?*anyopaque) *Editor {
    return @ptrCast(@alignCast(data.?));
}

fn editorOfPage(page: *adw.NavigationPage) ?*Editor {
    return @ptrCast(@alignCast(gtk.g_object_get_data(page, editor_key) orelse return null));
}

pub fn isEditorPage(page: *adw.NavigationPage) bool {
    return editorOfPage(page) != null;
}

pub fn pushedOf(page: *adw.NavigationPage) ?window.Pushed {
    _ = editorOfPage(page) orelse return null;
    return .metadata_editor;
}

fn shownEditor(self: *App) ?*Editor {
    const page = window.pushedPage(self, self.current_page) orelse return null;
    return editorOfPage(page);
}

pub fn isShown(self: *App) bool {
    return shownEditor(self) != null;
}

pub fn applyShown(self: *App) void {
    const editor = shownEditor(self) orelse return;
    if (!apply(editor)) return;
    self.toast("Saved to Orca's library");
    close(editor, true);
}

pub fn cancelShown(self: *App) void {
    close(shownEditor(self) orelse return, false);
}

/// Where a pushed editing page goes: the navigation of the section showing,
/// or Albums' for a section without one, which the page then returns to.
pub const Host = struct {
    navigation: *adw.NavigationView,
    return_page: ?window.Page,
};

pub fn host(self: *App) ?Host {
    if (window.pageNavigation(self, self.current_page)) |navigation| return .{ .navigation = navigation, .return_page = null };
    const navigation = self.albums_navigation orelse return null;
    const previous = self.current_page;
    window.showPage(self, .albums);
    return .{ .navigation = navigation, .return_page = previous };
}

/// Pops `page` and everything above it, then shows `return_page` if the page
/// was borrowed from another section.
pub fn leave(self: *App, page: *adw.NavigationPage, return_page: ?window.Page) void {
    var navigation_found: ?*adw.NavigationView = null;
    for ([_]?*adw.NavigationView{
        self.albums_navigation,
        self.artists_navigation,
        self.genres.navigation,
        self.loved.navigation,
        self.playlists.navigation,
    }) |candidate| {
        const navigation = candidate orelse continue;
        var at = adw.adw_navigation_view_get_visible_page(navigation);
        while (at) |shown| : (at = adw.adw_navigation_view_get_previous_page(navigation, shown)) {
            if (shown == page) navigation_found = navigation;
        }
    }
    if (navigation_found) |navigation| {
        if (adw.adw_navigation_view_get_previous_page(navigation, page)) |previous| window.popToPage(self, navigation, previous);
    }
    if (return_page) |shown| window.showPage(self, shown);
}

fn close(editor: *Editor, edited: bool) void {
    const self = editor.self;
    const return_page = editor.return_page;
    leave(self, editor.page, return_page);
    if (edited) {
        jobs.reloadLibraryViews(self);
        tags.popPages(self);
        self.requestTick();
    }
}

/// Closes the editor `page` after its edits were written.
pub fn closePage(page: *adw.NavigationPage) void {
    close(editorOfPage(page) orelse return, true);
}

fn selectedIds(editor: *Editor) ![]i64 {
    const allocator = editor.self.allocator;
    var selected: std.ArrayList(i64) = .empty;
    errdefer selected.deinit(allocator);
    for (editor.ids, editor.checks) |id, check| {
        if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0) try selected.append(allocator, id);
    }
    return selected.toOwnedSlice(allocator);
}

fn entryText(row: Row) []const u8 {
    const entry = row.entry orelse return "";
    return std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, entry))), " ");
}

/// The value a touched row sets: null to leave the field as it is, an empty
/// slice to clear Orca's value.
fn changedValue(row: Row) ?[]const u8 {
    if (!row.touched or row.entry == null) return null;
    const text = entryText(row);
    if (row.mixed and text.len == 0) return null;
    if (row.initial) |before| {
        if (std.mem.eql(u8, before, text)) return null;
    } else if (text.len == 0) return null;
    return text;
}

fn discNumber(text: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, text, " of ") orelse return text;
    return std.mem.trim(u8, text[0..end], " ");
}

/// Applies the touched fields to the checked Tracks. The ids an edit moved
/// replace the editor's, so a later write plans the Tracks that now exist.
fn apply(editor: *Editor) bool {
    const self = editor.self;
    const library = self.library orelse return false;
    const selected = selectedIds(editor) catch return false;
    defer self.allocator.free(selected);
    if (selected.len == 0) {
        self.toast("Select the tracks to apply to");
        return false;
    }

    var edits: std.ArrayList(liborca.TrackEdit) = .empty;
    defer edits.deinit(self.allocator);
    var genres: ?[]const u8 = null;
    for (specs, editor.rows) |spec, row| {
        const value = changedValue(row) orelse continue;
        if (isGenre(spec)) {
            genres = value;
            continue;
        }
        const text = if (spec.field == .disc_number) discNumber(value) else value;
        if (spec.field == .musicbrainz_recording_id and text.len != 0 and !liborca.isMusicBrainzId(text)) {
            self.toast("A MusicBrainz recording ID is a lowercase UUID");
            return false;
        }
        edits.append(self.allocator, .{ .field = spec.field, .value = if (text.len == 0) null else text }) catch return false;
    }

    var targets: []const i64 = selected;
    var edited: ?liborca.EditedTracks = null;
    defer if (edited) |owned| owned.deinit();
    if (edits.items.len != 0) {
        edited = self.runtime.libraryEditTracks(library, selected, edits.items) catch |err| {
            self.toast(if (err == error.InvalidEditValue) "Track and disc must be whole numbers from 1 to 9999" else "Could not save the changes");
            return false;
        };
        targets = edited.?.ids;
    }
    if (genres) |text| {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var groups = std.mem.splitScalar(u8, text, ';');
        while (groups.next()) |group| {
            var parts = std.mem.splitSequence(u8, group, genre_separator);
            while (parts.next()) |part| {
                const name = std.mem.trim(u8, part, " ");
                if (name.len != 0) names.append(self.allocator, name) catch return false;
            }
        }
        self.runtime.librarySetTrackGenres(library, targets, names.items) catch {
            self.toast("Could not save the genres");
            return false;
        };
    }
    if (edited) |owned| replaceIds(editor, selected, owned.ids);
    return true;
}

fn replaceIds(editor: *Editor, selected: []const i64, edited: []const i64) void {
    const allocator = editor.self.allocator;
    if (selected.len == edited.len) {
        var next: usize = 0;
        for (editor.ids) |*id| {
            if (next < selected.len and id.* == selected[next]) {
                id.* = edited[next];
                next += 1;
            }
        }
        return;
    }
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(allocator);
    for (editor.ids) |id| {
        if (std.mem.indexOfScalar(i64, selected, id) == null) ids.append(allocator, id) catch return;
    }
    ids.appendSlice(allocator, edited) catch return;
    const owned = ids.toOwnedSlice(allocator) catch return;
    allocator.free(editor.ids);
    editor.ids = owned;
    fillChecklist(editor, selected.len);
}

fn writeLinkActivated(_: ?*anyopaque, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const editor = editorOf(data);
    const self = editor.self;
    if (!apply(editor)) return gtk.true_;
    jobs.reloadLibraryViews(self);
    for (&editor.rows) |*row| row.touched = false;
    loadStates(editor);
    const selected = selectedIds(editor) catch return gtk.true_;
    defer self.allocator.free(selected);
    write_tags.open(self, selected);
    return gtk.true_;
}

fn selectClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const any = for (editor.checks) |check| {
        if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0) break true;
    } else false;
    editor.loading = true;
    for (editor.checks) |check| gtk.gtk_check_button_set_active(gtk.cast(gtk.CheckButton, check), @intFromBool(!any));
    editor.loading = false;
    loadStates(editor);
}

fn checkToggled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    if (!editor.loading) loadStates(editor);
}

fn entryChanged(entry: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    if (editor.loading) return;
    for (&editor.rows) |*row| {
        if (row.entry) |widget| if (@as(?*anyopaque, widget) == entry) {
            row.touched = true;
        };
    }
}

fn setEntry(editor: *Editor, row: *Row, value: ?[]const u8, mixed: bool) void {
    const allocator = editor.self.allocator;
    if (row.initial) |text| allocator.free(text);
    row.initial = if (value) |text| allocator.dupeZ(u8, text) catch null else null;
    row.mixed = mixed;
    row.touched = false;
    const entry = row.entry orelse return;
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), if (row.initial) |text| text.ptr else "");
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), if (mixed) "Mixed" else null);
}

fn setEdited(row: Row, edited: bool) void {
    if (row.badge) |badge| gtk.gtk_widget_set_visible(badge, @intFromBool(edited));
    const entry = row.entry orelse return;
    if (edited) gtk.gtk_widget_add_css_class(entry, "edited") else gtk.gtk_widget_remove_css_class(entry, "edited");
}

fn recordingId(self: *App, track_id: i64) ?[]const u8 {
    const library = self.library orelse return null;
    const details = (self.runtime.libraryTrackDetails(library, track_id) catch return null) orelse return null;
    defer details.deinit();
    const id = details.musicbrainz_recording_id orelse return null;
    return self.allocator.dupe(u8, id) catch null;
}

/// Shows what the checked Tracks hold in every field nobody has typed into.
fn loadStates(editor: *Editor) void {
    const self = editor.self;
    const library = self.library orelse return;
    const selected = selectedIds(editor) catch return;
    defer self.allocator.free(selected);
    var buffer: [256]u8 = undefined;
    var genre_buffer: [1024]u8 = undefined;
    gtk.gtk_label_set_text(editor.count, switch (selected.len) {
        1 => "1 track",
        else => strings.format(&buffer, "{d} tracks", .{selected.len}),
    });
    gtk.gtk_button_set_label(editor.select, if (selected.len == 0) "Select all" else "Select none");

    editor.loading = true;
    defer editor.loading = false;
    if (selected.len == 0) {
        for (&editor.rows) |*row| if (!row.touched) {
            setEntry(editor, row, null, false);
            setEdited(row.*, false);
        };
        art.clear(self, editor.cover);
        gtk.gtk_label_set_text(editor.cover_caption, "No tracks selected");
        return;
    }
    const states = self.runtime.libraryTrackFieldStates(library, selected) catch return self.toast("Could not read the tracks' fields");
    defer states.deinit();
    for (specs, &editor.rows) |spec, *row| {
        if (row.touched) continue;
        const field = spec.state orelse {
            const value = if (selected.len == 1) recordingId(self, selected[0]) else null;
            defer if (value) |text| self.allocator.free(text);
            setEntry(editor, row, value, false);
            continue;
        };
        const state = states.fields.get(field);
        var value = state.value;
        if (field == .disc_number) if (state.value) |number| if (states.disc_total) |total| {
            value = std.fmt.bufPrint(&buffer, "{s} of {d}", .{ number, total }) catch number;
        };
        if (field == .genre) if (state.value) |names| {
            value = genreText(&genre_buffer, names);
        };
        setEntry(editor, row, value, state.mixed);
        setEdited(row.*, state.edited);
    }
    showCover(editor, states, selected);
}

fn genreText(buffer: []u8, names: []const u8) []const u8 {
    const size = std.mem.replacementSize(u8, names, liborca_genre_separator, genre_separator);
    if (size > buffer.len) return names;
    _ = std.mem.replace(u8, names, liborca_genre_separator, genre_separator, buffer);
    return buffer[0..size];
}

fn showCover(editor: *Editor, states: liborca.TrackFieldStates, selected: []const i64) void {
    const self = editor.self;
    art.show(self, editor.cover, art.Key.track(selected[0], .tile));
    var name_buffer: [128]u8 = undefined;
    const name: []const u8 = switch (states.cover.source) {
        .none => return gtk.gtk_label_set_text(editor.cover_caption, "No cover"),
        .folder => states.cover.file_name orelse "Folder image",
        .embedded => strings.format(&name_buffer, "Embedded {s}", .{imageType(states.cover.mime_type)}),
        .fetched => "Cover Art Archive",
        .chosen => "Chosen cover",
    };
    var buffer: [256]u8 = undefined;
    const caption = if (states.track_count == 1)
        strings.terminated(&buffer, name)
    else if (states.cover.tracks == states.track_count)
        strings.format(&buffer, "{s} · same on all {d} tracks", .{ name, states.track_count })
    else
        strings.format(&buffer, "{s} · on {d} of {d} tracks", .{ name, states.cover.tracks, states.track_count });
    gtk.gtk_label_set_text(editor.cover_caption, caption);
}

fn imageType(mime_type: ?[]const u8) []const u8 {
    const mime = mime_type orelse return "image";
    if (std.mem.eql(u8, mime, "image/jpeg") or std.mem.eql(u8, mime, "image/jpg")) return "JPEG";
    if (std.mem.eql(u8, mime, "image/png")) return "PNG";
    if (std.mem.eql(u8, mime, "image/webp")) return "WebP";
    if (std.mem.eql(u8, mime, "image/gif")) return "GIF";
    return mime;
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    gtk.gtk_widget_add_css_class(widget, class);
    return widget;
}

/// Rebuilds the checklist from `ids`, checking the last `checked_tail` rows,
/// or every row when that is all of them.
fn fillChecklist(editor: *Editor, checked_tail: usize) void {
    const self = editor.self;
    while (gtk.gtk_widget_get_first_child(editor.list)) |child| gtk.gtk_box_remove(gtk.cast(gtk.Box, editor.list), child);
    const checks = self.allocator.alloc(*gtk.Widget, editor.ids.len) catch return;
    self.allocator.free(editor.checks);
    editor.checks = checks;
    const library = self.library;
    var buffer: [512]u8 = undefined;
    editor.loading = true;
    defer editor.loading = false;
    for (editor.ids, checks, 0..) |id, *check, index| {
        var number: [:0]const u8 = "";
        var title: [:0]const u8 = "";
        var number_buffer: [16]u8 = undefined;
        if (library) |handle| if (self.runtime.libraryTrackSummary(handle, id) catch null) |summary| {
            defer summary.deinit(self.allocator);
            if (summary.track_number) |value| number = strings.format(&number_buffer, "{d}", .{value});
            title = strings.terminated(&buffer, summary.title);
        };
        check.* = gtk.gtk_check_button_new_with_label(null);
        gtk.gtk_widget_add_css_class(check.*, "metadata-check");
        gtk.gtk_check_button_set_active(gtk.cast(gtk.CheckButton, check.*), @intFromBool(index + checked_tail >= editor.ids.len));
        gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, check.*), gtk.ACCESSIBLE_PROPERTY_LABEL, title.ptr, @as(c_int, -1));
        _ = gtk.signalConnect(check.*, "toggled", gtk.callback(checkToggled), editor);
        const number_label = label(number.ptr, "metadata-track-number");
        gtk.gtk_widget_set_size_request(number_label, 22, -1);
        gtk.gtk_widget_add_css_class(number_label, "numeric");
        const title_label = label(title.ptr, "metadata-track-title");
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title_label), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_set_hexpand(title_label, gtk.true_);
        const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
        gtk.gtk_widget_add_css_class(row, "metadata-track");
        for ([_]*gtk.Widget{ check.*, number_label, title_label }) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, row), child);
        const press = gtk.gtk_gesture_click_new();
        _ = gtk.signalConnect(press, "released", gtk.callback(trackRowReleased), check.*);
        gtk.gtk_widget_add_controller(row, press);
        gtk.gtk_box_append(gtk.cast(gtk.Box, editor.list), row);
    }
}

fn trackRowReleased(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const check: *gtk.Widget = @ptrCast(@alignCast(data.?));
    const row = gtk.gtk_event_controller_get_widget(gtk.cast(gtk.EventController, gesture));
    if (gtk.gtk_widget_pick(row, x, y, 0)) |picked| {
        if (picked == check or gtk.gtk_widget_is_ancestor(picked, check) != 0) return;
    }
    const button = gtk.cast(gtk.CheckButton, check);
    gtk.gtk_check_button_set_active(button, @intFromBool(gtk.gtk_check_button_get_active(button) == 0));
}

fn newTracks(editor: *Editor) *gtk.Widget {
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    const count = gtk.cast(gtk.Widget, editor.count);
    gtk.gtk_widget_set_hexpand(count, gtk.true_);
    gtk.gtk_widget_set_valign(count, gtk.ALIGN_BASELINE_FILL);
    const select = gtk.cast(gtk.Widget, editor.select);
    gtk.gtk_widget_set_valign(select, gtk.ALIGN_BASELINE_FILL);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), count);
    gtk.gtk_box_append(gtk.cast(gtk.Box, heading), select);
    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(column, "metadata-tracks");
    gtk.gtk_widget_set_size_request(column, 280, -1);
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_START);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), editor.list);
    return column;
}

fn newField(editor: *Editor, spec: Spec, row: *Row) *gtk.Widget {
    const title = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 7);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title), label(spec.label, "metadata-label"));
    const badge = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 5);
    gtk.gtk_widget_add_css_class(badge, "metadata-edited");
    const dot = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(dot, "metadata-edited-dot");
    gtk.gtk_widget_set_valign(dot, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, badge), dot);
    gtk.gtk_box_append(gtk.cast(gtk.Box, badge), gtk.gtk_label_new("Edited"));
    gtk.gtk_widget_set_visible(badge, gtk.false_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, title), badge);

    const entry = gtk.gtk_entry_new();
    gtk.gtk_widget_add_css_class(entry, "metadata-field");
    if (spec.numeric) gtk.gtk_widget_add_css_class(entry, "numeric");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, entry), gtk.ACCESSIBLE_PROPERTY_LABEL, spec.label, @as(c_int, -1));
    _ = gtk.signalConnect(entry, "changed", gtk.callback(entryChanged), editor);
    row.entry = entry;
    row.badge = badge;

    const cell = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    gtk.gtk_widget_set_hexpand(cell, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, cell), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, cell), entry);
    return cell;
}

fn newFields(editor: *Editor, single: bool) *gtk.Widget {
    const grid = gtk.gtk_grid_new();
    gtk.gtk_grid_set_row_spacing(gtk.cast(gtk.Grid, grid), 16);
    gtk.gtk_grid_set_column_spacing(gtk.cast(gtk.Grid, grid), 18);
    gtk.gtk_grid_set_column_homogeneous(gtk.cast(gtk.Grid, grid), gtk.true_);
    var slot: c_int = 0;
    for (specs, &editor.rows) |spec, *row| {
        if (spec.single_only and !single) continue;
        const cell = newField(editor, spec, row);
        if (spec.wide) {
            if (@mod(slot, 2) != 0) slot += 1;
            gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), cell, 0, @divTrunc(slot, 2), 2, 1);
            slot += 2;
        } else {
            gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), cell, @mod(slot, 2), @divTrunc(slot, 2), 1, 1);
            slot += 1;
        }
    }

    const note_text = gtk.gtk_label_new(null);
    gtk.gtk_label_set_markup(
        gtk.cast(gtk.Label, note_text),
        "Applying saves to Orca’s database and can be undone. Your files don’t change until you choose " ++
            "<a href=\"write\">Write to Files…</a>, which shows a preview first. " ++
            "Fields marked “Mixed” keep each track’s own value unless you type a new one.",
    );
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note_text), gtk.true_);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, note_text), 0);
    gtk.gtk_widget_set_hexpand(note_text, gtk.true_);
    _ = gtk.signalConnect(note_text, "activate-link", gtk.callback(writeLinkActivated), editor);
    const icon = gtk.gtk_image_new_from_icon_name("orca-info-symbolic");
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(icon, "metadata-note-icon");
    const note = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(note, "metadata-note");
    gtk.gtk_box_append(gtk.cast(gtk.Box, note), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, note), note_text);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_START);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), grid);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), note);
    return column;
}

fn newArtwork(editor: *Editor) *gtk.Widget {
    const replace_label = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, replace_label), gtk.gtk_image_new_from_icon_name("orca-image-symbolic"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, replace_label), gtk.gtk_label_new("Replace…"));
    const replace = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, replace), replace_label);
    const remove = gtk.gtk_button_new_with_label("Remove");
    gtk.gtk_widget_add_css_class(remove, "metadata-remove");
    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    for ([_]*gtk.Widget{ replace, remove }) |button| {
        gtk.gtk_widget_add_css_class(button, "btn-secondary");
        gtk.gtk_widget_add_css_class(button, "metadata-cover-button");
        gtk.gtk_widget_set_sensitive(button, gtk.false_);
        gtk.gtk_widget_set_tooltip_text(button, "Changing a release's cover in the library is not available yet");
        gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), button);
    }

    gtk.gtk_widget_add_css_class(editor.cover, "metadata-cover");
    gtk.gtk_widget_set_halign(editor.cover, gtk.ALIGN_START);
    const caption = gtk.cast(gtk.Widget, editor.cover_caption);
    gtk.gtk_label_set_wrap(editor.cover_caption, gtk.true_);
    gtk.gtk_label_set_xalign(editor.cover_caption, 0);
    gtk.gtk_widget_add_css_class(caption, "metadata-cover-caption");

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_set_size_request(column, cover_pixels, -1);
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_START);
    for ([_]*gtk.Widget{ label("Front cover", "metadata-label"), editor.cover, caption, buttons }) |child|
        gtk.gtk_box_append(gtk.cast(gtk.Box, column), child);
    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), cover_pixels);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), cover_pixels);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), column);
    gtk.gtk_widget_set_hexpand(clamp, gtk.false_);
    gtk.gtk_widget_set_valign(clamp, gtk.ALIGN_START);
    return clamp;
}

fn destroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const editor = editorOf(data);
    const allocator = editor.self.allocator;
    gtk.g_object_set_data(editor.page, editor_key, null);
    editor.freeInitial();
    allocator.free(editor.checks);
    allocator.free(editor.ids);
    allocator.destroy(editor);
}

fn popOpenEditor(self: *App, navigation: *adw.NavigationView) void {
    var at = adw.adw_navigation_view_get_visible_page(navigation);
    while (at) |shown| : (at = adw.adw_navigation_view_get_previous_page(navigation, shown)) {
        if (editorOfPage(shown) == null) continue;
        const previous = adw.adw_navigation_view_get_previous_page(navigation, shown) orelse return;
        return window.popToPage(self, navigation, previous);
    }
}

/// Opens the editor on `ids`, every one checked.
pub fn open(self: *App, ids: []const i64) void {
    if (ids.len == 0) return;
    if (self.library == null) return self.toast("No library is open");
    if (ids.len > max_tracks) return self.toast("Edit at most 512 tracks at once");
    const editor = self.allocator.create(Editor) catch return self.toast("Out of memory");
    const owned_ids = self.allocator.dupe(i64, ids) catch {
        self.allocator.destroy(editor);
        return self.toast("Out of memory");
    };
    const count = label("", "metadata-count");
    const select = gtk.gtk_button_new_with_label("Select none");
    gtk.gtk_widget_add_css_class(select, "flat");
    gtk.gtk_widget_add_css_class(select, "metadata-select");
    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    const cover = art.newPictureCover(self, cover_pixels);
    editor.* = .{
        .self = self,
        .page = undefined,
        .ids = owned_ids,
        .checks = &.{},
        .list = list,
        .count = gtk.cast(gtk.Label, count),
        .select = gtk.cast(gtk.Button, select),
        .cover = cover,
        .cover_caption = gtk.cast(gtk.Label, gtk.gtk_label_new("")),
        .return_page = null,
    };
    _ = gtk.signalConnect(select, "clicked", gtk.callback(selectClicked), editor);
    fillChecklist(editor, ids.len);

    const columns = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    gtk.gtk_widget_add_css_class(columns, "metadata-editor");
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), newTracks(editor));
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), newFields(editor, ids.len == 1));
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), newArtwork(editor));
    loadStates(editor);

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_AUTOMATIC, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), columns);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(destroyed), editor);

    const page = adw.adw_navigation_page_new(scroller, "Edit Metadata");
    editor.page = page;
    gtk.g_object_set_data(page, editor_key, editor);
    const target = host(self) orelse {
        _ = gtk.g_object_ref_sink(page);
        gtk.g_object_unref(page);
        return;
    };
    editor.return_page = target.return_page;
    popOpenEditor(self, target.navigation);
    adw.adw_navigation_view_push(target.navigation, page);
    if (self.window) |root| gtk.gtk_window_set_focus(root, null);
}
