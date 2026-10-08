//! The libraries this frontend knows, by name and path, kept in settings.ini.
//!
//! liborca holds only the one open database. Switching opens the next one
//! before it lets the current one go, so a library that cannot be opened
//! leaves the current one open and playing.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const settings = @import("settings.zig");
const preferences = @import("preferences.zig");
const window = @import("window.zig");
const home = @import("home.zig");
const page_ui = @import("page.zig");
const transport = @import("transport.zig");
const jobs = @import("jobs.zig");
const watching = @import("watching.zig");
const maintenance = @import("maintenance.zig");
const art = @import("art.zig");
const browse = @import("browse.zig");
const details = @import("details.zig");
const queue = @import("queue.zig");
const activity = @import("activity.zig");
const first_run = @import("first_run.zig");
const albums = @import("albums.zig");
const album_filters = @import("album_filters.zig");
const track_filters = @import("track_filters.zig");
const artist_page = @import("artist_page.zig");
const artwork_review = @import("artwork_review.zig");
const audio_problems = @import("audio_problems.zig");
const metadata_issues = @import("metadata_issues.zig");
const matches = @import("matches.zig");
const match_review = @import("match_review.zig");
const changes = @import("changes.zig");
const offline = @import("offline.zig");
const analysis_notice = @import("analysis_notice.zig");
const folders = @import("folders.zig");
const lyrics = @import("lyrics.zig");
const palette = @import("palette.zig");
const genres = @import("genres.zig");
const duplicates = @import("duplicates.zig");

const App = app.App;

pub const max_entries = 16;
const max_name_chars = 40;
const index_key = "orca-library-index";

pub const Entry = struct {
    name: [:0]u8,
    path: [:0]u8,
    tracks: ?u64 = null,
    transient: bool = false,

    fn free(entry: Entry, allocator: std.mem.Allocator) void {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
};

pub const Problem = struct {
    title: [:0]u8,
    detail: [:0]u8,
};

pub const State = struct {
    entries: std.ArrayList(Entry) = .empty,
    active: ?usize = null,
    chosen: ?usize = null,
    problem: ?Problem = null,
    switch_source: c_uint = 0,
    switch_target: usize = 0,
    dialog: ?*adw.Dialog = null,
    list: ?*gtk.ListBox = null,
    content: ?*gtk.Stack = null,
    failure: ?*adw.StatusPage = null,
    choose_button: ?*gtk.Widget = null,
    create_button: ?*gtk.Widget = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.switch_source != 0) _ = gtk.g_source_remove(self.switch_source);
        self.switch_source = 0;
        for (self.entries.items) |entry| entry.free(allocator);
        self.entries.deinit(allocator);
        clearProblem(self, allocator);
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn clearProblem(libraries: *State, allocator: std.mem.Allocator) void {
    const current = libraries.problem orelse return;
    allocator.free(current.title);
    allocator.free(current.detail);
    libraries.problem = null;
}

fn setProblem(self: *App, title: [:0]u8, detail: [:0]u8) void {
    clearProblem(&self.libraries, self.allocator);
    self.libraries.problem = .{ .title = title, .detail = detail };
}

fn reportProblem(self: *App, comptime title: []const u8, title_args: anytype, comptime detail: []const u8, detail_args: anytype) void {
    const title_text = std.fmt.allocPrintSentinel(self.allocator, title, title_args, 0) catch return;
    const detail_text = std.fmt.allocPrintSentinel(self.allocator, detail, detail_args, 0) catch {
        self.allocator.free(title_text);
        return;
    };
    setProblem(self, title_text, detail_text);
}

pub fn problem(self: *App) ?Problem {
    return self.libraries.problem;
}

pub fn activeName(self: *App) [:0]const u8 {
    const index = self.libraries.active orelse return "None";
    return self.libraries.entries.items[index].name;
}

fn defaultPath(buffer: []u8) ?[:0]const u8 {
    const data = std.mem.span(gtk.g_get_user_data_dir());
    return strings.printZ(buffer, "{s}/orca/library.db", .{data}) catch null;
}

fn isDefault(path: []const u8) bool {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.mem.eql(u8, path, defaultPath(&buffer) orelse return false);
}

fn clipped(text: []const u8) []const u8 {
    return clippedTo(text, max_name_chars);
}

fn clippedTo(text: []const u8, limit: usize) []const u8 {
    const view = std.unicode.Utf8View.init(text) catch return "";
    var iterator = view.iterator();
    var count: usize = 0;
    while (count < limit) : (count += 1) {
        _ = iterator.nextCodepointSlice() orelse return text;
    }
    return text[0..iterator.i];
}

fn named(libraries: *const State, name: []const u8) bool {
    for (libraries.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn uniqueName(libraries: *const State, name: []const u8, buffer: []u8) []const u8 {
    if (!named(libraries, name)) return name;
    const stem = clippedTo(name, max_name_chars - 3);
    var number: usize = 2;
    while (number <= max_entries + 1) : (number += 1) {
        const candidate = std.fmt.bufPrint(buffer, "{s} {d}", .{ stem, number }) catch break;
        if (!named(libraries, candidate)) return candidate;
    }
    return name;
}

fn nameFromPath(path: []const u8) []const u8 {
    const name = clipped(std.mem.trim(u8, std.fs.path.stem(path), " "));
    return if (name.len == 0) "Library" else name;
}

pub fn append(self: *App, name: []const u8, path: []const u8, tracks: ?u64) !usize {
    const libraries = &self.libraries;
    if (find(libraries, path)) |index| return index;
    if (libraries.entries.items.len == max_entries) return error.TooManyLibraries;
    const shown = clipped(std.mem.trim(u8, name, " "));
    var name_buffer: [max_name_chars * 4 + 8]u8 = undefined;
    const owned_name = try self.allocator.dupeSentinel(u8, uniqueName(libraries, if (shown.len == 0) nameFromPath(path) else shown, &name_buffer), 0);
    errdefer self.allocator.free(owned_name);
    const owned_path = try self.allocator.dupeSentinel(u8, path, 0);
    errdefer self.allocator.free(owned_path);
    try libraries.entries.append(self.allocator, .{ .name = owned_name, .path = owned_path, .tracks = tracks });
    return libraries.entries.items.len - 1;
}

fn addDefault(self: *App) void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = defaultPath(&buffer) orelse return;
    self.libraries.chosen = append(self, "Main", path, null) catch return;
}

fn find(libraries: *const State, path: []const u8) ?usize {
    for (libraries.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}

fn exists(self: *App, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => false,
        else => true,
    };
    return true;
}

fn absolute(allocator: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const terminated = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(terminated);
    const canonical = gtk.g_canonicalize_filename(terminated.ptr, null);
    defer gtk.g_free(canonical);
    return allocator.dupeSentinel(u8, std.mem.span(canonical), 0) catch null;
}

pub fn resolve(self: *App, environ: *std.process.Environ.Map) ?[:0]u8 {
    const libraries = &self.libraries;
    if (environ.get("ORCA_LIBRARY")) |configured| if (configured.len != 0) {
        var default_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (libraries.entries.items.len == 0) if (defaultPath(&default_buffer)) |default| {
            if (exists(self, default)) addDefault(self);
        };
        const path = absolute(self.allocator, configured) orelse return null;
        defer self.allocator.free(path);
        const index = find(libraries, path) orelse transient: {
            const index = append(self, nameFromPath(path), path, null) catch
                return self.allocator.dupeSentinel(u8, path, 0) catch null;
            libraries.entries.items[index].transient = true;
            break :transient index;
        };
        libraries.active = index;
        return self.allocator.dupeSentinel(u8, path, 0) catch null;
    };
    if (libraries.entries.items.len == 0) addDefault(self);
    const chosen = libraries.chosen orelse 0;
    if (chosen >= libraries.entries.items.len) return null;
    const entry = libraries.entries.items[chosen];
    if (isDefault(entry.path) and !exists(self, entry.path)) {
        if (std.fs.path.dirname(entry.path)) |directory| {
            const owned = self.allocator.dupeSentinel(u8, directory, 0) catch return null;
            defer self.allocator.free(owned);
            _ = gtk.g_mkdir_with_parents(owned.ptr, 0o700);
        }
    }
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (isDefault(entry.path) or exists(self, entry.path)) {
        libraries.active = chosen;
        return self.allocator.dupeSentinel(u8, entry.path, 0) catch null;
    }
    const shown = preferences.homePath(&path_buffer, entry.path);
    for (libraries.entries.items, 0..) |other, index| {
        if (index == chosen or !exists(self, other.path)) continue;
        reportProblem(self, "Could not open {s}", .{entry.name}, "No database at {s}. {s} is open instead.", .{ shown, other.name });
        libraries.active = index;
        return self.allocator.dupeSentinel(u8, other.path, 0) catch null;
    }
    reportProblem(self, "Could not open {s}", .{entry.name}, "No database at {s}", .{shown});
    return null;
}

pub fn openFailed(self: *App, err: anyerror) void {
    std.log.warn("The library could not be opened ({t})", .{err});
    const index = self.libraries.active orelse return;
    self.libraries.active = null;
    const entry = self.libraries.entries.items[index];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const shown = preferences.homePath(&path_buffer, entry.path);
    if (err == error.SchemaVersionTooNew)
        reportProblem(self, "Could not open {s}", .{entry.name}, incompatible, .{shown})
    else
        reportProblem(self, "Could not open {s}", .{entry.name}, "{s} is not an Orca library, or it cannot be read", .{shown});
}

const incompatible = "{s} was made by a different version of Orca; create a new library";

/// Switches on idle: the dropdown or button that asked is rebuilt by the switch.
pub fn requestSwitch(self: *App, index: usize) void {
    const libraries = &self.libraries;
    libraries.switch_target = index;
    if (libraries.switch_source == 0 and libraries.active != index) libraries.switch_source = gtk.g_idle_add(switchLater, self);
}

fn switchLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    self.libraries.switch_source = 0;
    _ = switchTo(self, self.libraries.switch_target, false);
    return gtk.SOURCE_REMOVE;
}

const Failure = enum { missing, unreadable, incompatible };

fn fail(self: *App, index: usize, failure: Failure) void {
    const entry = self.libraries.entries.items[index];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const shown = preferences.homePath(&path_buffer, entry.path);
    switch (failure) {
        .missing => reportProblem(self, "Could not switch to {s}", .{entry.name}, "No database at {s}", .{shown}),
        .unreadable => reportProblem(self, "Could not switch to {s}", .{entry.name}, "{s} is not an Orca library, or it cannot be read", .{shown}),
        .incompatible => reportProblem(self, "Could not switch to {s}", .{entry.name}, incompatible, .{shown}),
    }
    preferences.rebuildPage(self);
    refreshDialog(self);
    showFailure(self);
}

fn switchTo(self: *App, index: usize, create: bool) bool {
    const libraries = &self.libraries;
    if (index >= libraries.entries.items.len or libraries.active == index) return false;
    const entry = libraries.entries.items[index];
    if (!create and !exists(self, entry.path)) {
        fail(self, index, .missing);
        return false;
    }
    const path = self.allocator.dupeSentinel(u8, entry.path, 0) catch {
        self.toast("Out of memory");
        return false;
    };
    const library = self.runtime.openLibrary(self.io, path) catch |err| {
        self.allocator.free(path);
        std.log.warn("A library could not be opened ({t})", .{err});
        fail(self, index, if (err == error.SchemaVersionTooNew) .incompatible else .unreadable);
        return false;
    };
    closeCurrent(self);
    adopt(self, index, library, path);
    rebuild(self);
    return true;
}

fn rememberTracks(self: *App) void {
    const libraries = &self.libraries;
    const index = libraries.active orelse return;
    const library = self.library orelse return;
    const stats = self.runtime.libraryStats(library) catch return;
    libraries.entries.items[index].tracks = stats.tracks;
}

/// `destroyLibrary` joins only liborca's workers, so the frontend's threads,
/// which hold the library's handle, are joined before it.
fn closeCurrent(self: *App) void {
    window.forgetLibrary(self);
    home.forgetLibrary(self);
    artwork_review.forgetLibrary(self);
    audio_problems.forgetLibrary(self);
    metadata_issues.forgetLibrary(self);
    first_run.forgetLibrary(self);
    matches.forgetLibrary(self);
    match_review.forgetLibrary(self);
    changes.forgetLibrary(self);
    offline.forgetLibrary(self);
    analysis_notice.forgetLibrary(self);
    albums.forgetLibrary(self);
    artist_page.forgetLibrary(self);
    lyrics.forgetLibrary(self);
    palette.forgetLibrary(self);
    jobs.forgetLibrary(self);
    folders.forgetLibrary(self);
    self.mpris.forgetLibrary();
    if (self.seek_settle_timer != 0) {
        _ = gtk.g_source_remove(self.seek_settle_timer);
        self.seek_settle_timer = 0;
    }
    self.seeking = false;
    self.pending_play_request = 0;
    const library = self.library orelse return;
    rememberTracks(self);
    self.runtime.pausePlayer(self.player) catch {};
    self.runtime.playerSaveState(self.player, library) catch |err|
        std.log.warn("The queue and position were not saved before switching libraries ({t})", .{err});
    if (self.zone) |zone| {
        self.runtime.destroyZone(zone) catch {};
        self.zone = null;
        transport.refreshSignalPath(self);
    }
    self.runtime.destroyLibrary(library) catch |err|
        std.log.warn("The library did not close cleanly ({t})", .{err});
    self.library = null;
}

/// The queue is cleared only after the old library is gone: while it is still
/// bound, clearing would be saved over the queue just kept for it.
fn adopt(self: *App, index: usize, library: liborca.LibraryHandle, path: [:0]u8) void {
    const libraries = &self.libraries;
    self.library = library;
    if (self.library_path) |old| self.allocator.free(old);
    self.library_path = path;
    libraries.active = index;
    if (!libraries.entries.items[index].transient) libraries.chosen = index;
    clearProblem(libraries, self.allocator);
    self.runtime.stopPlayer(self.player) catch {};
    self.runtime.playerClearQueue(self.player) catch {};
    self.runtime.playerClearQueueHistory(self.player) catch {};
    transport.tick(self);
    self.runtime.playerBindLibrary(self.player, library, self.io) catch |err|
        std.log.warn("Playback could not use the library just opened ({t})", .{err});
    self.tag_write_group = 0;
    self.unmatched_track = null;
    self.seen_recorded_listens = 0;
    self.maintenance_units_seen = 0;
    art.reset(self);
    transport.applyLongTrackMemory(self);
    _ = watching.apply(self);
    maintenance.apply(self) catch {};
    settings.reapplyScrobbling(self);
    const mode: liborca.RestoreMode = if (self.playback.on_launch == .start_empty) .none else .paused;
    _ = self.runtime.playerRestoreState(self.player, library, mode) catch
        self.toast("Could not restore the last queue");
    self.mpris.notify();
}

fn rebuild(self: *App) void {
    album_filters.forgetLibrary(self);
    track_filters.forgetLibrary(self);
    duplicates.forgetLibrary(self);
    genres.forgetLibrary(self);
    details.forgetLibrary(self);
    browse.clearSearch(self);
    jobs.reloadLibraryViews(self);
    home.startMixes(self, false);
    audio_problems.invalidate(self);
    metadata_issues.invalidate(self);
    artwork_review.invalidate(self);
    match_review.invalidate(self);
    duplicates.invalidate(self);
    queue.invalidate(self);
    details.invalidate(self);
    activity.forgetLibrary(self);
    first_run.startIfEmpty(self);
    preferences.rebuildPage(self);
    refreshDialog(self);
    showFailure(self);
    settings.save(self);
    self.requestTick();
    toastNamed(self, "Switched to {s}", activeName(self));
}

fn toastNamed(self: *App, comptime pattern: []const u8, name: []const u8) void {
    const escaped = gtk.g_markup_escape_text(name.ptr, @intCast(name.len));
    defer gtk.g_free(escaped);
    var buffer: [256]u8 = undefined;
    self.toast(strings.printZ(&buffer, pattern, .{std.mem.span(escaped)}) catch return);
}

fn looksLikeLibrary(self: *App, path: []const u8) bool {
    var header: [100]u8 = undefined;
    const read = std.Io.Dir.cwd().readFile(self.io, path, &header) catch return false;
    if (read.len < 64 or !std.mem.startsWith(u8, read, "SQLite format 3\x00")) return false;
    if (std.mem.readInt(u32, read[60..64], .big) != 0) return true;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return exists(self, strings.printZ(&buffer, "{s}-wal", .{path}) catch return false);
}

fn fileBytes(self: *App, path: []const u8) ?u64 {
    const database = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wal_path = strings.printZ(&buffer, "{s}-wal", .{path}) catch return database.size;
    const wal = std.Io.Dir.cwd().statFile(self.io, wal_path, .{}) catch return database.size;
    return database.size + wal.size;
}

fn metaText(self: *App, buffer: []u8, index: usize) [:0]const u8 {
    const libraries = &self.libraries;
    const entry = &libraries.entries.items[index];
    const bytes = fileBytes(self, entry.path) orelse return "Missing";
    if (libraries.active == index) rememberTracks(self);
    const size = gtk.g_format_size(bytes);
    defer gtk.g_free(size);
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (entry.transient) writer.writeAll("From ORCA_LIBRARY · ") catch {};
    writer.writeAll(std.mem.span(size)) catch {};
    if (entry.tracks) |tracks| {
        writer.print(" · {f} {s}", .{ strings.grouped(tracks), if (tracks == 1) "track" else "tracks" }) catch {};
    }
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

pub fn manage(self: *App) void {
    const libraries = &self.libraries;
    if (libraries.dialog != null) return;
    const dialog = adw.adw_alert_dialog_new("Libraries", null);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_prefer_wide_layout(alert, gtk.true_);

    const list = gtk.gtk_list_box_new();
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "boxed-list");
    gtk.gtk_widget_add_css_class(list, "libraries-list");
    const scroller = gtk.gtk_scrolled_window_new();
    const scrolled = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(scrolled, gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_propagate_natural_height(scrolled, gtk.true_);
    gtk.gtk_scrolled_window_set_max_content_height(scrolled, 360);
    gtk.gtk_scrolled_window_set_child(scrolled, list);

    const add = gtk.gtk_button_new_with_label("Add Library…");
    gtk.gtk_widget_add_css_class(add, "settings-action");
    gtk.gtk_widget_set_halign(add, gtk.ALIGN_START);
    _ = gtk.signalConnect(add, "clicked", gtk.callback(addClicked), self);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_set_size_request(content, 540, -1);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), scroller);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), add);
    adw.adw_alert_dialog_set_extra_child(alert, content);
    adw.adw_alert_dialog_add_response(alert, "done", "Done");
    adw.adw_alert_dialog_set_default_response(alert, "done");
    adw.adw_alert_dialog_set_close_response(alert, "done");
    _ = gtk.signalConnect(dialog, "closed", gtk.callback(dialogClosed), self);
    libraries.dialog = dialog;
    libraries.list = gtk.cast(gtk.ListBox, list);
    refreshDialog(self);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn dialogClosed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.libraries.dialog = null;
    self.libraries.list = null;
}

fn refreshDialog(self: *App) void {
    const libraries = &self.libraries;
    const dialog = libraries.dialog orelse return;
    const list = libraries.list orelse return;
    adw.adw_alert_dialog_set_body(
        gtk.cast(adw.AlertDialog, dialog),
        if (libraries.problem) |current| current.detail.ptr else "Each library keeps its own folders, history and playlists. Removing one from this list never deletes its database.",
    );
    gtk.gtk_list_box_remove_all(list);
    for (0..libraries.entries.items.len) |index| gtk.gtk_list_box_append(list, entryRow(self, index));
}

fn indexButton(label: ?[*:0]const u8, icon: ?[*:0]const u8, tooltip: [*:0]const u8, index: usize, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const button = if (label) |text| gtk.gtk_button_new_with_label(text) else gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(button, if (label == null) "flat" else "settings-action");
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    gtk.g_object_set_data(button, index_key, @ptrFromInt(index + 1));
    _ = gtk.signalConnect(button, "clicked", handler, self);
    return button;
}

fn buttonIndex(button: ?*anyopaque) ?usize {
    const value = @intFromPtr(gtk.g_object_get_data(button orelse return null, index_key));
    return if (value == 0) null else value - 1;
}

fn entryRow(self: *App, index: usize) *gtk.Widget {
    const libraries = &self.libraries;
    const entry = libraries.entries.items[index];
    const row = adw.adw_action_row_new();
    const preferences_row = gtk.cast(adw.PreferencesRow, row);
    const action_row = gtk.cast(adw.ActionRow, row);
    adw.adw_preferences_row_set_use_markup(preferences_row, gtk.false_);
    adw.adw_preferences_row_set_title(preferences_row, entry.name.ptr);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    adw.adw_action_row_set_subtitle(action_row, preferences.homePath(&path_buffer, entry.path).ptr);
    gtk.gtk_widget_add_css_class(row, "library-row");

    var meta_buffer: [128]u8 = undefined;
    const meta_text = metaText(self, &meta_buffer, index);
    const meta = gtk.gtk_label_new(meta_text.ptr);
    gtk.gtk_widget_add_css_class(meta, "library-meta");
    if (std.mem.eql(u8, meta_text, "Missing")) gtk.gtk_widget_add_css_class(meta, "missing");
    adw.adw_action_row_add_suffix(action_row, meta);

    const active = libraries.active == index;
    if (active) {
        const label = gtk.gtk_label_new("Active");
        gtk.gtk_widget_add_css_class(label, "library-active");
        adw.adw_action_row_add_suffix(action_row, label);
    } else {
        adw.adw_action_row_add_suffix(action_row, indexButton("Switch", null, "Switch to this library", index, gtk.callback(switchClicked), self));
    }
    if (!entry.transient) {
        adw.adw_action_row_add_suffix(action_row, indexButton(null, "orca-pen-symbolic", "Rename", index, gtk.callback(renameClicked), self));
        const remove_button = indexButton(null, "orca-minus-symbolic", "Remove from List", index, gtk.callback(removeClicked), self);
        gtk.gtk_widget_set_sensitive(remove_button, @intFromBool(!active));
        adw.adw_action_row_add_suffix(action_row, remove_button);
    }
    return row;
}

fn switchClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    requestSwitch(state(data), buttonIndex(button) orelse return);
}

fn changed(self: *App) void {
    settings.save(self);
    preferences.rebuildPage(self);
    refreshDialog(self);
    showFailure(self);
}

const RenameRequest = struct {
    self: *App,
    index: usize,
    entry: *gtk.Widget,
};

fn renameClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = buttonIndex(button) orelse return;
    if (index >= self.libraries.entries.items.len) return;
    const request = self.allocator.create(RenameRequest) catch return self.toast("Out of memory");
    const entry = gtk.gtk_entry_new();
    gtk.gtk_editable_set_text(gtk.cast(gtk.Editable, entry), self.libraries.entries.items[index].name.ptr);
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, entry), "Name");
    gtk.gtk_entry_set_max_length(gtk.cast(gtk.Entry, entry), max_name_chars);
    gtk.gtk_entry_set_activates_default(gtk.cast(gtk.Entry, entry), gtk.true_);
    request.* = .{ .self = self, .index = index, .entry = entry };

    const dialog = adw.adw_alert_dialog_new("Rename Library", null);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_set_extra_child(alert, entry);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "rename", "Rename");
    adw.adw_alert_dialog_set_response_appearance(alert, "rename", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "rename");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(renameResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
    _ = gtk.g_idle_add(focusLater, gtk.g_object_ref(entry));
}

fn focusLater(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const entry = gtk.cast(gtk.Widget, data.?);
    defer gtk.g_object_unref(entry);
    if (gtk.gtk_widget_get_root(entry) != null) _ = gtk.gtk_widget_grab_focus(entry);
    return gtk.SOURCE_REMOVE;
}

fn renameResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *RenameRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    const index = request.index;
    const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, request.entry)));
    self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "rename")) return;
    const libraries = &self.libraries;
    if (index >= libraries.entries.items.len) return;
    const name = clipped(std.mem.trim(u8, text, " "));
    if (name.len == 0) return self.toast("A library needs a name");
    for (libraries.entries.items, 0..) |other, at| {
        if (at != index and std.mem.eql(u8, other.name, name)) return self.toast("Another library has that name");
    }
    const owned = self.allocator.dupeSentinel(u8, name, 0) catch return self.toast("Out of memory");
    self.allocator.free(libraries.entries.items[index].name);
    libraries.entries.items[index].name = owned;
    changed(self);
}

const RemoveRequest = struct {
    self: *App,
    index: usize,
};

fn removeClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = buttonIndex(button) orelse return;
    if (index >= self.libraries.entries.items.len or self.libraries.active == index) return;
    const entry = self.libraries.entries.items[index];
    const request = self.allocator.create(RemoveRequest) catch return self.toast("Out of memory");
    request.* = .{ .self = self, .index = index };
    var heading_buffer: [128]u8 = undefined;
    var body_buffer: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const heading = strings.printZ(&heading_buffer, "Remove {s}?", .{entry.name}) catch "Remove Library?";
    const body = strings.printZ(&body_buffer, "Orca forgets this library. Its database stays at {s}.", .{preferences.homePath(&path_buffer, entry.path)}) catch
        "Orca forgets this library. Its database stays where it is.";
    const dialog = adw.adw_alert_dialog_new(heading.ptr, body.ptr);
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "remove", "Remove from List");
    adw.adw_alert_dialog_set_response_appearance(alert, "remove", adw.RESPONSE_DESTRUCTIVE);
    adw.adw_alert_dialog_set_default_response(alert, "cancel");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(removeResponse), request);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn removeResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const request: *RemoveRequest = @ptrCast(@alignCast(data.?));
    const self = request.self;
    const index = request.index;
    self.allocator.destroy(request);
    if (!std.mem.eql(u8, std.mem.span(response), "remove")) return;
    remove(self, index);
}

fn shifted(value: ?usize, removed: usize) ?usize {
    const current = value orelse return null;
    if (current == removed) return null;
    return if (current > removed) current - 1 else current;
}

fn remove(self: *App, index: usize) void {
    const libraries = &self.libraries;
    if (index >= libraries.entries.items.len or libraries.active == index) return;
    const entry = libraries.entries.orderedRemove(index);
    libraries.active = shifted(libraries.active, index);
    libraries.chosen = shifted(libraries.chosen, index);
    if (libraries.chosen == null) if (libraries.active) |active| {
        if (!libraries.entries.items[active].transient) libraries.chosen = active;
    };
    clearProblem(libraries, self.allocator);
    changed(self);
    toastNamed(self, "Removed {s} from the list", entry.name);
    entry.free(self.allocator);
}

fn refuseWhenFull(self: *App) bool {
    if (self.libraries.entries.items.len < max_entries) return false;
    self.toast("Orca keeps at most 16 libraries");
    return true;
}

fn addClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (refuseWhenFull(self)) return;
    const dialog = adw.adw_alert_dialog_new("Add Library", "Open a library you already have, or create a new, empty one.");
    const alert = gtk.cast(adw.AlertDialog, dialog);
    adw.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    adw.adw_alert_dialog_add_response(alert, "open", "Open Existing…");
    adw.adw_alert_dialog_add_response(alert, "create", "Create New…");
    adw.adw_alert_dialog_set_response_appearance(alert, "create", adw.RESPONSE_SUGGESTED);
    adw.adw_alert_dialog_set_default_response(alert, "create");
    adw.adw_alert_dialog_set_close_response(alert, "cancel");
    _ = gtk.signalConnect(dialog, "response", gtk.callback(addResponse), self);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn addResponse(_: ?*anyopaque, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const choice = std.mem.span(response);
    if (std.mem.eql(u8, choice, "open")) return chooseExisting(self);
    if (std.mem.eql(u8, choice, "create")) return chooseNew(self);
}

fn databaseFilters(dialog: *gtk.FileDialog) void {
    const filter = gtk.gtk_file_filter_new();
    gtk.gtk_file_filter_set_name(filter, "Orca libraries (.db)");
    gtk.gtk_file_filter_add_suffix(filter, "db");
    if (gtk.g_list_store_new(gtk.gtk_file_filter_get_type())) |filters| {
        gtk.g_list_store_append(filters, filter);
        gtk.gtk_file_dialog_set_filters(dialog, gtk.cast(gtk.ListModel, filters));
        gtk.g_object_unref(filters);
    }
    gtk.gtk_file_dialog_set_default_filter(dialog, filter);
    gtk.g_object_unref(filter);
}

fn chooseExisting(self: *App) void {
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Open Library");
    databaseFilters(dialog);
    gtk.gtk_file_dialog_open(dialog, self.window, null, existingChosen, self);
    gtk.g_object_unref(dialog);
}

fn chooseNew(self: *App) void {
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Create Library");
    gtk.gtk_file_dialog_set_initial_name(dialog, "Library.db");
    databaseFilters(dialog);
    gtk.gtk_file_dialog_save(dialog, self.window, null, newChosen, self);
    gtk.g_object_unref(dialog);
}

fn chosenPath(self: *App, file: *gtk.GFile) ?[:0]u8 {
    const raw = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const pointer = raw orelse {
        self.toast("That file is not on the local filesystem");
        return null;
    };
    defer gtk.g_free(pointer);
    return self.allocator.dupeSentinel(u8, std.mem.span(pointer), 0) catch null;
}

fn existingChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_open_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const path = chosenPath(self, file) orelse return;
    defer self.allocator.free(path);
    addExisting(self, path);
}

fn addExisting(self: *App, path: []const u8) void {
    const libraries = &self.libraries;
    if (find(libraries, path)) |index| {
        const entry = &libraries.entries.items[index];
        if (!entry.transient) return self.toast("That library is already in the list");
        entry.transient = false;
        changed(self);
        return toastNamed(self, "Added {s}", entry.name);
    }
    if (!looksLikeLibrary(self, path)) return self.toast("That file is not an Orca library");
    const index = append(self, nameFromPath(path), path, null) catch return self.toast("Could not add that library");
    changed(self);
    toastNamed(self, "Added {s}", libraries.entries.items[index].name);
}

fn newChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_save_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const path = chosenPath(self, file) orelse return;
    defer self.allocator.free(path);
    const libraries = &self.libraries;
    if (find(libraries, path) != null) return self.toast("That library is already in the list");
    if (exists(self, path)) {
        if (!looksLikeLibrary(self, path)) return self.toast("That file is not an Orca library");
        return addExisting(self, path);
    }
    const index = append(self, nameFromPath(path), path, null) catch return self.toast("Could not add that library");
    if (switchTo(self, index, true)) return;
    const entry = libraries.entries.orderedRemove(index);
    entry.free(self.allocator);
    preferences.rebuildPage(self);
    refreshDialog(self);
    showFailure(self);
}

pub fn wrapPages(self: *App, pages: *gtk.Widget) *gtk.Widget {
    const content = gtk.gtk_stack_new();
    const stack = gtk.cast(gtk.Stack, content);
    gtk.gtk_stack_set_transition_type(stack, gtk.STACK_TRANSITION_CROSSFADE);
    gtk.gtk_stack_set_hhomogeneous(stack, gtk.false_);
    gtk.gtk_stack_set_vhomogeneous(stack, gtk.false_);
    _ = gtk.gtk_stack_add_named(stack, pages, "pages");
    _ = gtk.gtk_stack_add_named(stack, buildFailure(self), "failed");
    page_ui.showChild(stack, "pages");
    self.libraries.content = stack;
    return content;
}

fn buildFailure(self: *App) *gtk.Widget {
    const page = adw.adw_status_page_new();
    const status = gtk.cast(adw.StatusPage, page);
    adw.adw_status_page_set_icon_name(status, "orca-alert-symbolic");
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_set_halign(actions, gtk.ALIGN_CENTER);
    const choose = gtk.gtk_button_new_with_label("Choose Library…");
    gtk.gtk_widget_add_css_class(choose, "pill");
    _ = gtk.signalConnect(choose, "clicked", gtk.callback(chooseClicked), self);
    const create = gtk.gtk_button_new_with_label("Create Library…");
    gtk.gtk_widget_add_css_class(create, "pill");
    _ = gtk.signalConnect(create, "clicked", gtk.callback(createClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), choose);
    gtk.gtk_box_append(gtk.cast(gtk.Box, actions), create);
    adw.adw_status_page_set_child(status, actions);
    self.libraries.failure = status;
    self.libraries.choose_button = choose;
    self.libraries.create_button = create;
    return page;
}

fn chooseClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    manage(state(data));
}

fn createClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (refuseWhenFull(self)) return;
    chooseNew(self);
}

pub fn showFailure(self: *App) void {
    const failed = self.library == null;
    enableLibraryActions(self, !failed);
    const content = self.libraries.content orelse return;
    const shown = failed and self.current_page != .settings;
    if (shown) describeFailure(self);
    page_ui.showChild(content, if (shown) "failed" else "pages");
}

fn enableLibraryActions(self: *App, enabled: bool) void {
    const application = self.application orelse return;
    for ([_][*:0]const u8{ "add-folder", "rescan" }) |name| {
        const action = gtk.g_action_map_lookup_action(gtk.cast(gtk.GActionMap, application), name) orelse continue;
        gtk.g_simple_action_set_enabled(gtk.cast(gtk.GSimpleAction, action), if (enabled) gtk.true_ else gtk.false_);
    }
}

fn describeFailure(self: *App) void {
    const status = self.libraries.failure orelse return;
    const title: [:0]const u8, const detail: [:0]const u8 = if (self.libraries.problem) |current|
        .{ current.title, current.detail }
    else
        .{ "No library is open", "Choose a library, or create a new one." };
    adw.adw_status_page_set_title(status, title.ptr);
    const escaped = gtk.g_markup_escape_text(detail.ptr, @intCast(detail.len));
    defer gtk.g_free(escaped);
    adw.adw_status_page_set_description(status, escaped);
    const others = self.libraries.entries.items.len > 1;
    suggest(self.libraries.choose_button, others);
    suggest(self.libraries.create_button, !others);
}

fn suggest(button: ?*gtk.Widget, suggested: bool) void {
    const widget = button orelse return;
    if (suggested)
        gtk.gtk_widget_add_css_class(widget, "suggested-action")
    else
        gtk.gtk_widget_remove_css_class(widget, "suggested-action");
}
