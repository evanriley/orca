//! A library folder that cannot be read: the banner over the pages, the
//! sidebar's offline count and the dimming of albums that cannot play.
//! liborca decides what is offline; this file only shows it.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const strings = @import("strings.zig");
const window = @import("window.zig");
const albums = @import("albums.zig");
const folders = @import("folders.zig");
const jobs = @import("jobs.zig");
const activity = @import("activity.zig");

const App = app.App;

const release_cache_limit = 4096;

const Check = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    availability: ?liborca.LibraryAvailability = null,

    fn run(self: *Check) void {
        self.availability = self.runtime.libraryAvailability(self.library, self.threaded.io()) catch null;
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn destroy(self: *Check, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.availability) |availability| availability.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

pub const State = struct {
    availability: ?liborca.LibraryAvailability = null,
    releases: std.AutoHashMapUnmanaged(i64, bool) = .empty,
    check: ?*Check = null,
    check_again: bool = false,
    retrying: bool = false,
    banner: ?*gtk.Widget = null,
    title: ?*gtk.Label = null,
    body: ?*gtk.Label = null,
    details: ?*gtk.Popover = null,
    retry: ?*gtk.Widget = null,
    retry_label: ?*gtk.Label = null,
    relocating_root: ?i64 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.availability) |availability| availability.deinit();
        self.availability = null;
        self.releases.deinit(allocator);
    }

    pub fn offlineRoots(self: *const State) []const liborca.LibraryRoot {
        const availability = self.availability orelse return &.{};
        return availability.offline_roots;
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

/// Asks liborca again, on a thread of its own, which roots are offline; `tick`
/// shows the answer. A request while a check runs repeats it once it ends.
pub fn refresh(self: *App) void {
    const offline = &self.offline;
    if (offline.check != null) {
        offline.check_again = true;
        return;
    }
    offline.check_again = false;
    const library = self.library orelse return finishRetry(self);
    const check = self.allocator.create(Check) catch return finishRetry(self);
    check.* = .{ .runtime = self.runtime, .library = library, .waker = self.waker() };
    check.thread = std.Thread.spawn(.{}, Check.run, .{check}) catch {
        check.destroy(self.allocator);
        return finishRetry(self);
    };
    offline.check = check;
}

pub fn tick(self: *App) void {
    const offline = &self.offline;
    const check = offline.check orelse return;
    if (!check.finished.load(.acquire)) return;
    offline.check = null;
    defer check.destroy(self.allocator);
    const before = summary(offline);
    if (offline.availability) |availability| availability.deinit();
    offline.availability = check.availability;
    check.availability = null;
    offline.releases.clearRetainingCapacity();
    showBanner(self);
    showCount(self);
    albums.showUnavailable(self);
    if (!std.meta.eql(before, summary(offline))) {
        albums.reloadKeepingScroll(self);
        folders.invalidate(self);
        window.refreshCounts(self);
    }
    if (offline.check_again) return refresh(self);
    if (offline.retrying and offline.offlineRoots().len != 0) self.toast("The folder is still not available");
    finishRetry(self);
}

/// Joins a check still running; before main closes the wake eventfd it writes.
pub fn shutdown(self: *App) void {
    if (self.offline.check) |check| check.destroy(self.allocator);
    self.offline.check = null;
}

fn finishRetry(self: *App) void {
    const offline = &self.offline;
    offline.retrying = false;
    if (offline.retry) |button| gtk.gtk_widget_set_sensitive(button, gtk.true_);
    if (offline.retry_label) |label| gtk.gtk_label_set_text(label, "Try Again");
}

const Summary = struct { roots: usize, tracks: u64, releases: u64, first: i64 };

fn summary(offline: *const State) Summary {
    const availability = offline.availability orelse return .{ .roots = 0, .tracks = 0, .releases = 0, .first = 0 };
    return .{
        .roots = availability.offline_roots.len,
        .tracks = availability.unavailable_tracks,
        .releases = availability.unavailable_releases,
        .first = if (availability.offline_roots.len != 0) availability.offline_roots[0].id else 0,
    };
}

pub fn unavailableReleases(self: *const App) u64 {
    const availability = self.offline.availability orelse return 0;
    return availability.unavailable_releases;
}

/// Whether Release `release_id` can still play, or null while every root is
/// online and nothing needs marking.
pub fn releaseAvailable(self: *App, release_id: i64) ?bool {
    const offline = &self.offline;
    const availability = &(offline.availability orelse return null);
    if (availability.offline_roots.len == 0) return null;
    if (offline.releases.get(release_id)) |known| return known;
    var available = [1]bool{true};
    prefetch(self, &.{release_id}, &available);
    return offline.releases.get(release_id) orelse available[0];
}

/// Looks up a page of Releases at once, ahead of their tiles binding.
pub fn prefetchReleases(self: *App, releases: []const liborca.ReleaseSummary) void {
    const availability = self.offline.availability orelse return;
    if (availability.offline_roots.len == 0) return;
    var ids: [app.page_size]i64 = undefined;
    var available: [app.page_size]bool = undefined;
    const count = @min(releases.len, ids.len);
    for (releases[0..count], 0..) |release, index| ids[index] = release.id;
    prefetch(self, ids[0..count], available[0..count]);
}

fn prefetch(self: *App, ids: []const i64, available: []bool) void {
    const library = self.library orelse return;
    const offline = &self.offline;
    const availability = &(offline.availability orelse return);
    self.runtime.libraryReleasesAvailable(library, availability, ids, available) catch return;
    if (offline.releases.count() + ids.len > release_cache_limit) offline.releases.clearRetainingCapacity();
    for (ids, available) |id, value| offline.releases.put(self.allocator, id, value) catch return;
}

/// Dims a cover tile whose Release cannot play, and badges one that can while
/// another folder is offline.
pub fn markTile(self: *App, tile: *gtk.Widget, release_id: ?i64) void {
    const available: ?bool = if (release_id) |id| releaseAvailable(self, id) else null;
    if (available == false)
        gtk.gtk_widget_add_css_class(tile, "unavailable")
    else
        gtk.gtk_widget_remove_css_class(tile, "unavailable");
    const badge = gtk.g_object_get_data(tile, "orca-local") orelse return;
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, badge), @intFromBool(available == true));
}

pub fn localBadge() *gtk.Widget {
    const badge = gtk.gtk_label_new("On this computer");
    gtk.gtk_widget_add_css_class(badge, "local-badge");
    gtk.gtk_widget_set_halign(badge, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(badge, gtk.ALIGN_END);
    gtk.gtk_widget_set_can_target(badge, gtk.false_);
    gtk.gtk_widget_set_visible(badge, gtk.false_);
    return badge;
}

fn showCount(self: *App) void {
    const label = self.folders_count orelse return;
    const count = self.offline.offlineRoots().len;
    var buffer: [32]u8 = undefined;
    const text: [:0]const u8 = if (count == 0) "" else strings.printZ(&buffer, "{d} offline", .{count}) catch "";
    gtk.gtk_label_set_text(label, text.ptr);
    if (count == 0)
        gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, label), "nav-count-warn")
    else
        gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, label), "nav-count-warn");
}

/// The banner is hidden on pages drawn edge to edge.
pub fn showBanner(self: *App) void {
    const banner = self.offline.banner orelse return;
    const roots = self.offline.offlineRoots();
    const page_allows = switch (self.current_page) {
        .now_playing, .scan => false,
        else => true,
    };
    gtk.gtk_widget_set_visible(banner, @intFromBool(roots.len != 0 and page_allows));
    if (roots.len == 0) return;
    if (self.offline.title) |title| gtk.gtk_label_set_text(title, if (roots.len == 1)
        "Your music folder isn't available"
    else
        "Some of your music folders aren't available");
    if (self.offline.body) |body| showBody(self, body, roots);
    showDetails(self, roots);
}

fn showBody(self: *App, body: *gtk.Label, roots: []const liborca.LibraryRoot) void {
    const escaped = gtk.g_markup_escape_text(roots[0].path.ptr, @intCast(roots[0].path.len));
    defer gtk.g_free(escaped);
    const tracks = (self.offline.availability orelse return).unavailable_tracks;
    var others_buffer: [64]u8 = undefined;
    const others: []const u8 = switch (roots.len) {
        1 => " isn't mounted. It may be on a drive that's unplugged or a network share that's offline.",
        2 => " and 1 other folder aren't mounted. They may be on drives that are unplugged or network shares that are offline.",
        else => strings.format(&others_buffer, " and {d} other folders aren't mounted.", .{roots.len - 1}),
    };
    var buffer: [4096]u8 = undefined;
    const text = strings.printZ(&buffer, "<span font_family=\"Geist Mono, monospace\" size=\"96%\">{s}</span>{s} {f} {s} play until {s} back.", .{
        std.mem.span(escaped),
        others,
        strings.grouped(tracks),
        if (tracks == 1) "track can't" else "tracks can't",
        if (roots.len == 1) "it's" else "they're",
    }) catch return;
    gtk.gtk_label_set_markup(body, text.ptr);
}

fn showDetails(self: *App, roots: []const liborca.LibraryRoot) void {
    const popover = self.offline.details orelse return;
    const grid = gtk.gtk_grid_new();
    gtk.gtk_widget_add_css_class(grid, "offline-details");
    gtk.gtk_grid_set_column_spacing(gtk.cast(gtk.Grid, grid), 16);
    gtk.gtk_grid_set_row_spacing(gtk.cast(gtk.Grid, grid), 6);
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    var row: c_int = 0;
    for (roots, 0..) |root, index| {
        if (index == 8) break;
        var path_buffer: [1024]u8 = undefined;
        var volume_buffer: [256]u8 = undefined;
        var seen_buffer: [128]u8 = undefined;
        var ago_buffer: [64]u8 = undefined;
        var time_buffer: [64]u8 = undefined;
        const seen: [:0]const u8 = if (root.last_seen_at) |then| strings.printZ(&seen_buffer, "{s} · {s}", .{
            activity.agoText(&ago_buffer, now, then),
            activity.localTime(&time_buffer, then, "%-d %b %Y, %H:%M"),
        }) catch "" else "Never";
        const lines = [_]struct { [*:0]const u8, [:0]const u8 }{
            .{ "Folder", strings.terminated(&path_buffer, root.path) },
            .{ "Volume", if (root.volume.len != 0) strings.terminated(&volume_buffer, root.volume) else "Unknown" },
            .{ "Last seen", seen },
        };
        for (lines, 0..) |line, line_index| {
            const name = gtk.gtk_label_new(line[0]);
            gtk.gtk_widget_add_css_class(name, "offline-details-name");
            gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, name), 0.0);
            gtk.gtk_widget_set_valign(name, gtk.ALIGN_START);
            const value = gtk.gtk_label_new(line[1].ptr);
            gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, value), 0.0);
            gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, value), gtk.true_);
            gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, value), 48);
            if (line_index == 0) gtk.gtk_widget_add_css_class(value, "offline-details-path");
            gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), name, 0, row, 1, 1);
            gtk.gtk_grid_attach(gtk.cast(gtk.Grid, grid), value, 1, row, 1, 1);
            row += 1;
        }
    }
    gtk.gtk_popover_set_child(popover, grid);
}

pub fn build(self: *App) *gtk.Widget {
    const offline = &self.offline;
    const icon = gtk.gtk_image_new_from_icon_name("orca-drive-off-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 20);
    gtk.gtk_widget_set_halign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(icon, gtk.true_);
    const icon_box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(icon_box, "offline-icon");
    gtk.gtk_widget_set_size_request(icon_box, 40, 40);
    gtk.gtk_widget_set_valign(icon_box, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, icon_box), icon);

    const title = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(title, "offline-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, title), 0.0);
    offline.title = gtk.cast(gtk.Label, title);
    const body = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(body, "offline-body");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, body), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, body), gtk.true_);
    offline.body = gtk.cast(gtk.Label, body);
    const shield = gtk.gtk_image_new_from_icon_name("orca-shield-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, shield), 14);
    gtk.gtk_widget_add_css_class(shield, "offline-shield");
    gtk.gtk_widget_set_valign(shield, gtk.ALIGN_START);
    const safe = gtk.gtk_label_new("Your library, ratings, playlists and play history are safe. Orca won't remove anything while the folder is missing.");
    gtk.gtk_widget_add_css_class(safe, "offline-safe");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, safe), 0.0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, safe), gtk.true_);
    gtk.gtk_widget_set_hexpand(safe, gtk.true_);
    const safe_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    gtk.gtk_box_append(gtk.cast(gtk.Box, safe_row), shield);
    gtk.gtk_box_append(gtk.cast(gtk.Box, safe_row), safe);
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    for ([_]*gtk.Widget{ title, body, safe_row }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, text), part);

    const retry_icon = gtk.gtk_image_new_from_icon_name("orca-refresh-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, retry_icon), 14);
    const retry_content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 7);
    gtk.gtk_box_append(gtk.cast(gtk.Box, retry_content), retry_icon);
    const retry_label = gtk.gtk_label_new("Try Again");
    offline.retry_label = gtk.cast(gtk.Label, retry_label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, retry_content), retry_label);
    const retry = gtk.gtk_button_new();
    offline.retry = retry;
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, retry), retry_content);
    _ = gtk.signalConnect(retry, "clicked", gtk.callback(retryClicked), self);
    const locate = gtk.gtk_button_new_with_label("Locate Folder…");
    _ = gtk.signalConnect(locate, "clicked", gtk.callback(locateClicked), self);
    for ([_]*gtk.Widget{ retry, locate }) |button| gtk.gtk_widget_add_css_class(button, "offline-button");
    const details = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, details), gtk.gtk_label_new("Details"));
    gtk.gtk_widget_add_css_class(details, "offline-more");
    const popover = gtk.gtk_popover_new();
    offline.details = gtk.cast(gtk.Popover, popover);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, details), popover);
    const buttons = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(buttons, gtk.ALIGN_CENTER);
    for ([_]*gtk.Widget{ retry, locate, details }) |button| gtk.gtk_box_append(gtk.cast(gtk.Box, buttons), button);

    const banner = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(banner, "offline-banner");
    gtk.gtk_accessible_update_property(gtk.cast(gtk.Accessible, banner), gtk.ACCESSIBLE_PROPERTY_LABEL, "Music folder unavailable", @as(c_int, -1));
    for ([_]*gtk.Widget{ icon_box, text, buttons }) |part| gtk.gtk_box_append(gtk.cast(gtk.Box, banner), part);
    gtk.gtk_widget_set_visible(banner, gtk.false_);
    offline.banner = banner;
    return banner;
}

fn retryClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const offline = &self.offline;
    offline.retrying = true;
    if (offline.retry) |button| gtk.gtk_widget_set_sensitive(button, gtk.false_);
    if (offline.retry_label) |label| gtk.gtk_label_set_text(label, "Checking…");
    refresh(self);
}

fn locateClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const roots = self.offline.offlineRoots();
    if (roots.len == 0) return;
    jobs.relocateRoot(self, roots[0].id);
}
