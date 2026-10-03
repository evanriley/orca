const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const browse_model = @import("browse_model.zig");
const menu = @import("menu.zig");
const page_ui = @import("page.zig");
const signal_path = @import("signal_path.zig");
const strings = @import("strings.zig");
const transport = @import("transport.zig");

const App = app.App;
const BrowseObject = browse_model.BrowseObject;

const pane_width: c_int = 280;
const column_pixels: c_int = 160;
const duration_pixels: c_int = 76;
const number_pixels: c_int = 28;
const format_pixels: c_int = 96;
const rate_pixels: c_int = 64;
const track_duration_pixels: c_int = 44;
const cover_pixels: c_int = 48;
const max_tree_pages = 16;

pub const Mode = enum { files, library };

const Kind = enum { root, folder, file };

const Root = struct {
    id: i64,
    path: []u8,
};

const Entry = struct {
    kind: Kind,
    root_id: i64,
    track_id: ?i64 = null,
    duration_ms: i64 = 0,
};

const LibraryTrack = struct {
    id: i64,
    recording_id: ?i64,
    feedback: liborca.Feedback,
    release_id: ?i64,
    artist_id: ?i64,
};

pub const State = struct {
    pane: ?*gtk.Widget = null,
    tree_model: ?*gtk.TreeListModel = null,
    tree_roots: ?*gtk.ListStore = null,
    tree_selection: ?*gtk.SingleSelection = null,
    tree_view: ?*gtk.Widget = null,
    files_store: ?*gtk.ListStore = null,
    files_view: ?*gtk.Widget = null,
    library_list: ?*gtk.ListBox = null,
    crumbs: ?*gtk.Box = null,
    count: ?*gtk.Label = null,
    body: ?*gtk.Stack = null,
    toolbar: ?*gtk.Widget = null,
    play: ?*gtk.Widget = null,
    shuffle: ?*gtk.Widget = null,
    roots: std.ArrayList(Root) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    library_tracks: std.ArrayList(LibraryTrack) = .empty,
    root_id: ?i64 = null,
    path: app.OwnedText = .{},
    mode: Mode = .files,
    loaded: u32 = 0,
    exhausted: bool = true,
    folder_count: u32 = 0,
    file_count: u32 = 0,
    files_below: u64 = 0,
    library_stale: bool = true,
    stale: bool = true,
    suppress: bool = false,
    narrow: bool = false,
    menu_position: ?usize = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        clearRoots(self, allocator);
        self.roots.deinit(allocator);
        self.entries.deinit(allocator);
        self.library_tracks.deinit(allocator);
        self.path.clear(allocator);
    }
};

fn clearRoots(folders: *State, allocator: std.mem.Allocator) void {
    for (folders.roots.items) |root| allocator.free(root.path);
    folders.roots.clearRetainingCapacity();
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

fn stem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

pub fn shown(self: *App) void {
    if (self.folders.stale) refresh(self);
}

pub fn invalidate(self: *App) void {
    self.folders.stale = true;
    if (self.current_page == .folders) refresh(self);
}

fn refresh(self: *App) void {
    const folders = &self.folders;
    folders.stale = false;
    loadRoots(self);
    if (folders.root_id) |id| if (rootById(self, id) == null) {
        folders.root_id = null;
        folders.path.clear(self.allocator);
    };
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

fn open(self: *App, root_id: ?i64, path: []const u8, origin: Origin) void {
    const folders = &self.folders;
    folders.root_id = root_id;
    if (root_id == null) folders.path.clear(self.allocator) else folders.path.set(self.allocator, path);
    show(self, origin);
}

fn show(self: *App, origin: Origin) void {
    const folders = &self.folders;
    rebuildCrumbs(self);
    reloadFiles(self);
    folders.library_stale = true;
    if (folders.mode == .library) fillLibrary(self);
    showBody(self);
    if (origin == .list) syncTree(self);
    if (folders.files_view) |view| if (folders.entries.items.len != 0)
        gtk.gtk_list_view_scroll_to(gtk.cast(gtk.ListView, view), 0, gtk.LIST_SCROLL_NONE, null);
}

fn goUp(self: *App) bool {
    const folders = &self.folders;
    const root_id = folders.root_id orelse return false;
    if (folders.path.value.len == 0) {
        open(self, null, "", .list);
    } else {
        open(self, root_id, parentPath(folders.path.value), .list);
    }
    return true;
}

fn showBody(self: *App) void {
    const folders = &self.folders;
    const body = folders.body orelse return;
    const visible = if (folders.roots.items.len == 0)
        "welcome"
    else if (folders.root_id != null and folders.entries.items.len == 0)
        "empty"
    else switch (folders.mode) {
        .files => "files",
        .library => if (folders.library_tracks.items.len == 0) "empty" else "library",
    };
    gtk.gtk_stack_set_visible_child_name(body, visible);
    const playable = folders.root_id != null and folders.files_below != 0;
    for ([_]?*gtk.Widget{ folders.play, folders.shuffle }) |maybe|
        gtk.gtk_widget_set_sensitive(maybe orelse continue, @intFromBool(playable));
    if (folders.toolbar) |toolbar| gtk.gtk_widget_set_visible(toolbar, @intFromBool(folders.roots.items.len != 0));
}

fn removeChildren(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn crumbLabel(text: []const u8, class: [*:0]const u8) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const label = gtk.gtk_label_new(strings.terminated(&buffer, text).ptr);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn crumbButton(self: *App, text: []const u8, depth: usize) *gtk.Widget {
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), crumbLabel(text, "breadcrumb-text"));
    gtk.gtk_widget_add_css_class(button, "flat");
    gtk.gtk_widget_add_css_class(button, "breadcrumb-parent");
    gtk.g_object_set_data(button, "orca-depth", @ptrFromInt(depth + 1));
    _ = gtk.signalConnect(button, "clicked", gtk.callback(crumbClicked), self);
    return button;
}

fn separator() *gtk.Widget {
    const label = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(label, "breadcrumb-separator");
    return label;
}

fn rebuildCrumbs(self: *App) void {
    const folders = &self.folders;
    const crumbs = folders.crumbs orelse return;
    removeChildren(crumbs);
    const root = if (folders.root_id) |id| rootById(self, id) else null;
    const top = root orelse {
        gtk.gtk_box_append(crumbs, crumbLabel("Folders", "breadcrumb-current"));
        return;
    };
    gtk.gtk_box_append(crumbs, crumbButton(self, "Folders", 0));
    var names: [64][]const u8 = undefined;
    var count: usize = 0;
    names[count] = displayName(top.path);
    count += 1;
    var components = std.mem.tokenizeScalar(u8, folders.path.value, '/');
    while (components.next()) |component| {
        if (count == names.len) break;
        names[count] = component;
        count += 1;
    }
    for (names[0..count], 0..) |name, index| {
        gtk.gtk_box_append(crumbs, separator());
        if (index + 1 == count)
            gtk.gtk_box_append(crumbs, crumbLabel(name, "breadcrumb-current"))
        else
            gtk.gtk_box_append(crumbs, crumbButton(self, name, index + 1));
    }
}

fn crumbClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-depth"));
    if (marked == 0) return;
    const depth = marked - 1;
    const root_id = self.folders.root_id orelse return;
    if (depth == 0) return open(self, null, "", .list);
    const path = self.folders.path.value;
    var end: usize = 0;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    var taken: usize = 1;
    while (taken < depth) : (taken += 1) {
        const component = components.next() orelse break;
        end = @intFromPtr(component.ptr) - @intFromPtr(path.ptr) + component.len;
    }
    open(self, root_id, path[0..end], .list);
}

fn reloadFiles(self: *App) void {
    const folders = &self.folders;
    const store = folders.files_store orelse return;
    folders.suppress = true;
    gtk.g_list_store_remove_all(store);
    folders.suppress = false;
    folders.entries.clearRetainingCapacity();
    folders.loaded = 0;
    folders.exhausted = false;
    folders.folder_count = 0;
    folders.file_count = 0;
    folders.files_below = 0;
    if (folders.root_id == null) listRoots(self) else loadNext(self);
    updateCount(self);
}

fn listRoots(self: *App) void {
    const folders = &self.folders;
    const store = folders.files_store orelse return;
    folders.exhausted = true;
    for (folders.roots.items) |root| {
        const object = browse_model.newWithCaption(root.id, displayName(root.path), root.path, "") orelse continue;
        folders.entries.append(self.allocator, .{ .kind = .root, .root_id = root.id }) catch {
            gtk.g_object_unref(object);
            return;
        };
        gtk.g_list_store_append(store, object);
        gtk.g_object_unref(object);
        folders.folder_count += 1;
    }
}

fn plural(buffer: []u8, count: u64, one: []const u8, many: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) one else many }) catch "";
}

fn formatText(buffer: []u8, summary: liborca.TrackSummary) []const u8 {
    if (summary.codec.len == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    signal_path.writeCodecName(&writer, summary.codec) catch return "";
    if (summary.bit_depth) |bits| writer.print(" {d}-bit", .{bits}) catch return writer.buffered();
    if (summary.sample_rate) |rate| {
        writer.writeAll(" · ") catch return writer.buffered();
        signal_path.writeRate(&writer, rate) catch return writer.buffered();
    }
    return writer.buffered();
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
    if (page.items.len < app.page_size) folders.exhausted = true;
    var additions: std.ArrayList(?*anyopaque) = .empty;
    defer {
        for (additions.items) |row| gtk.g_object_unref(row);
        additions.deinit(self.allocator);
    }
    for (page.items) |item| {
        var column_buffer: [96]u8 = undefined;
        var column: []const u8 = "";
        var secondary: []const u8 = "";
        var summary: ?liborca.TrackSummary = null;
        defer if (summary) |found| found.deinit(self.allocator);
        var entry: Entry = .{
            .kind = if (item.kind == .folder) .folder else .file,
            .root_id = root_id,
            .track_id = item.track_id,
            .duration_ms = item.total_duration_ms,
        };
        switch (item.kind) {
            .folder => column = plural(&column_buffer, item.file_count, "file", "files"),
            .file => if (item.track_id) |id| {
                summary = self.runtime.libraryTrackSummary(library, id) catch null;
                if (summary) |found| {
                    if (found.title.len != 0 and !std.mem.eql(u8, found.title, stem(item.name))) secondary = found.title;
                    if (entry.duration_ms <= 0) entry.duration_ms = found.duration_ms orelse 0;
                    column = formatText(&column_buffer, found);
                }
            },
        }
        const object = browse_model.newWithCaption(item.track_id, item.name, secondary, column) orelse continue;
        additions.append(self.allocator, object) catch {
            gtk.g_object_unref(object);
            break;
        };
        folders.entries.append(self.allocator, entry) catch {
            _ = additions.pop();
            gtk.g_object_unref(object);
            break;
        };
        switch (item.kind) {
            .folder => {
                folders.folder_count += 1;
                folders.files_below += item.file_count;
            },
            .file => {
                folders.file_count += 1;
                folders.files_below += 1;
            },
        }
    }
    if (additions.items.len != 0) {
        folders.suppress = true;
        gtk.g_list_store_splice(
            store,
            gtk.g_list_model_get_n_items(gtk.cast(gtk.ListModel, store)),
            0,
            additions.items.ptr,
            @intCast(additions.items.len),
        );
        folders.suppress = false;
    }
    folders.loaded += @intCast(page.items.len);
}

fn updateCount(self: *App) void {
    const folders = &self.folders;
    const label = folders.count orelse return;
    var folder_buffer: [48]u8 = undefined;
    var file_buffer: [48]u8 = undefined;
    var buffer: [128]u8 = undefined;
    const folders_text = plural(&folder_buffer, folders.folder_count, "folder", "folders");
    if (folders.root_id == null) return gtk.gtk_label_set_text(label, strings.terminated(&buffer, folders_text).ptr);
    const files_text = plural(&file_buffer, folders.files_below, "file", "files");
    const more: []const u8 = if (folders.exhausted) "" else "+";
    const text = if (folders.folder_count == 0)
        strings.format(&buffer, "{s}{s}", .{ files_text, more })
    else
        strings.format(&buffer, "{s} • {s}{s}", .{ folders_text, files_text, more });
    gtk.gtk_label_set_text(label, text.ptr);
}

fn filesMoved(adjustment: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.folders.exhausted) return;
    const value = gtk.cast(gtk.Adjustment, adjustment);
    const page = gtk.gtk_adjustment_get_page_size(value);
    const remaining = gtk.gtk_adjustment_get_upper(value) - (gtk.gtk_adjustment_get_value(value) + page);
    if (remaining < page) {
        loadNext(self);
        updateCount(self);
    }
}

fn objectAt(store: *gtk.ListStore, position: usize) ?*BrowseObject {
    const object = gtk.g_list_model_get_item(gtk.cast(gtk.ListModel, store), @intCast(position)) orelse return null;
    gtk.g_object_unref(object);
    return @ptrCast(@alignCast(object));
}

fn activateAt(self: *App, position: usize) void {
    const folders = &self.folders;
    if (position >= folders.entries.items.len) return;
    const entry = folders.entries.items[position];
    switch (entry.kind) {
        .root => open(self, entry.root_id, "", .list),
        .folder => {
            const store = folders.files_store orelse return;
            const object = objectAt(store, position) orelse return;
            const path = joinPath(self.allocator, folders.path.value, object.name()) catch return;
            defer self.allocator.free(path);
            open(self, entry.root_id, path, .list);
        },
        .file => playFrom(self, position),
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

fn playFrom(self: *App, position: usize) void {
    const folders = &self.folders;
    if (folders.entries.items[position].track_id == null) return self.toast("This file is not in the library yet");
    var start: u32 = 0;
    for (folders.entries.items[0..position]) |entry| {
        if (entry.kind == .file and entry.track_id != null) start += 1;
    }
    const ids = levelTrackIds(self) catch return self.toast("Could not read this folder");
    defer self.allocator.free(ids);
    if (start >= ids.len) return;
    transport.playIds(self, ids, start);
}

fn playFolder(self: *App, shuffle: bool) void {
    const folders = &self.folders;
    const root_id = folders.root_id orelse return;
    const library = self.library orelse return;
    if (!transport.ensureOutput(self)) return self.toast("No audio output is available");
    self.runtime.playerPlayFolder(self.player, library, self.io, root_id, folders.path.value, shuffle) catch |err| switch (err) {
        error.FolderEmpty => return self.toast("No songs in this folder"),
        else => return self.toast("Could not start playback"),
    };
    self.requestTick();
}

fn playClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playFolder(state(data), false);
}

fn shuffleClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    playFolder(state(data), true);
}

fn filesActivated(_: ?*anyopaque, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    activateAt(state(data), position);
}

fn rowLabel(class: [*:0]const u8) *gtk.Widget {
    const label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, class);
    return label;
}

fn setupFile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "folder-row");
    const icon = gtk.gtk_image_new_from_icon_name("folder-symbolic");
    gtk.gtk_widget_add_css_class(icon, "folder-row-icon");
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    const name = rowLabel("folder-row-name");
    const secondary = rowLabel("folder-row-secondary");
    gtk.gtk_widget_add_css_class(secondary, "dim-label");
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, name), 1);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, secondary), 1);
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    gtk.gtk_widget_set_hexpand(secondary, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), secondary);
    const column = rowLabel("folder-row-column");
    gtk.gtk_widget_add_css_class(column, "dim-label");
    gtk.gtk_widget_add_css_class(column, "numeric");
    gtk.gtk_widget_set_size_request(column, column_pixels, -1);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, column), 1);
    const duration = rowLabel("folder-row-duration");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration), 1.0);
    gtk.gtk_widget_add_css_class(duration, "dim-label");
    gtk.gtk_widget_add_css_class(duration, "numeric");
    gtk.gtk_widget_set_size_request(duration, duration_pixels, -1);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, duration), 1);
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    _ = gtk.signalConnect(more, "clicked", gtk.callback(moreClicked), self);
    for ([_]*gtk.Widget{ icon, labels, column, duration, more }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    menu.onSecondaryClick(box, rowMenu, self);
    gtk.gtk_list_item_set_child(gtk.cast(gtk.ListItem, item), box);
    gtk.g_object_set_data(box, "orca-icon", icon);
    gtk.g_object_set_data(box, "orca-name", name);
    gtk.g_object_set_data(box, "orca-secondary", secondary);
    gtk.g_object_set_data(box, "orca-column", column);
    gtk.g_object_set_data(box, "orca-duration", duration);
    gtk.g_object_set_data(box, "orca-more", more);
    fitName(box, self.folders.narrow);
}

fn fitName(box: *gtk.Widget, narrow: bool) void {
    const name = part(box, "orca-name") orelse return;
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, name), if (narrow) -1 else 1);
    gtk.gtk_widget_set_hexpand(name, @intFromBool(!narrow));
}

fn bindFile(_: ?*anyopaque, item: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const list_item = gtk.cast(gtk.ListItem, item);
    const position = gtk.gtk_list_item_get_position(list_item);
    if (position >= self.folders.entries.items.len) return;
    const entry = self.folders.entries.items[position];
    const object: *BrowseObject = @ptrCast(@alignCast(gtk.gtk_list_item_get_item(list_item) orelse return));
    const box = gtk.gtk_list_item_get_child(list_item) orelse return;
    gtk.g_object_set_data(box, "orca-position", @ptrFromInt(@as(usize, position) + 1));
    const icon: [*:0]const u8 = if (entry.kind == .file) "audio-x-generic-symbolic" else "folder-symbolic";
    if (part(box, "orca-icon")) |image| gtk.gtk_image_set_from_icon_name(gtk.cast(gtk.Image, image), icon);
    if (part(box, "orca-name")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), object.name().ptr);
    if (part(box, "orca-secondary")) |label| {
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), object.detail().ptr);
        gtk.gtk_widget_set_visible(label, @intFromBool(object.detail().len != 0));
    }
    if (part(box, "orca-column")) |label| {
        gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), object.caption().ptr);
        gtk.gtk_widget_set_visible(label, @intFromBool(!self.folders.narrow));
    }
    var buffer: [32]u8 = undefined;
    const duration: [:0]const u8 = if (entry.duration_ms <= 0)
        ""
    else if (entry.kind == .file)
        strings.formatMs(&buffer, @intCast(entry.duration_ms))
    else
        strings.terminated(buffer[16..], strings.totalDuration(buffer[0..16], entry.duration_ms));
    if (part(box, "orca-duration")) |label| gtk.gtk_label_set_text(gtk.cast(gtk.Label, label), duration.ptr);
    if (part(box, "orca-more")) |more| {
        gtk.g_object_set_data(more, "orca-position", @ptrFromInt(@as(usize, position) + 1));
        const usable = entry.kind == .file;
        gtk.gtk_widget_set_can_target(more, @intFromBool(usable));
        gtk.gtk_widget_set_can_focus(more, @intFromBool(usable));
        if (usable) gtk.gtk_widget_remove_css_class(more, "unused") else gtk.gtk_widget_add_css_class(more, "unused");
    }
    gtk.gtk_widget_set_tooltip_text(box, object.name().ptr);
}

fn markedPosition(widget: *gtk.Widget) ?usize {
    const marked = @intFromPtr(gtk.g_object_get_data(widget, "orca-position"));
    if (marked == 0) return null;
    return marked - 1;
}

fn moreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const position = markedPosition(widget) orelse return;
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    fileMenu(self, widget, position, x, y);
}

fn rowMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const box = menu.gestureWidget(gesture);
    const position = markedPosition(box) orelse return;
    fileMenu(self, box, position, x, y);
}

fn fileMenu(self: *App, widget: *gtk.Widget, position: usize, x: f64, y: f64) void {
    const folders = &self.folders;
    if (position >= folders.entries.items.len) return;
    const entry = folders.entries.items[position];
    if (entry.kind != .file) return;
    folders.menu_position = position;
    const items = gtk.g_menu_new();
    defer gtk.g_object_unref(items);
    const reveal = gtk.g_menu_new();
    gtk.g_menu_append(reveal, "Show in Files", "folders.reveal");
    gtk.g_menu_append_section(items, null, gtk.cast(gtk.GMenuModel, reveal));
    gtk.g_object_unref(reveal);
    if (trackContext(self, entry.track_id)) {
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
    const position = folders.menu_position orelse return;
    if (position >= folders.entries.items.len) return;
    const root = rootById(self, folders.entries.items[position].root_id) orelse return;
    const store = folders.files_store orelse return;
    const object = objectAt(store, position) orelse return;
    const relative = joinPath(self.allocator, folders.path.value, object.name()) catch return;
    defer self.allocator.free(relative);
    const absolute = std.mem.concatWithSentinel(self.allocator, u8, &.{ std.mem.trimEnd(u8, root.path, "/"), "/", relative }, 0) catch return;
    defer self.allocator.free(absolute);
    const file = gtk.g_file_new_for_path(absolute.ptr);
    defer gtk.g_object_unref(file);
    if (gtk.g_file_query_exists(file, null) == 0) return self.toast("File not found");
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_open_containing_folder(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

const ReleaseGroup = struct {
    release_id: ?i64,
    order: usize,
};

const Sorting = struct {
    summaries: []const liborca.TrackSummary,
    groups: []const usize,

    fn lessThan(context: Sorting, left: usize, right: usize) bool {
        if (context.groups[left] != context.groups[right]) return context.groups[left] < context.groups[right];
        const a = context.summaries[left];
        const b = context.summaries[right];
        const disc_a = a.disc_number orelse 0;
        const disc_b = b.disc_number orelse 0;
        if (disc_a != disc_b) return disc_a < disc_b;
        const track_a = a.track_number orelse std.math.maxInt(i64);
        const track_b = b.track_number orelse std.math.maxInt(i64);
        if (track_a != track_b) return track_a < track_b;
        return left < right;
    }
};

fn fillLibrary(self: *App) void {
    const folders = &self.folders;
    folders.library_stale = false;
    folders.library_tracks.clearRetainingCapacity();
    const list = folders.library_list orelse return;
    gtk.gtk_list_box_remove_all(list);
    const library = self.library orelse return;
    const ids = levelTrackIds(self) catch return;
    defer self.allocator.free(ids);
    var summaries: std.ArrayList(liborca.TrackSummary) = .empty;
    defer {
        for (summaries.items) |summary| summary.deinit(self.allocator);
        summaries.deinit(self.allocator);
    }
    for (ids) |id| {
        const summary = (self.runtime.libraryTrackSummary(library, id) catch null) orelse continue;
        summaries.append(self.allocator, summary) catch {
            summary.deinit(self.allocator);
            break;
        };
    }
    const count = summaries.items.len;
    const groups = self.allocator.alloc(usize, count) catch return;
    defer self.allocator.free(groups);
    const order = self.allocator.alloc(usize, count) catch return;
    defer self.allocator.free(order);
    var seen: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    defer seen.deinit(self.allocator);
    for (summaries.items, 0..) |summary, index| {
        order[index] = index;
        const release = summary.release_id orelse {
            groups[index] = std.math.maxInt(usize);
            continue;
        };
        const found = seen.getOrPut(self.allocator, release) catch return;
        if (!found.found_existing) found.value_ptr.* = seen.count() - 1;
        groups[index] = found.value_ptr.*;
    }
    std.sort.pdq(usize, order, Sorting{ .summaries = summaries.items, .groups = groups }, Sorting.lessThan);
    folders.library_tracks.ensureTotalCapacity(self.allocator, count) catch return;
    var previous_group: ?usize = null;
    for (order) |index| {
        const summary = summaries.items[index];
        const starts = previous_group != groups[index];
        previous_group = groups[index];
        const row = libraryRow(self, summary, folders.library_tracks.items.len, starts);
        gtk.gtk_list_box_append(list, row);
        folders.library_tracks.appendAssumeCapacity(.{
            .id = summary.id,
            .recording_id = summary.recording_id,
            .feedback = summary.feedback,
            .release_id = summary.release_id,
            .artist_id = summary.artist_id,
        });
    }
}

fn columnLabel(text: []const u8, width: c_int) *gtk.Widget {
    var buffer: [128]u8 = undefined;
    const label = gtk.gtk_label_new(strings.terminated(&buffer, text).ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, label), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, label), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_size_request(label, width, -1);
    gtk.gtk_widget_add_css_class(label, "album-track-column");
    gtk.gtk_widget_add_css_class(label, "dim-label");
    return label;
}

fn releaseHeader(self: *App, summary: liborca.TrackSummary) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "folder-release");
    const cover = art.newCover(self, art.initialsPlaceholder(), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "album-cover");
    art.setInitials(cover, summary.album);
    art.show(self, cover, if (summary.release_id) |release| art.Key.release(release, .thumb) else art.Key.track(summary.id, .thumb));
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    var buffer: [512]u8 = undefined;
    const album: []const u8 = if (summary.release_id == null) "Other Songs" else if (summary.album.len != 0) summary.album else "Untitled";
    const title = gtk.gtk_label_new(strings.terminated(&buffer, album).ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(title, "folder-release-title");
    const artist = if (summary.album_artist.len != 0) summary.album_artist else summary.artist;
    const detail_text = if (summary.release_id == null)
        strings.terminated(&buffer, "")
    else if (summary.year) |year|
        (if (artist.len != 0) strings.format(&buffer, "{s} · {d}", .{ artist, year }) else strings.format(&buffer, "{d}", .{year}))
    else
        strings.terminated(&buffer, artist);
    const detail = gtk.gtk_label_new(detail_text.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, detail), 0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, detail), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(detail, "folder-release-detail");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title);
    if (detail_text.len != 0) gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), cover);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), labels);
    return box;
}

fn libraryRow(self: *App, summary: liborca.TrackSummary, position: usize, starts_group: bool) *gtk.Widget {
    const row = gtk.gtk_list_box_row_new();
    gtk.gtk_widget_add_css_class(row, "album-track-row");
    gtk.g_object_set_data(row, "orca-position", @ptrFromInt(position + 1));
    if (starts_group) {
        const header = releaseHeader(self, summary);
        gtk.g_object_set_data_full(row, "orca-header", gtk.g_object_ref_sink(header), gtk.g_object_unref);
    }
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(box, "album-track");
    var buffer: [512]u8 = undefined;
    const number: [:0]const u8 = if (summary.track_number) |value| strings.format(&buffer, "{d}", .{value}) else "";
    const number_label = gtk.gtk_label_new(number.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number_label), 1.0);
    gtk.gtk_widget_set_size_request(number_label, number_pixels, -1);
    gtk.gtk_widget_add_css_class(number_label, "numeric");
    gtk.gtk_widget_add_css_class(number_label, "album-track-number");
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const title = gtk.gtk_label_new(strings.terminated(&buffer, if (summary.title.len != 0) summary.title else "Untitled").ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(title, "album-track-title");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), title);
    if (summary.artist.len != 0 and !std.mem.eql(u8, summary.artist, summary.album_artist)) {
        const artist = gtk.gtk_label_new(strings.terminated(&buffer, summary.artist).ptr);
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, artist), 0.0);
        gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, artist), gtk.ELLIPSIZE_END);
        gtk.gtk_widget_add_css_class(artist, "caption");
        gtk.gtk_widget_add_css_class(artist, "dim-label");
        gtk.gtk_box_append(gtk.cast(gtk.Box, labels), artist);
    }
    var format_buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&format_buffer);
    if (summary.codec.len != 0) {
        signal_path.writeCodecName(&writer, summary.codec) catch {};
        if (summary.bit_depth) |bits| writer.print(" {d}-bit", .{bits}) catch {};
    }
    const format_label = columnLabel(writer.buffered(), format_pixels);
    writer = std.Io.Writer.fixed(&format_buffer);
    if (summary.sample_rate) |rate| signal_path.writeRate(&writer, rate) catch {};
    const rate_label = columnLabel(writer.buffered(), rate_pixels);
    const duration: [:0]const u8 = if (summary.duration_ms) |ms|
        (if (ms >= 0) strings.formatMs(&buffer, @intCast(ms)) else "")
    else
        "";
    const duration_label = gtk.gtk_label_new(duration.ptr);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, duration_label), 1.0);
    gtk.gtk_widget_set_size_request(duration_label, track_duration_pixels, -1);
    gtk.gtk_widget_add_css_class(duration_label, "numeric");
    gtk.gtk_widget_add_css_class(duration_label, "dim-label");
    const more = gtk.gtk_button_new_from_icon_name("view-more-symbolic");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "row-more");
    gtk.gtk_widget_set_valign(more, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(more, "More");
    gtk.g_object_set_data(more, "orca-position", @ptrFromInt(position + 1));
    _ = gtk.signalConnect(more, "clicked", gtk.callback(libraryMoreClicked), self);
    for ([_]*gtk.Widget{ number_label, labels, format_label, rate_label, duration_label, more }) |piece|
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), piece);
    gtk.gtk_list_box_row_set_child(gtk.cast(gtk.ListBoxRow, row), box);
    menu.onSecondaryClick(row, libraryRowMenu, self);
    if (!summary.has_playable_file) gtk.gtk_widget_set_sensitive(row, gtk.false_);
    return row;
}

fn updateHeader(row: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const list_row = gtk.cast(gtk.ListBoxRow, row.?);
    if (gtk.gtk_list_box_row_get_header(list_row) != null) return;
    const header = part(gtk.cast(gtk.Widget, list_row), "orca-header") orelse return;
    gtk.gtk_list_box_row_set_header(list_row, header);
}

fn libraryContext(self: *App, position: usize) bool {
    const tracks = self.folders.library_tracks.items;
    if (position >= tracks.len) return false;
    const track = tracks[position];
    self.context.reset(.tracks);
    self.context.addTrack(self.allocator, track.id, track.recording_id, track.feedback) catch return false;
    self.context.release_id = track.release_id;
    self.context.artist_id = track.artist_id;
    return true;
}

fn libraryMoreClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const widget = gtk.cast(gtk.Widget, button.?);
    const position = markedPosition(widget) orelse return;
    if (!libraryContext(self, position)) return;
    const x: f64 = @floatFromInt(@divTrunc(gtk.gtk_widget_get_width(widget), 2));
    const y: f64 = @floatFromInt(gtk.gtk_widget_get_height(widget));
    menu.popup(self, widget, x, y);
}

fn libraryRowMenu(gesture: ?*anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const row = menu.gestureWidget(gesture);
    const position = markedPosition(row) orelse return;
    if (libraryContext(self, position)) menu.popup(self, row, x, y);
}

fn libraryActivated(_: ?*anyopaque, row: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const position = markedPosition(gtk.cast(gtk.Widget, row.?)) orelse return;
    const tracks = self.folders.library_tracks.items;
    if (position >= tracks.len) return;
    const ids = self.allocator.alloc(i64, tracks.len) catch return;
    defer self.allocator.free(ids);
    for (tracks, ids) |track, *id| id.* = track.id;
    transport.playIds(self, ids, @intCast(position));
}

fn modeToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button.?)) == 0) return;
    const marked = @intFromPtr(gtk.g_object_get_data(button.?, "orca-mode"));
    if (marked == 0) return;
    const mode: Mode = @enumFromInt(marked - 1);
    if (self.folders.mode == mode) return;
    self.folders.mode = mode;
    if (mode == .library and self.folders.library_stale) fillLibrary(self);
    showBody(self);
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
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(box, "folder-node");
    const icon = gtk.gtk_image_new_from_icon_name("folder-symbolic");
    gtk.gtk_widget_add_css_class(icon, "folder-row-icon");
    const label = rowLabel("folder-node-name");
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
    gtk.gtk_widget_add_css_class(view, "navigation-sidebar");
    self.folders.tree_view = view;
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), view);
    gtk.gtk_widget_set_size_request(scroller, pane_width, -1);
    gtk.gtk_widget_add_css_class(scroller, "folder-pane");
    self.folders.pane = scroller;
    return scroller;
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
    _ = gtk.signalConnect(
        gtk.gtk_scrolled_window_get_vadjustment(gtk.cast(gtk.ScrolledWindow, scroller)),
        "value-changed",
        gtk.callback(filesMoved),
        self,
    );
    return scroller;
}

fn buildLibrary(self: *App) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    gtk.gtk_widget_add_css_class(list, "album-tracks");
    gtk.gtk_widget_add_css_class(list, "folder-library");
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_SINGLE);
    gtk.gtk_list_box_set_activate_on_single_click(gtk.cast(gtk.ListBox, list), gtk.false_);
    gtk.gtk_list_box_set_header_func(gtk.cast(gtk.ListBox, list), updateHeader, null, null);
    _ = gtk.signalConnect(list, "row-activated", gtk.callback(libraryActivated), self);
    self.folders.library_list = gtk.cast(gtk.ListBox, list);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), list);
    return scroller;
}

fn modeButton(self: *App, label: [*:0]const u8, mode: Mode) *gtk.Widget {
    const button = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, button), label);
    gtk.g_object_set_data(button, "orca-mode", @ptrFromInt(@as(usize, @intFromEnum(mode)) + 1));
    _ = gtk.signalConnect(button, "toggled", gtk.callback(modeToggled), self);
    return button;
}

fn actionButton(label: [*:0]const u8, icon: [*:0]const u8, suggested: bool) *gtk.Widget {
    const button = gtk.gtk_button_new();
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_image_new_from_icon_name(icon));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), gtk.gtk_label_new(label));
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "folder-action");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    if (suggested) gtk.gtk_widget_add_css_class(button, "suggested-action");
    return button;
}

fn buildToolbar(self: *App) *gtk.Widget {
    const toolbar = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(toolbar, "folder-toolbar");
    const files = modeButton(self, "Files", .files);
    const library = modeButton(self, "Library", .library);
    gtk.gtk_toggle_button_set_group(gtk.cast(gtk.ToggleButton, library), gtk.cast(gtk.ToggleButton, files));
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, if (self.folders.mode == .files) files else library), gtk.true_);
    const switcher = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(switcher, "linked");
    gtk.gtk_widget_add_css_class(switcher, "view-switch");
    gtk.gtk_widget_set_valign(switcher, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, switcher), files);
    gtk.gtk_box_append(gtk.cast(gtk.Box, switcher), library);
    const play = actionButton("Play", "media-playback-start-symbolic", true);
    gtk.gtk_widget_set_tooltip_text(play, "Play this folder and every folder in it");
    _ = gtk.signalConnect(play, "clicked", gtk.callback(playClicked), self);
    self.folders.play = play;
    const shuffle = actionButton("Shuffle", "media-playlist-shuffle-symbolic", false);
    gtk.gtk_widget_set_tooltip_text(shuffle, "Shuffle this folder and every folder in it");
    _ = gtk.signalConnect(shuffle, "clicked", gtk.callback(shuffleClicked), self);
    self.folders.shuffle = shuffle;
    const count = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(count, "meta");
    gtk.gtk_widget_add_css_class(count, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, count), 1.0);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, count), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_hexpand(count, gtk.true_);
    self.folders.count = gtk.cast(gtk.Label, count);
    for ([_]*gtk.Widget{ switcher, play, shuffle, count }) |piece| gtk.gtk_box_append(gtk.cast(gtk.Box, toolbar), piece);
    self.folders.toolbar = toolbar;
    return toolbar;
}

fn buildEmpty() *gtk.Widget {
    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "folder-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "No audio files here.");
    return empty;
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
    var row = gtk.gtk_widget_get_first_child(view);
    while (row) |widget| : (row = gtk.gtk_widget_get_next_sibling(widget)) {
        const box = gtk.gtk_widget_get_first_child(widget) orelse continue;
        if (part(box, "orca-column")) |label| gtk.gtk_widget_set_visible(label, @intFromBool(!narrow));
        fitName(box, narrow);
    }
}

fn narrowed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setNarrow(state(data), true);
}

fn widened(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    setNarrow(state(data), false);
}

pub fn build(self: *App) *gtk.Widget {
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    self.folders.crumbs = gtk.cast(gtk.Box, crumbs);
    rebuildCrumbs(self);
    page_ui.addTrail(self, .folders, crumbs);

    const body = gtk.gtk_stack_new();
    self.folders.body = gtk.cast(gtk.Stack, body);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildFiles(self), "files");
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildLibrary(self), "library");
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildEmpty(), "empty");
    _ = gtk.gtk_stack_add_named(self.folders.body.?, buildWelcome(), "welcome");

    const right = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(right, gtk.true_);
    gtk.gtk_widget_add_css_class(right, "folder-content");
    gtk.gtk_box_append(gtk.cast(gtk.Box, right), buildToolbar(self));
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
    gtk.gtk_box_append(gtk.cast(gtk.Box, split), buildTree(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, split), bin);

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
    return split;
}
