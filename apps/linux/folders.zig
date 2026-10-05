const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const albums = @import("albums.zig");
const art = @import("art.zig");
const browse_model = @import("browse_model.zig");
const details = @import("details.zig");
const jobs = @import("jobs.zig");
const menu = @import("menu.zig");
const page_ui = @import("page.zig");
const signal_path = @import("signal_path.zig");
const strings = @import("strings.zig");
const transport = @import("transport.zig");
const window = @import("window.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const pane_width: c_int = 260;
const kind_pixels: c_int = 260;
const length_pixels: c_int = 72;
const status_pixels: c_int = 136;
const cover_pixels: c_int = 44;
const max_tree_pages = 16;
const max_filter_pages = 16;

const Kind = enum { folder, file, image };

const Root = struct {
    id: i64,
    path: []u8,
};

const Entry = struct {
    kind: Kind,
    object: *BrowseObject,
    track_id: ?i64 = null,
    duration_ms: i64 = 0,
    track_count: u32 = 0,
    front_cover: bool = false,
};

pub const State = struct {
    pane: ?*gtk.Widget = null,
    tree_model: ?*gtk.TreeListModel = null,
    tree_roots: ?*gtk.ListStore = null,
    tree_selection: ?*gtk.SingleSelection = null,
    tree_view: ?*gtk.Widget = null,
    files_store: ?*gtk.ListStore = null,
    files_view: ?*gtk.Widget = null,
    crumbs: ?*gtk.Box = null,
    page: ?*gtk.Stack = null,
    body: ?*gtk.Stack = null,
    card_cover: ?*gtk.Widget = null,
    card_title: ?*gtk.Label = null,
    card_detail: ?*gtk.Label = null,
    files_button: ?*gtk.Widget = null,
    library_button: ?*gtk.Widget = null,
    roots: std.ArrayList(Root) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    root_id: ?i64 = null,
    path: app.OwnedText = .{},
    filter: app.OwnedText = .{},
    release_id: ?i64 = null,
    last_scanned_at: ?i64 = null,
    image_count: u32 = 0,
    loaded: u32 = 0,
    exhausted: bool = true,
    stale: bool = true,
    suppress: bool = false,
    narrow: bool = false,
    menu_position: ?usize = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        clearRoots(self, allocator);
        self.roots.deinit(allocator);
        clearEntries(self);
        self.entries.deinit(allocator);
        self.path.clear(allocator);
        self.filter.clear(allocator);
    }
};

fn clearRoots(folders: *State, allocator: std.mem.Allocator) void {
    for (folders.roots.items) |root| allocator.free(root.path);
    folders.roots.clearRetainingCapacity();
}

fn clearEntries(folders: *State) void {
    for (folders.entries.items) |entry| gtk.g_object_unref(entry.object);
    folders.entries.clearRetainingCapacity();
}

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn part(widget: *gtk.Widget, key: [*:0]const u8) ?*gtk.Widget {
    const found = gtk.g_object_get_data(widget, key) orelse return null;
    return @ptrCast(@alignCast(found));
}

fn rootById(self: *App, id: i64) ?Root {
    for (self.folders.roots.items) |root| if (root.id == id) return root;
    return null;
}

fn displayName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

fn joinPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.mem.concat(allocator, u8, &.{ parent, "/", name });
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn absolutePath(self: *App, relative: []const u8) ?[:0]u8 {
    const root = rootById(self, self.folders.root_id orelse return null) orelse return null;
    const base = std.mem.trimEnd(u8, root.path, "/");
    const parts: []const []const u8 = if (relative.len == 0) &.{base} else &.{ base, "/", relative };
    return std.mem.concatWithSentinel(self.allocator, u8, parts, 0) catch null;
}

pub fn shown(self: *App) void {
    if (self.folders.stale) refresh(self);
}

pub fn invalidate(self: *App) void {
    self.folders.stale = true;
    if (self.current_page == .folders) refresh(self);
}

pub fn forgetLibrary(self: *App) void {
    const folders = &self.folders;
    folders.root_id = null;
    folders.path.clear(self.allocator);
    folders.release_id = null;
}

pub fn setFilter(self: *App, text: []const u8) void {
    const folders = &self.folders;
    if (std.mem.eql(u8, text, folders.filter.value)) return;
    folders.filter.set(self.allocator, text);
    if (folders.filter.value.len != 0) {
        var pages: usize = 0;
        while (!folders.exhausted and pages < max_filter_pages) : (pages += 1) loadNext(self);
    }
    refill(self);
    showBody(self);
}

fn refresh(self: *App) void {
    const folders = &self.folders;
    folders.stale = false;
    loadRoots(self);
    if (folders.root_id) |id| if (rootById(self, id) == null) {
        folders.root_id = null;
        folders.path.clear(self.allocator);
    };
    if (folders.root_id == null and folders.roots.items.len != 0) folders.root_id = folders.roots.items[0].id;
    if (folders.tree_roots) |store| {
        folders.suppress = true;
        gtk.g_list_store_remove_all(store);
        for (folders.roots.items) |root| {
            const node = browse_model.newWithCaption(root.id, displayName(root.path), "", root.path) orelse continue;
            gtk.g_list_store_append(store, node);
            gtk.g_object_unref(node);
        }
        folders.suppress = false;
    }
    show(self, .list);
}

fn loadRoots(self: *App) void {
    const folders = &self.folders;
    clearRoots(folders, self.allocator);
    const library = self.library orelse return;
    var offset: u32 = 0;
    while (true) {
        var page = self.runtime.libraryRootPage(library, app.page_size, offset) catch return;
        defer page.deinit();
        for (page.items) |root| {
            const path = self.allocator.dupe(u8, root.path) catch return;
            folders.roots.append(self.allocator, .{ .id = root.id, .path = path }) catch {
                self.allocator.free(path);
                return;
            };
        }
        if (page.items.len < app.page_size) return;
        offset += app.page_size;
    }
}

const Origin = enum { list, tree };

fn open(self: *App, root_id: i64, path: []const u8, origin: Origin) void {
    const folders = &self.folders;
    folders.root_id = root_id;
    folders.path.set(self.allocator, path);
    show(self, origin);
}

fn show(self: *App, origin: Origin) void {
    const folders = &self.folders;
    rebuildCrumbs(self);
    reloadFiles(self);
    updateCardDetail(self);
    showBody(self);
    if (origin == .list) syncTree(self);
    if (folders.files_view) |view| if (visibleCount(self) != 0)
        gtk.gtk_list_view_scroll_to(gtk.cast(gtk.ListView, view), 0, gtk.LIST_SCROLL_NONE, null);
}

fn goUp(self: *App) bool {
    const folders = &self.folders;
    const root_id = folders.root_id orelse return false;
    if (folders.path.value.len == 0) return false;
    open(self, root_id, parentPath(folders.path.value), .list);
    return true;
}

fn visibleCount(self: *App) c_uint {
    const store = self.folders.files_store orelse return 0;
    return gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store));
}

fn showBody(self: *App) void {
    const folders = &self.folders;
    if (folders.page) |page| gtk.gtk_stack_set_visible_child_name(page, if (folders.roots.items.len == 0) "welcome" else "folders");
    const body = folders.body orelse return;
    const visible = if (folders.entries.items.len == 0)
        "empty"
    else if (visibleCount(self) == 0)
        "unmatched"
    else
        "files";
    gtk.gtk_stack_set_visible_child_name(body, visible);
}

fn removeChildren(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn crumbLabel(text: []const u8, class: [*:0]const u8) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const label = gtk.gtk_label_new(strings.terminated(&buffer, text).ptr);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_MIDDLE);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn crumbButton(self: *App, text: []const u8, depth: usize) *gtk.Widget {
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), crumbLabel(text, "folder-crumb-text"));
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "folder-crumb");
    gtk.g_object_set_data(button, "orca-depth", @ptrFromInt(depth + 1));
    _ = gtk.signalConnect(button, "clicked", gtk.callback(crumbClicked), self);
    return button;
}

fn separator() *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("orca-chevron-right-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 12);
    gtk.gtk_widget_add_css_class(icon, "folder-crumb-separator");
    return icon;
}

fn rebuildCrumbs(self: *App) void {
    const folders = &self.folders;
    const crumbs = folders.crumbs orelse return;
    removeChildren(crumbs);
    const root = rootById(self, folders.root_id orelse return) orelse return;
    var names: [64][]const u8 = undefined;
    var count: usize = 0;
    names[count] = std.mem.trimEnd(u8, root.path, "/");
    if (names[count].len == 0) names[count] = root.path;
    count += 1;
    var components = std.mem.tokenizeScalar(u8, folders.path.value, '/');
    while (components.next()) |component| {
        if (count == names.len) break;
        names[count] = component;
        count += 1;
    }
    for (names[0..count], 0..) |name, depth| {
        if (depth != 0) gtk.gtk_box_append(crumbs, separator());
        if (depth + 1 == count)
            gtk.gtk_box_append(crumbs, crumbLabel(name, "folder-crumb-current"))
        else
            gtk.gtk_box_append(crumbs, crumbButton(self, name, depth));
    }
}

fn crumbClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-depth"));
    if (marked == 0) return;
    const depth = marked - 1;
    const root_id = self.folders.root_id orelse return;
    const path = self.folders.path.value;
    var end: usize = 0;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    var taken: usize = 0;
    while (taken < depth) : (taken += 1) {
        const component = components.next() orelse break;
        end = @intFromPtr(component.ptr) - @intFromPtr(path.ptr) + component.len;
    }
    const target = self.allocator.dupe(u8, path[0..end]) catch return;
    defer self.allocator.free(target);
    open(self, root_id, target, .list);
}

fn reloadFiles(self: *App) void {
    const folders = &self.folders;
    const store = folders.files_store orelse return;
    folders.suppress = true;
    gtk.g_list_store_remove_all(store);
    folders.suppress = false;
    clearEntries(folders);
    folders.loaded = 0;
    folders.exhausted = folders.root_id == null;
    folders.release_id = null;
    folders.last_scanned_at = null;
    folders.image_count = 0;
    setCardRelease(self, null, null, null);
    if (folders.filter.value.len == 0) {
        loadNext(self);
    } else {
        var pages: usize = 0;
        while (!folders.exhausted and pages < max_filter_pages) : (pages += 1) loadNext(self);
    }
}

fn plural(buffer: []u8, count: u64, one: []const u8, many: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) one else many }) catch "";
}

fn formatText(buffer: []u8, summary: liborca.TrackSummary) []const u8 {
    if (summary.codec.len == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    signal_path.writeCodecName(&writer, summary.codec) catch return "";
    if (summary.bit_depth) |bits| writer.print(" · {d}-bit", .{bits}) catch return writer.buffered();
    if (summary.sample_rate) |rate| {
        writer.writeAll(" · ") catch return writer.buffered();
        signal_path.writeRate(&writer, rate) catch return writer.buffered();
    }
    return writer.buffered();
}

fn extensionText(buffer: []u8, name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    const extension = name[dot + 1 ..];
    if (dot == 0 or extension.len == 0 or extension.len > buffer.len) return "";
    return std.ascii.upperString(buffer[0..extension.len], extension);
}

fn imageKindText(buffer: []u8, mime: ?[]const u8) []const u8 {
    const known = mime orelse return "Image";
    const slash = std.mem.indexOfScalar(u8, known, '/') orelse return "Image";
    const subtype = known[slash + 1 ..];
    if (subtype.len == 0 or subtype.len + " image".len > buffer.len) return "Image";
    _ = std.ascii.upperString(buffer[0..subtype.len], subtype);
    @memcpy(buffer[subtype.len..][0..6], " image");
    return buffer[0 .. subtype.len + 6];
}

fn roleText(role: ?liborca.ArtworkRole) []const u8 {
    return switch (role orelse .other) {
        .front => "Front cover",
        .back => "Back cover",
        .booklet => "Booklet",
        .other => "Image",
    };
}

fn loadNext(self: *App) void {
    const folders = &self.folders;
    const store = folders.files_store orelse return;
    if (folders.exhausted) return;
    const root_id = folders.root_id orelse return;
    const library = self.library orelse {
        folders.exhausted = true;
        return;
    };
    var page = self.runtime.libraryFolderPage(library, root_id, folders.path.value, app.page_size, folders.loaded) catch {
        folders.exhausted = true;
        return;
    };
    defer page.deinit();
    if (folders.loaded == 0) {
        folders.release_id = page.release_id;
        folders.last_scanned_at = page.last_scanned_at;
        folders.image_count = page.image_count;
        setCardRelease(self, page.release_id, page.release_title, page.release_artist);
    }
    if (page.items.len < app.page_size) folders.exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer additions.deinit(self.allocator);
    folders.entries.ensureUnusedCapacity(self.allocator, page.items.len) catch {
        folders.exhausted = true;
        return;
    };
    for (page.items) |item| {
        var kind_buffer: [96]u8 = undefined;
        var status_buffer: [48]u8 = undefined;
        var kind_text: []const u8 = "";
        var status_text: []const u8 = "";
        var entry_kind: Kind = .folder;
        var duration_ms = item.total_duration_ms;
        switch (item.kind) {
            .folder => {
                kind_text = "Folder";
                status_text = plural(&status_buffer, item.track_count, "track", "tracks");
            },
            .file => {
                entry_kind = .file;
                var summary: ?liborca.TrackSummary = null;
                if (item.track_id) |id| summary = self.runtime.libraryTrackSummary(library, id) catch null;
                defer if (summary) |found| found.deinit(self.allocator);
                if (summary) |found| {
                    kind_text = formatText(&kind_buffer, found);
                    if (duration_ms <= 0) duration_ms = found.duration_ms orelse 0;
                }
                if (kind_text.len == 0) kind_text = extensionText(&kind_buffer, item.name);
                status_text = if (item.status == .unreadable)
                    "Unreadable"
                else if (item.track_id != null)
                    "In library"
                else
                    "Not imported";
            },
            .image => {
                entry_kind = .image;
                kind_text = imageKindText(&kind_buffer, item.mime);
                status_text = roleText(item.artwork_role);
            },
        }
        const index: i64 = @intCast(folders.entries.items.len);
        const object = browse_model.newWithCaption(index, item.name, kind_text, status_text) orelse continue;
        folders.entries.appendAssumeCapacity(.{
            .kind = entry_kind,
            .object = object,
            .track_id = item.track_id,
            .duration_ms = duration_ms,
            .track_count = item.track_count,
            .front_cover = item.artwork_role == .front,
        });
        if (matches(self, object)) additions.append(self.allocator, object) catch {};
    }
    if (additions.items.len != 0) {
        folders.suppress = true;
        gtk.g_list_store_splice(store, visibleCount(self), 0, additions.items.ptr, @intCast(additions.items.len));
        folders.suppress = false;
    }
    folders.loaded += @intCast(page.items.len);
    updateCardDetail(self);
}

fn matches(self: *App, object: *BrowseObject) bool {
    const filter = self.folders.filter.value;
    return filter.len == 0 or std.ascii.findIgnoreCase(object.name(), filter) != null;
}

fn refill(self: *App) void {
    const folders = &self.folders;
    const store = folders.files_store orelse return;
    var kept: std.ArrayList(?*anyopaque) = .empty;
    defer kept.deinit(self.allocator);
    for (folders.entries.items) |entry| {
        if (matches(self, entry.object)) kept.append(self.allocator, entry.object) catch break;
    }
    folders.suppress = true;
    gtk.g_list_store_splice(store, 0, visibleCount(self), kept.items.ptr, @intCast(kept.items.len));
    folders.suppress = false;
}

fn filesMoved(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.folders.exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page) loadNext(self);
}

fn setCardRelease(self: *App, release_id: ?i64, title: ?[]const u8, artist: ?[]const u8) void {
    const folders = &self.folders;
    if (folders.library_button) |button| gtk.gtk_widget_set_sensitive(button, @intFromBool(release_id != null));
    if (folders.card_cover) |cover| {
        gtk.gtk_widget_set_visible(cover, @intFromBool(release_id != null));
        if (release_id) |id| {
            art.setInitials(cover, title orelse "");
            art.show(self, cover, art.Key.release(id, .thumb));
        }
    }
    const label = folders.card_title orelse return;
    if (release_id == null) {
        var buffer: [512]u8 = undefined;
        const name = if (folders.path.value.len != 0)
            displayName(folders.path.value)
        else if (folders.root_id) |id| (if (rootById(self, id)) |root| root.path else "") else "";
        gtk.gtk_label_set_text(label, strings.terminated(&buffer, name).ptr);
        return;
    }
    const shown_title = if (title) |value| (if (value.len != 0) value else "Untitled") else "Untitled";
    const escaped_title = gtk.g_markup_escape_text(shown_title.ptr, @intCast(shown_title.len));
    defer gtk.g_free(escaped_title);
    const shown_artist = artist orelse "";
    const escaped_artist = gtk.g_markup_escape_text(shown_artist.ptr, @intCast(shown_artist.len));
    defer gtk.g_free(escaped_artist);
    var buffer: [2048]u8 = undefined;
    const markup = if (shown_artist.len != 0)
        strings.format(&buffer, "Imported as <a href=\"release\">{s}</a> by {s}", .{ std.mem.span(escaped_title), std.mem.span(escaped_artist) })
    else
        strings.format(&buffer, "Imported as <a href=\"release\">{s}</a>", .{std.mem.span(escaped_title)});
    gtk.gtk_label_set_markup(label, markup.ptr);
}

fn updateCardDetail(self: *App) void {
    const folders = &self.folders;
    const label = folders.card_detail orelse return;
    var tracks: u64 = 0;
    var front_covers: u32 = 0;
    for (folders.entries.items) |entry| switch (entry.kind) {
        .folder => tracks += entry.track_count,
        .file => {
            if (entry.track_id != null) tracks += 1;
        },
        .image => {
            if (entry.front_cover) front_covers += 1;
        },
    };
    var track_buffer: [48]u8 = undefined;
    var image_buffer: [48]u8 = undefined;
    var moment_buffer: [96]u8 = undefined;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (folders.exhausted)
        writer.writeAll(plural(&track_buffer, tracks, "track", "tracks")) catch {}
    else
        writer.print("{d}+ tracks", .{tracks}) catch {};
    if (folders.image_count != 0) {
        const covers = front_covers == folders.image_count;
        writer.writeAll(" · ") catch {};
        writer.writeAll(plural(&image_buffer, folders.image_count, if (covers) "cover image" else "image", if (covers) "cover images" else "images")) catch {};
    }
    if (folders.last_scanned_at) |scanned| {
        const moment = details.recentMomentText(&moment_buffer, scanned);
        writer.writeAll(" · last scanned ") catch {};
        if (moment.len != 0) {
            writer.writeByte(std.ascii.toLower(moment[0])) catch {};
            writer.writeAll(moment[1..]) catch {};
        }
    }
    buffer[writer.end] = 0;
    gtk.gtk_label_set_text(label, buffer[0..writer.end :0].ptr);
}

fn cardLinkActivated(_: ?*anyopaque, _: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    openRelease(state(data));
    return gtk.true_;
}

fn openRelease(self: *App) void {
    const release_id = self.folders.release_id orelse return;
    window.showAlbum(self, release_id);
}

fn libraryToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) == 0) return;
    if (self.folders.files_button) |files| gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, files), gtk.true_);
    openRelease(self);
}

fn rescanClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const root_id = self.folders.root_id orelse return;
    jobs.rescanFolder(self, root_id, self.folders.path.value);
}

fn showInFilesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const absolute = absolutePath(self, self.folders.path.value) orelse return;
    defer self.allocator.free(absolute);
    const uri = gtk.g_filename_to_uri(absolute.ptr, null, null) orelse return self.toast("Could not open the file manager");
    defer gtk.g_free(uri);
    var err: ?*gtk.GError = null;
    if (gtk.g_app_info_launch_default_for_uri(uri, null, &err) != 0) return;
    gtk.g_clear_error(&err);
    self.toast("Could not open the file manager");
}

fn entryAt(self: *App, position: usize) ?usize {
    const store = self.folders.files_store orelse return null;
    const object = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), @intCast(position)) orelse return null;
    defer gtk.g_object_unref(object);
    const index = (@as(*BrowseObject, @ptrCast(@alignCast(object)))).id() orelse return null;
    if (index < 0 or index >= self.folders.entries.items.len) return null;
    return @intCast(index);
}

fn activateEntry(self: *App, index: usize) void {
    const folders = &self.folders;
    const entry = folders.entries.items[index];
    const root_id = folders.root_id orelse return;
    switch (entry.kind) {
        .folder => {
            const path = joinPath(self.allocator, folders.path.value, entry.object.name()) catch return;
            defer self.allocator.free(path);
            open(self, root_id, path, .list);
        },
        .file => playFrom(self, index),
        .image => {},
    }
}

fn levelTrackIds(self: *App) ![]i64 {
    const folders = &self.folders;
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(self.allocator);
    const root_id = folders.root_id orelse return ids.toOwnedSlice(self.allocator);
    const library = self.library orelse return ids.toOwnedSlice(self.allocator);
    var offset: u32 = 0;
    while (ids.items.len < liborca.max_playlist_entries) {
        var page = try self.runtime.libraryFolderPage(library, root_id, folders.path.value, app.page_size, offset);
        defer page.deinit();
        for (page.items) |item| {
            if (ids.items.len == liborca.max_playlist_entries) break;
            if (item.kind == .file) if (item.track_id) |id| try ids.append(self.allocator, id);
        }
        if (page.items.len < app.page_size) break;
        offset += app.page_size;
    }
    return ids.toOwnedSlice(self.allocator);
}

fn playFrom(self: *App, index: usize) void {
    const folders = &self.folders;
    if (folders.entries.items[index].track_id == null) return self.toast("This file is not in the library yet");
    var start: u32 = 0;
    for (folders.entries.items[0..index]) |entry| {
        if (entry.kind == .file and entry.track_id != null) start += 1;
    }
    const ids = levelTrackIds(self) catch return self.toast("Could not read this folder");
    defer self.allocator.free(ids);
    if (start >= ids.len) return;
    transport.playIds(self, ids, start);
}

fn filesActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const index = entryAt(self, position) orelse return;
    activateEntry(self, index);
}

fn cellLabel(class: [*:0]const u8, width: c_int, xalign: f32) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), xalign);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1);
    gtk.gtk_widget_add_css_class(label, "folder-cell");
    gtk.gtk_widget_add_css_class(label, class);
    if (width > 0) gtk.gtk_widget_set_size_request(label, width, -1) else gtk.gtk_widget_set_hexpand(label, gtk.true_);
    return label;
}

fn setupFile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "folder-row");
    const name_cell = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 9);
    gtk.gtk_widget_add_css_class(name_cell, "folder-cell");
    gtk.gtk_widget_set_hexpand(name_cell, gtk.true_);
    const icon = gtk.gtk_image_new_from_icon_name("orca-file-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 15);
    gtk.gtk_widget_add_css_class(icon, "folder-row-icon");
    const name = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, name), 1);
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    gtk.gtk_widget_add_css_class(name, "folder-row-name");
    gtk.gtk_box_append(gtk.cast(gtk.Box, name_cell), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, name_cell), name);
    const kind = cellLabel("folder-row-kind", kind_pixels, 0);
    const length = cellLabel("folder-row-length", length_pixels, 1);
    gtk.gtk_widget_add_css_class(length, "numeric");
    const status = cellLabel("folder-row-status", status_pixels, 0);
    for ([_]*gtk.Widget{ name_cell, kind, length, status }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    gtk.gtk_widget_set_visible(kind, @intFromBool(!self.folders.narrow));
    menu.onSecondaryClick(box, rowMenu, self);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), box);
    gtk.g_object_set_data(box, "orca-icon", icon);
    gtk.g_object_set_data(box, "orca-name", name);
    gtk.g_object_set_data(box, "orca-kind", kind);
    gtk.g_object_set_data(box, "orca-length", length);
    gtk.g_object_set_data(box, "orca-status", status);
}

fn bindFile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const object: *BrowseObject = @ptrCast(@alignCast(gtk.gtk_list_item_get_item(list_item) orelse return));
    const raw_index = object.id() orelse return;
    if (raw_index < 0 or raw_index >= self.folders.entries.items.len) return;
    const index: usize = @intCast(raw_index);
    const entry = self.folders.entries.items[index];
    const box = gtk.gtk_list_item_get_child(list_item) orelse return;
    gtk.g_object_set_data(box, "orca-index", @ptrFromInt(index + 1));
    const icon: [*:0]const u8 = switch (entry.kind) {
        .folder => "orca-folders-symbolic",
        .file => "orca-file-symbolic",
        .image => "orca-image-symbolic",
    };
    if (part(box, "orca-icon")) |image| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, image), icon);
    if (part(box, "orca-name")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), object.name().ptr);
    if (part(box, "orca-kind")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), object.detail().ptr);
    if (part(box, "orca-status")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), object.caption().ptr);
    var buffer: [32]u8 = undefined;
    const duration: [:0]const u8 = if (entry.duration_ms <= 0 or entry.kind == .image)
        ""
    else if (entry.kind == .file)
        strings.formatMs(&buffer, @intCast(entry.duration_ms))
    else
        strings.terminated(buffer[16..], strings.totalDuration(buffer[0..16], entry.duration_ms));
    if (part(box, "orca-length")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), duration.ptr);
    gtk.gtk_widget_set_tooltip_text(box, object.name().ptr);
    albums.showPlaying(box, sameTrack(self.shown_track_id, entry.track_id));
}

pub fn markPlaying(self: *App, track_id: ?i64) void {
    const folders = &self.folders;
    const view = folders.files_view orelse return;
    var child = gtk.gtk_widget_get_first_child(view);
    while (child) |cell| : (child = gtk.gtk_widget_get_next_sibling(cell)) {
        const box = gtk.gtk_widget_get_first_child(cell) orelse continue;
        const index = markedIndex(box) orelse continue;
        if (index >= folders.entries.items.len) continue;
        albums.showPlaying(box, sameTrack(track_id, folders.entries.items[index].track_id));
    }
}

fn sameTrack(playing: ?i64, track_id: ?i64) bool {
    const a = playing orelse return false;
    const b = track_id orelse return false;
    return a == b;
}

fn markedIndex(widget: *gtk.Widget) ?usize {
    const marked = @intFromPtr(gtk.g_object_get_data(widget, "orca-index"));
    if (marked == 0) return null;
    return marked - 1;
}

fn rowMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const box = menu.gestureWidget(gesture);
    const index = markedIndex(box) orelse return;
    fileMenu(self, box, index, x, y);
}

fn fileMenu(self: *App, widget: *gtk.Widget, index: usize, x: f64, y: f64) void {
    const folders = &self.folders;
    if (index >= folders.entries.items.len) return;
    const entry = folders.entries.items[index];
    if (entry.kind == .folder) return;
    folders.menu_position = index;
    const items = gtk.g_menu_new();
    defer gtk.g_object_unref(items);
    const reveal = gtk.g_menu_new();
    gtk.g_menu_append(reveal, "Show in Files", "folders.reveal");
    gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, reveal));
    gtk.g_object_unref(reveal);
    if (entry.kind == .file and trackContext(self, entry.track_id)) {
        const playback = gtk.g_menu_new();
        gtk.g_menu_append(playback, "Play", "app.ctx-play");
        gtk.g_menu_append(playback, "Add to Queue", "app.ctx-enqueue");
        gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, playback));
        gtk.g_object_unref(playback);
        const editing = gtk.g_menu_new();
        gtk.g_menu_append(editing, "Edit Metadata…", "app.ctx-edit-tags");
        gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, editing));
        gtk.g_object_unref(editing);
    }
    menu.popupModel(widget, gtk.cast(gtk.GMenuModel, items), x, y);
}

fn trackContext(self: *App, track_id: ?i64) bool {
    const id = track_id orelse return false;
    const library = self.library orelse return false;
    const summary = (self.runtime.libraryTrackSummary(library, id) catch null) orelse return false;
    defer summary.deinit(self.allocator);
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, id, summary.recording_id, summary.feedback) catch return false;
    self.context.release_id = summary.release_id;
    self.context.artist_id = summary.artist_id;
    return true;
}

fn launched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_file_launcher_open_containing_folder_finish(gtk.cast(gtk.FileLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open the file manager");
}

fn revealActivated(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const folders = &self.folders;
    const index = folders.menu_position orelse return;
    if (index >= folders.entries.items.len) return;
    const relative = joinPath(self.allocator, folders.path.value, folders.entries.items[index].object.name()) catch return;
    defer self.allocator.free(relative);
    const absolute = absolutePath(self, relative) orelse return;
    defer self.allocator.free(absolute);
    const file = gtk.g_file_new_for_path(absolute.ptr);
    defer gtk.g_object_unref(file);
    if (gtk.g_file_query_exists(file, null) == 0) return self.toast("File not found");
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_open_containing_folder(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

fn childFolders(item: ?*anyopaque, data: ?*anyopaque) callconv(.c) ?*gtk.ListModel {
    const self = state(data);
    const node: *BrowseObject = @ptrCast(@alignCast(item orelse return null));
    const root_id = node.id() orelse return null;
    const library = self.library orelse return null;
    const store = gtk.g_list_store_new(browse_model.getType()) orelse return null;
    var offset: u32 = 0;
    var pages: usize = 0;
    pages: while (pages < max_tree_pages) : (pages += 1) {
        var page = self.runtime.libraryFolderPage(library, root_id, node.detail(), app.page_size, offset) catch break;
        defer page.deinit();
        for (page.items) |entry| {
            if (entry.kind != .folder) break :pages;
            const path = joinPath(self.allocator, node.detail(), entry.name) catch continue;
            defer self.allocator.free(path);
            const child = browse_model.newWithCaption(root_id, entry.name, path, "") orelse continue;
            gtk.g_list_store_append(store, child);
            gtk.g_object_unref(child);
        }
        if (page.items.len < app.page_size) break;
        offset += app.page_size;
    }
    if (gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)) == 0) {
        gtk.g_object_unref(store);
        return null;
    }
    return gtk.cast(gtk.ListModel, store);
}

fn setupNode(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const expander = gtk.gtk_tree_expander_new();
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 7);
    gtk.gtk_widget_add_css_class(box, "folder-node");
    const icon = gtk.gtk_image_new_from_icon_name("orca-folders-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 16);
    gtk.gtk_widget_add_css_class(icon, "folder-node-icon");
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, label), 1);
    gtk.gtk_widget_set_hexpand(label, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), label);
    gtk.gtk_tree_expander_set_child(gtk.cast(gtk.TreeExpander, expander), box);
    gtk.g_object_set_data(expander, "orca-name", label);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), expander);
}

fn bindNode(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_item = gtk.cast(gtk.ListItem, item);
    const row: *gtk.TreeListRow = @ptrCast(gtk.gtk_list_item_get_item(list_item) orelse return);
    const expander = gtk.gtk_list_item_get_child(list_item) orelse return;
    gtk.gtk_tree_expander_set_list_row(gtk.cast(gtk.TreeExpander, expander), row);
    const object = gtk.gtk_tree_list_row_get_item(row) orelse return;
    defer gtk.g_object_unref(object);
    const node: *BrowseObject = @ptrCast(@alignCast(object));
    if (part(expander, "orca-name")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), node.name().ptr);
    gtk.gtk_widget_set_tooltip_text(expander, if (node.caption().len != 0) node.caption().ptr else node.name().ptr);
}

fn unbindNode(_: ?*anyopaque, item: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const expander = gtk.gtk_list_item_get_child(gtk.cast(gtk.ListItem, item)) orelse return;
    gtk.gtk_tree_expander_set_list_row(gtk.cast(gtk.TreeExpander, expander), null);
}

fn nodeAt(model: *gtk.TreeListModel, position: c_uint) ?struct { node: *BrowseObject, depth: c_uint } {
    const row = gtk.gtk_tree_list_model_get_row(model, position) orelse return null;
    defer gtk.g_object_unref(row);
    const object = gtk.gtk_tree_list_row_get_item(row) orelse return null;
    gtk.g_object_unref(object);
    return .{ .node = @ptrCast(@alignCast(object)), .depth = gtk.gtk_tree_list_row_get_depth(row) };
}

fn expand(model: *gtk.TreeListModel, position: c_uint) void {
    const row = gtk.gtk_tree_list_model_get_row(model, position) orelse return;
    defer gtk.g_object_unref(row);
    gtk.gtk_tree_list_row_set_expanded(row, gtk.true_);
}

fn findNode(self: *App, model: *gtk.TreeListModel) ?c_uint {
    const root_id = self.folders.root_id orelse return null;
    const list = gtk.cast(gtk.ListModel, model);
    var current: c_uint = found: {
        var position: c_uint = 0;
        while (position < gtk.g_list_model_get_n_items(list)) : (position += 1) {
            const found = nodeAt(model, position) orelse continue;
            if (found.depth == 0 and found.node.id() == root_id) break :found position;
        }
        return null;
    };
    var depth: c_uint = 0;
    var components = std.mem.tokenizeScalar(u8, self.folders.path.value, '/');
    while (components.next()) |component| {
        expand(model, current);
        var next = current + 1;
        const match: ?c_uint = while (next < gtk.g_list_model_get_n_items(list)) : (next += 1) {
            const found = nodeAt(model, next) orelse continue;
            if (found.depth <= depth) break null;
            if (found.depth == depth + 1 and std.mem.eql(u8, found.node.name(), component)) break next;
        } else null;
        current = match orelse return current;
        depth += 1;
    }
    return current;
}

fn syncTree(self: *App) void {
    const folders = &self.folders;
    const model = folders.tree_model orelse return;
    const selection = folders.tree_selection orelse return;
    folders.suppress = true;
    defer folders.suppress = false;
    const target = findNode(self, model);
    gtk.gtk_single_selection_set_selected(selection, target orelse gtk.INVALID_LIST_POSITION);
    if (target) |position| if (folders.tree_view) |view|
        gtk.gtk_list_view_scroll_to(gtk.cast(gtk.ListView, view), position, gtk.LIST_SCROLL_NONE, null);
}

fn treeSelected(selection: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.folders.suppress) return;
    const model = self.folders.tree_model orelse return;
    const position = gtk.gtk_single_selection_get_selected(gtk.cast(gtk.SingleSelection, selection));
    if (position == gtk.INVALID_LIST_POSITION) return;
    const found = nodeAt(model, position) orelse return;
    const root_id = found.node.id() orelse return;
    const path = self.allocator.dupe(u8, found.node.detail()) catch return;
    defer self.allocator.free(path);
    open(self, root_id, path, .tree);
}

fn keyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, modifiers: c_uint, data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const held = modifiers & (gtk.MODIFIER_CONTROL | gtk.MODIFIER_ALT | gtk.MODIFIER_SHIFT);
    const up = (keyval == gtk.KEY_BackSpace and held == 0) or (keyval == gtk.KEY_Up and held == gtk.MODIFIER_ALT);
    if (!up) return gtk.false_;
    return @intFromBool(goUp(self));
}

fn buildTree(self: *App) *gtk.Widget {
    const roots = gtk.g_list_store_new(browse_model.getType()).?;
    self.folders.tree_roots = roots;
    const model = gtk.gtk_tree_list_model_new(gtk.cast(gtk.ListModel, roots), gtk.false_, gtk.false_, childFolders, self, null);
    self.folders.tree_model = model;
    const selection = gtk.gtk_single_selection_new(gtk.cast(gtk.ListModel, model));
    gtk.gtk_single_selection_set_autoselect(selection, gtk.false_);
    gtk.gtk_single_selection_set_can_unselect(selection, gtk.true_);
    self.folders.tree_selection = selection;
    _ = gtk.signalConnect(selection, "notify::selected", gtk.callback(treeSelected), self);
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupNode), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindNode), self);
    _ = gtk.signalConnect(factory, "unbind", gtk.callback(unbindNode), self);
    const view = gtk.gtk_list_view_new(gtk.cast(gtk.SelectionModel, selection), factory);
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, view), gtk.LIST_TAB_ITEM);
    gtk.gtk_widget_add_css_class(view, "folder-tree");
    self.folders.tree_view = view;
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    gtk.gtk_widget_set_size_request(scroller, pane_width, -1);
    gtk.gtk_widget_add_css_class(scroller, "folder-pane");
    self.folders.pane = scroller;
    return scroller;
}

fn headerLabel(text: [*:0]const u8, width: c_int, xalign: f32) *gtk.Widget {
    const label = cellLabel("folder-heading", width, xalign);
    gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), text);
    return label;
}

fn buildFiles(self: *App) *gtk.Widget {
    const store = gtk.g_list_store_new(browse_model.getType()).?;
    self.folders.files_store = store;
    const selection = gtk.gtk_single_selection_new(gtk.cast(gtk.ListModel, store));
    gtk.gtk_single_selection_set_autoselect(selection, gtk.false_);
    gtk.gtk_single_selection_set_can_unselect(selection, gtk.true_);
    const factory = gtk.gtk_signal_list_item_factory_new();
    _ = gtk.signalConnect(factory, "setup", gtk.callback(setupFile), self);
    _ = gtk.signalConnect(factory, "bind", gtk.callback(bindFile), self);
    const view = gtk.gtk_list_view_new(gtk.cast(gtk.SelectionModel, selection), factory);
    gtk.gtk_list_view_set_tab_behavior(gtk.cast(gtk.ListView, view), gtk.LIST_TAB_ITEM);
    gtk.gtk_list_view_set_single_click_activate(gtk.cast(gtk.ListView, view), gtk.false_);
    gtk.gtk_widget_add_css_class(view, "folder-files");
    _ = gtk.signalConnect(view, "activate", gtk.callback(filesActivated), self);
    self.folders.files_view = view;
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(filesMoved),
        self,
    );

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(header, "folder-header-row");
    const kind = headerLabel("KIND", kind_pixels, 0);
    for ([_]*gtk.Widget{
        headerLabel("NAME", 0, 0),
        kind,
        headerLabel("LENGTH", length_pixels, 1),
        headerLabel("STATUS", status_pixels, 0),
    }) |label| gtk.gtk_box_append(gtk.cast(gtk.Box, header), label);
    gtk.g_object_set_data(view, "orca-kind-heading", kind);

    const table = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, table), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, table), scroller);
    return table;
}

fn folderButton(label: [*:0]const u8, icon: ?[*:0]const u8) *gtk.Widget {
    const button = gtk.gtk_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(content, gtk.ALIGN_CENTER);
    if (icon) |name| {
        const image = gtk.gtk_image_new_from_icon_name(name);
        gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, image), 14);
        gtk.gtk_box_append(gtk.cast(gtk.Box, content), image);
    }
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(label));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "folder-button");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    return button;
}

fn buildBar(self: *App) *gtk.Widget {
    const bar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(bar, "folder-bar");
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_widget_add_css_class(crumbs, "folder-crumbs");
    gtk.gtk_widget_set_hexpand(crumbs, gtk.true_);
    gtk.gtk_widget_set_valign(crumbs, gtk.ALIGN_CENTER);
    self.folders.crumbs = gtk.cast(gtk.Box, crumbs);

    const files = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, files), "Files");
    const library = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, library), "Library view");
    gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, library), gtk.cast(gtk.ToggleButton, files));
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, files), gtk.true_);
    gtk.gtk_widget_set_tooltip_text(library, "Open the album these files were imported as");
    _ = gtk.signalConnect(library, "toggled", gtk.callback(libraryToggled), self);
    self.folders.files_button = files;
    self.folders.library_button = library;
    const switcher = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(switcher, "segmented");
    gtk.gtk_widget_add_css_class(switcher, "folder-switch");
    gtk.gtk_widget_set_valign(switcher, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, switcher), files);
    gtk.gtk_box_append(gtk.cast(gtk.Box, switcher), library);

    const reveal = folderButton("Show in File Manager", "orca-external-link-symbolic");
    _ = gtk.signalConnect(reveal, "clicked", gtk.callback(showInFilesClicked), self);

    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_box_append(gtk.cast(gtk.Box, end), switcher);
    gtk.gtk_box_append(gtk.cast(gtk.Box, end), reveal);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), crumbs);
    gtk.gtk_box_append(gtk.cast(gtk.Box, bar), end);
    return bar;
}

fn cardLabel(class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn buildCard(self: *App) *gtk.Widget {
    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(card, "folder-card");
    const cover = art.newCover(self, art.initialsPlaceholder(), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "folder-card-cover");
    self.folders.card_cover = cover;
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title = cardLabel("folder-card-title");
    _ = gtk.signalConnect(title, "activate-link", gtk.callback(cardLinkActivated), self);
    const detail = cardLabel("folder-card-detail");
    gtk.gtk_widget_add_css_class(detail, "numeric");
    self.folders.card_title = gtk.cast(gtk.Label, title);
    self.folders.card_detail = gtk.cast(gtk.Label, detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);
    const rescan = folderButton("Rescan Folder", null);
    gtk.gtk_widget_set_tooltip_text(rescan, "Read this folder and every folder in it again");
    _ = gtk.signalConnect(rescan, "clicked", gtk.callback(rescanClicked), self);
    for ([_]*gtk.Widget{ cover, labels, rescan }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, card), piece);
    return card;
}

fn buildStatus(icon: [*:0]const u8, title: [*:0]const u8) *gtk.Widget {
    const page = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, page), icon);
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, page), title);
    gtk.gtk_widget_set_vexpand(page, gtk.true_);
    return page;
}

fn buildWelcome() *gtk.Widget {
    const page = adw.adw_status_page_new();
    const status = gtk.cast(adw.StatusPage, page);
    adw.adw_status_page_set_icon_name(status, "folder-music-symbolic");
    adw.adw_status_page_set_title(status, "Welcome to Orca");
    adw.adw_status_page_set_description(status, "Add the folder your music lives in. Orca reads it and never changes a file unless you ask.");
    const button = gtk.gtk_button_new_with_label("Add Music Folder…");
    gtk.gtk_widget_add_css_class(button, "pill");
    gtk.gtk_widget_add_css_class(button, "suggested-action");
    gtk.gtk_widget_set_halign(button, gtk.ALIGN_CENTER);
    gtk.gtk_actionable_set_action_name(gtk.cast(gtk.Actionable, button), "app.add-folder");
    adw.adw_status_page_set_child(status, button);
    return page;
}

fn setNarrow(self: *App, narrow: bool) void {
    self.folders.narrow = narrow;
    const view = self.folders.files_view orelse return;
    if (part(view, "orca-kind-heading")) |heading| gtk.gtk_widget_set_visible(heading, @intFromBool(!narrow));
    var row = gtk.gtk_widget_get_first_child(view);
    while (row) |widget| : (row = gtk.gtk_widget_get_next_sibling(widget)) {
        const box = gtk.gtk_widget_get_first_child(widget) orelse continue;
        if (part(box, "orca-kind")) |label| gtk.gtk_widget_set_visible(label, @intFromBool(!narrow));
    }
}

fn narrowed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setNarrow(state(data), true);
}

fn widened(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setNarrow(state(data), false);
}

pub fn build(self: *App) *gtk.Widget {
    const body = gtk.gtk_stack_new();
    self.folders.body = gtk.cast(gtk.Stack, body);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildFiles(self), "files");
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildStatus("folder-symbolic", "No audio files here."), "empty");
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildStatus("system-search-symbolic", "Nothing in this folder matches"), "unmatched");

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), buildBar(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), buildCard(self));

    const right = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 16);
    gtk.gtk_widget_set_hexpand(right, gtk.true_);
    gtk.gtk_widget_add_css_class(right, "folder-content");
    gtk.gtk_box_append(gtk.cast(gtk.Box, right), content);
    gtk.gtk_box_append(gtk.cast(gtk.Box, right), body);

    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    gtk.gtk_widget_set_hexpand(bin, gtk.true_);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), right);
    if (adw.adw_breakpoint_condition_parse("max-width: 700px")) |condition| {
        const breakpoint = adw.adw_breakpoint_new(condition);
        _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(narrowed), self);
        _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(widened), self);
        adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
    }

    const split = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(split, "folder-split");
    gtk.gtk_box_append(gtk.cast(gtk.Box, split), buildTree(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, split), bin);

    const welcome = buildWelcome();
    const page = gtk.gtk_stack_new();
    self.folders.page = gtk.cast(gtk.Stack, page);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, page), split, "folders");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, page), welcome, "welcome");

    const title = page_ui.title("Folders");
    gtk.gtk_widget_add_css_class(title.widget, "folder-title");
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, title.meta), gtk.false_);

    const group = gtk.g_simple_action_group_new();
    const reveal = gtk.g_simple_action_new("reveal", null).?;
    _ = gtk.signalConnect(reveal, "activate", gtk.callback(revealActivated), self);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, reveal));
    gtk.g_object_unref(reveal);
    gtk.gtk_widget_insert_action_group(split, "folders", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);

    const keys = gtk.gtk_event_controller_key_new();
    gtk.gtk_event_controller_set_propagation_phase(keys, gtk.PHASE_BUBBLE);
    _ = gtk.signalConnect(keys, "key-pressed", gtk.callback(keyPressed), self);
    gtk.gtk_widget_add_controller(split, keys);
    return page_ui.withTitle(title, page);
}
