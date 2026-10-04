//! Metadata Issues: where a release's tracks disagree with one another or
//! with MusicBrainz, listed by kind, with the value each fix gives the
//! tracks. Fixes change Orca's database only; files change on Write to Files.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const health = @import("health.zig");
const jobs = @import("jobs.zig");

const App = app.App;
const Group = liborca.MetadataIssueGroup;
const Category = liborca.IssueCategory;
const Application = liborca.MetadataIssueApplication;

const max_groups = 2048;
const cover_pixels = 52;
const value_width = 190;
const separator = " · ";
const settled = "Fixes apply to Orca’s database; writing to files is a separate step.";

const Release = struct {
    id: i64,
    year: ?[4]u8 = null,
};

const ListLoader = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    allocator: std.mem.Allocator,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    pages: std.ArrayList(liborca.MetadataIssuePage) = .empty,
    groups: std.ArrayList(Group) = .empty,
    releases: std.ArrayList(Release) = .empty,
    status: ?liborca.MetadataIssueStatus = null,
    failed: bool = false,

    fn run(self: *ListLoader) void {
        self.load() catch {
            self.failed = true;
        };
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn knows(self: *const ListLoader, release_id: i64) bool {
        for (self.releases.items) |release| if (release.id == release_id) return true;
        return false;
    }

    fn load(self: *ListLoader) !void {
        self.status = try self.runtime.libraryMetadataIssueStatus(self.library);
        var offset: u32 = 0;
        while (self.groups.items.len < max_groups) {
            const page = try self.runtime.libraryMetadataIssuePage(self.library, self.allocator, null, app.page_size, offset);
            self.pages.append(self.allocator, page) catch |err| {
                page.deinit();
                return err;
            };
            for (page.items) |item| {
                if (self.groups.items.len == max_groups) break;
                try self.groups.append(self.allocator, item);
                if (!self.knows(item.release_id)) try self.releases.append(self.allocator, .{ .id = item.release_id });
            }
            if (page.items.len < app.page_size) break;
            offset += app.page_size;
        }
        for (self.releases.items) |*release| {
            const summary = (self.runtime.libraryRelease(self.library, release.id) catch null) orelse continue;
            defer summary.deinit(self.runtime.allocator);
            if (summary.release_date) |date| if (date.len >= 4) {
                release.year = date[0..4].*;
            };
        }
    }

    fn destroy(self: *ListLoader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        for (self.pages.items) |page| page.deinit();
        self.pages.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.releases.deinit(self.allocator);
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

const StatusLoader = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    status: ?liborca.MetadataIssueStatus = null,

    fn run(self: *StatusLoader) void {
        self.status = self.runtime.libraryMetadataIssueStatus(self.library) catch null;
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn destroy(self: *StatusLoader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

const ActionKind = enum { apply, skip };

const Action = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    arena: std.heap.ArenaAllocator,
    kind: ActionKind,
    applications: []Application = &.{},
    skips: []i64 = &.{},
    changed: u64 = 0,
    skipped: usize = 0,
    failure: ?anyerror = null,

    fn run(self: *Action) void {
        switch (self.kind) {
            .apply => if (self.runtime.libraryApplyMetadataIssues(self.library, self.applications)) |changed| {
                self.changed = changed;
            } else |err| {
                self.failure = err;
            },
            .skip => for (self.skips) |group_id| {
                self.runtime.librarySkipMetadataIssue(self.library, group_id) catch |err| {
                    self.failure = err;
                    break;
                };
                self.skipped += 1;
            },
        }
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn destroy(self: *Action, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        self.arena.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

const Check = struct {
    track_id: i64,
    button: *gtk.CheckButton,
};

const Card = struct {
    group: usize,
    radios: []*gtk.CheckButton = &.{},
    rows: []*gtk.Widget = &.{},
    custom: ?*gtk.CheckButton = null,
    custom_row: ?*gtk.Widget = null,
    entry: ?*gtk.Editable = null,
    checks: []Check = &.{},
};

pub const State = struct {
    built: bool = false,
    stale: bool = true,
    out_of_date: bool = false,
    summary: ?*gtk.Label = null,
    notice: ?*gtk.Widget = null,
    notice_text: ?*gtk.Label = null,
    check: ?*gtk.Widget = null,
    list: ?*gtk.Box = null,
    empty: ?*gtk.Label = null,
    detail: ?*gtk.Widget = null,
    cover: ?*gtk.Widget = null,
    heading: ?*gtk.Label = null,
    subtitle: ?*gtk.Label = null,
    cards_box: ?*gtk.Box = null,
    apply_button: ?*gtk.Widget = null,
    skip_button: ?*gtk.Widget = null,
    pages: std.ArrayList(liborca.MetadataIssuePage) = .empty,
    groups: std.ArrayList(Group) = .empty,
    releases: std.ArrayList(Release) = .empty,
    status: ?liborca.MetadataIssueStatus = null,
    selected: ?i64 = null,
    selected_index: usize = 0,
    cards: []Card = &.{},
    cards_arena: ?std.heap.ArenaAllocator = null,
    list_loader: ?*ListLoader = null,
    list_again: bool = false,
    status_loader: ?*StatusLoader = null,
    status_again: bool = false,
    action: ?*Action = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.pages.items) |page| page.deinit();
        self.pages.deinit(allocator);
        self.groups.deinit(allocator);
        self.releases.deinit(allocator);
        self.cards = &.{};
        if (self.cards_arena) |*arena| arena.deinit();
        self.cards_arena = null;
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
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
    return widget;
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

fn setClass(widget: *gtk.Widget, class: [*:0]const u8, on: bool) void {
    if (on) gtk.gtk_widget_add_css_class(widget, class) else gtk.gtk_widget_remove_css_class(widget, class);
}

fn plural(count: u64, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

pub fn build(self: *App) *gtk.Widget {
    buildTrail(self);

    const title = page_ui.title("Metadata Issues");
    gtk.gtk_widget_add_css_class(title.widget, "metadata-issues-title");
    const meta = gtk.cast(gtk.Widget, title.meta);
    gtk.gtk_widget_remove_css_class(meta, "numeric");
    gtk.gtk_widget_add_css_class(meta, "metadata-issues-summary");
    self.metadata_issues.summary = title.meta;

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 14);
    gtk.gtk_widget_add_css_class(list, "metadata-issues-list");
    self.metadata_issues.list = gtk.cast(gtk.Box, list);
    const empty = wrapped("", "metadata-issues-empty");
    gtk.gtk_widget_set_visible(empty, gtk.false_);
    self.metadata_issues.empty = gtk.cast(gtk.Label, empty);
    const list_column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(list_column, &.{ list, empty });
    const list_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, list_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, list_scroller), list_column);
    gtk.gtk_widget_set_size_request(list_scroller, 270, -1);
    gtk.gtk_widget_set_hexpand(list_scroller, gtk.false_);
    gtk.gtk_widget_add_css_class(list_scroller, "metadata-issues-albums");
    _ = gtk.signalConnect(list_scroller, "destroy", gtk.callback(scrollerDestroyed), self);

    const detail_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, detail_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, detail_scroller), buildDetail(self));
    gtk.gtk_widget_set_hexpand(detail_scroller, gtk.true_);

    const split = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(split, "metadata-issues-split");
    gtk.gtk_widget_set_vexpand(split, gtk.true_);
    append(split, &.{ list_scroller, detail_scroller });

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "metadata-issues-page");
    append(column, &.{ title.widget, buildNotice(self), split });
    self.metadata_issues.built = true;
    return column;
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Library Health");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(healthClicked), self);
    const chevron = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(chevron, "breadcrumb-separator");
    const current = gtk.gtk_label_new("Metadata Issues");
    gtk.gtk_widget_add_css_class(current, "breadcrumb-current");
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, chevron, current });
    page_ui.addTrail(self, .metadata_issues, crumbs);
}

fn healthClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .health);
}

fn buildNotice(self: *App) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("orca-info-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 15);
    const text = label("", "metadata-issues-notice-text");
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    self.metadata_issues.notice_text = gtk.cast(gtk.Label, text);
    const check = button("Check Metadata", "btn-secondary", gtk.callback(checkClicked), self);
    gtk.gtk_widget_add_css_class(check, "metadata-issues-check");
    gtk.gtk_widget_set_tooltip_text(check, "Look for tracks of one album that disagree, without changing anything");
    self.metadata_issues.check = check;
    const notice = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(notice, "metadata-issues-notice");
    append(notice, &.{ icon, text, check });
    gtk.gtk_widget_set_visible(notice, gtk.false_);
    self.metadata_issues.notice = notice;
    return notice;
}

fn buildDetail(self: *App) *gtk.Widget {
    const issues = &self.metadata_issues;
    const cover = art.newCover(self, art.initialsPlaceholder(), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "metadata-issues-cover");
    gtk.gtk_widget_set_valign(cover, gtk.ALIGN_CENTER);
    issues.cover = cover;
    const heading = label("", "metadata-issues-heading");
    issues.heading = gtk.cast(gtk.Label, heading);
    const subtitle = label("", "metadata-issues-subtitle");
    issues.subtitle = gtk.cast(gtk.Label, subtitle);
    const names = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 3);
    gtk.gtk_widget_set_valign(names, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(names, gtk.true_);
    append(names, &.{ heading, subtitle });
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    append(header, &.{ cover, names });

    const cards = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    issues.cards_box = gtk.cast(gtk.Box, cards);

    const apply = button("Apply to Orca", "btn-primary", gtk.callback(applyClicked), self);
    gtk.gtk_widget_add_css_class(apply, "metadata-issues-apply");
    gtk.gtk_widget_set_tooltip_text(apply, "Give the chosen values to the album's tracks in Orca's database");
    issues.apply_button = apply;
    const skip = button("Skip Album", "btn-secondary", gtk.callback(skipClicked), self);
    gtk.gtk_widget_add_css_class(skip, "metadata-issues-skip");
    gtk.gtk_widget_set_tooltip_text(skip, "Hide this album's issues until its values change");
    issues.skip_button = skip;
    const info_icon = gtk.gtk_image_new_from_icon_name("orca-info-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, info_icon), 15);
    const note_text = label("Files stay untouched until you choose Write to Files", "metadata-issues-note-text");
    const note = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(note, "metadata-issues-note");
    gtk.gtk_widget_set_hexpand(note, gtk.true_);
    gtk.gtk_widget_set_halign(note, gtk.ALIGN_END);
    append(note, &.{ info_icon, note_text });
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(actions, "metadata-issues-actions");
    append(actions, &.{ apply, skip, note });

    const detail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 18);
    gtk.gtk_widget_add_css_class(detail, "metadata-issues-detail");
    append(detail, &.{ header, cards, actions });
    gtk.gtk_widget_set_visible(detail, gtk.false_);
    issues.detail = detail;
    return detail;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issues = &state(data).metadata_issues;
    issues.built = false;
    issues.list = null;
    issues.empty = null;
    issues.detail = null;
    issues.cards_box = null;
    issues.cards = &.{};
}

pub fn shown(self: *App) void {
    reload(self);
}

pub fn invalidate(self: *App) void {
    self.metadata_issues.stale = true;
    if (self.current_page == .metadata_issues) reload(self);
}

pub fn openCount(self: *const App) u64 {
    const status = self.metadata_issues.status orelse return 0;
    return status.open;
}

pub fn needsCheck(self: *const App) bool {
    const status = self.metadata_issues.status orelse return false;
    return status.last_pass_at == null or status.stale or self.metadata_issues.out_of_date;
}

pub fn mostlyText(self: *const App, buffer: []u8) [:0]const u8 {
    const status = self.metadata_issues.status orelse return "";
    if (status.last_pass_at == null) return "Not checked yet";
    if (status.open == 0) return if (status.stale) "The library changed since the last check" else "";
    var first: ?Category = null;
    var second: ?Category = null;
    for (std.enums.values(Category)) |category| {
        const count = status.by_category.get(category);
        if (count == 0) continue;
        if (first == null or count > status.by_category.get(first.?)) {
            second = first;
            first = category;
        } else if (second == null or count > status.by_category.get(second.?)) {
            second = category;
        }
    }
    const top = first orelse return "";
    if (second) |next| return strings.format(buffer, "Mostly {s} and {s}", .{ categoryWords(top), categoryWords(next) });
    return strings.format(buffer, "All {s}", .{categoryWords(top)});
}

fn categoryWords(category: Category) []const u8 {
    return switch (category) {
        .album_artist => "album artist",
        .dates => "dates",
        .track_numbering => "track numbers",
        .genre_variants => "genre spellings",
        .musicbrainz_differs => "MusicBrainz differences",
    };
}

fn categoryHeading(category: Category) [*:0]const u8 {
    return switch (category) {
        .album_artist => "ALBUM ARTIST",
        .dates => "DATES",
        .track_numbering => "TRACK NUMBERING",
        .genre_variants => "GENRES & CAPITALIZATION",
        .musicbrainz_differs => "MUSICBRAINZ DIFFERS",
    };
}

pub fn refreshStatus(self: *App) void {
    const issues = &self.metadata_issues;
    const library = self.library orelse return;
    if (issues.status_loader != null) {
        issues.status_again = true;
        return;
    }
    const loader = self.allocator.create(StatusLoader) catch return;
    loader.* = .{ .runtime = self.runtime, .library = library, .waker = self.waker() };
    loader.thread = std.Thread.spawn(.{}, StatusLoader.run, .{loader}) catch {
        loader.destroy(self.allocator);
        return;
    };
    issues.status_loader = loader;
}

fn reload(self: *App) void {
    const issues = &self.metadata_issues;
    if (!issues.built) return;
    issues.stale = false;
    const library = self.library orelse return;
    if (issues.list_loader != null) {
        issues.list_again = true;
        return;
    }
    const loader = self.allocator.create(ListLoader) catch return;
    loader.* = .{ .runtime = self.runtime, .library = library, .allocator = self.allocator, .waker = self.waker() };
    loader.thread = std.Thread.spawn(.{}, ListLoader.run, .{loader}) catch {
        loader.destroy(self.allocator);
        return self.toast("Could not read the metadata issues");
    };
    issues.list_loader = loader;
}

pub fn tick(self: *App) void {
    tickStatus(self);
    tickList(self);
    tickAction(self);
}

pub fn shutdown(self: *App) void {
    const issues = &self.metadata_issues;
    if (issues.list_loader) |loader| loader.destroy(self.allocator);
    issues.list_loader = null;
    if (issues.status_loader) |loader| loader.destroy(self.allocator);
    issues.status_loader = null;
    if (issues.action) |action| action.destroy(self.allocator);
    issues.action = null;
}

fn setStatus(self: *App, status: liborca.MetadataIssueStatus) void {
    const before = self.metadata_issues.status;
    self.metadata_issues.status = status;
    const changed = before == null or before.?.open != status.open or before.?.stale != status.stale or
        before.?.last_pass_at != status.last_pass_at;
    if (changed) health.showMismatched(self);
}

fn tickStatus(self: *App) void {
    const issues = &self.metadata_issues;
    const loader = issues.status_loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    issues.status_loader = null;
    const status = loader.status;
    loader.destroy(self.allocator);
    if (status) |value| setStatus(self, value);
    if (issues.status_again) {
        issues.status_again = false;
        refreshStatus(self);
    }
}

fn tickList(self: *App) void {
    const issues = &self.metadata_issues;
    const loader = issues.list_loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    issues.list_loader = null;
    defer loader.destroy(self.allocator);
    if (loader.failed) {
        self.toast("Could not read the metadata issues");
    } else {
        clearCards(self);
        for (issues.pages.items) |page| page.deinit();
        issues.pages.deinit(self.allocator);
        issues.groups.deinit(self.allocator);
        issues.releases.deinit(self.allocator);
        issues.pages = loader.pages;
        issues.groups = loader.groups;
        issues.releases = loader.releases;
        loader.pages = .empty;
        loader.groups = .empty;
        loader.releases = .empty;
        if (loader.status) |status| setStatus(self, status);
        showList(self);
    }
    if (issues.list_again) {
        issues.list_again = false;
        reload(self);
    }
}

fn groupIndex(self: *App, group_id: ?i64) ?usize {
    const wanted = group_id orelse return null;
    for (self.metadata_issues.groups.items, 0..) |group, index| if (group.id == wanted) return index;
    return null;
}

fn releaseYear(self: *App, release_id: i64) ?[4]u8 {
    for (self.metadata_issues.releases.items) |release| if (release.id == release_id) return release.year;
    return null;
}

fn summaryText(self: *App, buffer: []u8) [:0]const u8 {
    const status = self.metadata_issues.status orelse return "";
    if (status.last_pass_at == null) return settled;
    if (status.open == 0) return "No inconsistencies. " ++ settled;
    return strings.format(buffer, "{f} {s} across {f} {s}. " ++ settled, .{
        strings.grouped(status.open),
        plural(status.open, "inconsistency", "inconsistencies"),
        strings.grouped(status.releases),
        plural(status.releases, "album", "albums"),
    });
}

fn showNotice(self: *App) void {
    const issues = &self.metadata_issues;
    const notice = issues.notice orelse return;
    const status = issues.status orelse return gtk.gtk_widget_set_visible(notice, gtk.false_);
    const running = jobs.active(self, .consistency);
    const never = status.last_pass_at == null;
    const visible = running or never or status.stale or issues.out_of_date;
    gtk.gtk_widget_set_visible(notice, @intFromBool(visible));
    if (issues.notice_text) |text| gtk.gtk_label_set_text(text, if (running)
        "Checking the library’s metadata…"
    else if (never)
        "Orca has not checked this library’s metadata yet. Checking reads the library and changes nothing."
    else if (issues.out_of_date)
        "An album changed since its metadata was checked. Check again to bring its issues up to date."
    else
        "The library changed since its metadata was last checked.");
    if (issues.check) |check| {
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, check), if (running) "Checking…" else if (never) "Check Metadata" else "Check Again");
        gtk.gtk_widget_set_sensitive(check, @intFromBool(!running));
    }
}

fn checkClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    jobs.startConsistency(self);
    showNotice(self);
}

pub fn checked(self: *App, succeeded: bool) void {
    if (succeeded) self.metadata_issues.out_of_date = false;
    invalidate(self);
    refreshStatus(self);
    showNotice(self);
}

fn showList(self: *App) void {
    const issues = &self.metadata_issues;
    if (!issues.built) return;
    var buffer: [256]u8 = undefined;
    if (issues.summary) |summary| gtk.gtk_label_set_text(summary, summaryText(self, &buffer).ptr);
    showNotice(self);
    const list = issues.list orelse return;
    clear(list);
    const groups = issues.groups.items;
    var start: usize = 0;
    while (start < groups.len) {
        const category = groups[start].category;
        var end = start;
        while (end < groups.len and groups[end].category == category) end += 1;
        const count = if (issues.status) |status| status.by_category.get(category) else end - start;
        gtk.gtk_box_append(list, section(self, category, @max(count, end - start), start, end));
        start = end;
    }
    if (issues.empty) |empty| {
        const never = if (issues.status) |status| status.last_pass_at == null else false;
        gtk.gtk_label_set_text(empty, if (never)
            "Check the library’s metadata to find albums whose tracks disagree."
        else
            "Every album's tracks agree.");
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, empty), @intFromBool(groups.len == 0));
    }
    if (groupIndex(self, issues.selected) == null) {
        issues.selected = if (groups.len == 0) null else groups[@min(issues.selected_index, groups.len - 1)].id;
    }
    showSelected(self, true);
}

fn section(self: *App, category: Category, count: u64, start: usize, end: usize) *gtk.Widget {
    var buffer: [24]u8 = undefined;
    const name = label(categoryHeading(category), "metadata-issues-section-name");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    const number = label(strings.format(&buffer, "{f}", .{strings.grouped(count)}).ptr, "metadata-issues-section-name");
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, number), gtk.ELLIPSIZE_NONE);
    const heading = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(heading, "metadata-issues-section");
    append(heading, &.{ name, number });
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), heading);
    for (start..end) |index| gtk.gtk_box_append(gtk.cast(gtk.Box, box), row(self, index));
    return box;
}

fn rowTitle(buffer: []u8, group: Group) [:0]const u8 {
    if (group.category == .genre_variants and group.options.len >= 2)
        return strings.format(buffer, "{s} / {s}", .{ group.options[0].value, group.options[1].value });
    return strings.terminated(buffer, if (group.title.len != 0) group.title else "Untitled album");
}

fn rowSubtitle(buffer: []u8, group: Group) [:0]const u8 {
    const differing: u64 = group.proposals.len;
    switch (group.category) {
        .album_artist => return strings.format(buffer, "{s}" ++ separator ++ "{d} {s} {s}", .{
            group.artist, differing, plural(differing, "track", "tracks"), plural(differing, "differs", "differ"),
        }),
        .dates => {
            if (group.missing != 0) return strings.format(buffer, "{s}" ++ separator ++ "year missing", .{group.artist});
            if (group.options.len >= 2)
                return strings.format(buffer, "{s}" ++ separator ++ "{s} vs {s}", .{ group.artist, group.options[1].value, group.options[0].value });
            return strings.format(buffer, "{s}" ++ separator ++ "date Orca cannot read", .{group.artist});
        },
        .track_numbering => {
            if (group.gap) |gap| return strings.format(buffer, "{s}" ++ separator ++ "gap at track {d}", .{ group.artist, gap });
            return strings.format(buffer, "{s}" ++ separator ++ "{d} {s} without a number", .{ group.artist, differing, plural(differing, "track", "tracks") });
        },
        .genre_variants => {
            var tracks: u64 = 0;
            for (group.options) |option| tracks += option.tracks;
            return strings.format(buffer, "{d} spellings across {d} {s}", .{ group.options.len, tracks, plural(tracks, "track", "tracks") });
        },
        .musicbrainz_differs => {
            if (group.case_only) return strings.format(buffer, "{s}" ++ separator ++ "title case", .{group.artist});
            return strings.format(buffer, "{s}" ++ separator ++ "{s} differs", .{ group.artist, fieldWords(group.field) });
        },
    }
}

fn fieldWords(field: liborca.IssueField) []const u8 {
    return switch (field) {
        .album => "title",
        .album_artist => "album artist",
        .date => "date",
        .track_number => "track number",
        .genre => "genre",
    };
}

fn row(self: *App, index: usize) *gtk.Widget {
    const group = self.metadata_issues.groups.items[index];
    var title_buffer: [512]u8 = undefined;
    var subtitle_buffer: [512]u8 = undefined;
    const title = label(rowTitle(&title_buffer, group).ptr, "metadata-issues-row-title");
    const subtitle = label(rowSubtitle(&subtitle_buffer, group).ptr, "metadata-issues-row-subtitle");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    append(text, &.{ title, subtitle });
    const widget = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, widget), text);
    gtk.gtk_widget_add_css_class(widget, "flat");
    gtk.gtk_widget_add_css_class(widget, "metadata-issues-row");
    gtk.g_object_set_data(widget, "orca-issue", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(widget, "clicked", gtk.callback(rowClicked), self);
    return widget;
}

fn rowClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tagged = gtk.g_object_get_data(widget.?, "orca-issue") orelse return;
    const index = @intFromPtr(tagged) - 1;
    const groups = self.metadata_issues.groups.items;
    if (index >= groups.len) return;
    const before = self.metadata_issues.selected;
    const same_release = if (groupIndex(self, before)) |previous| groups[previous].release_id == groups[index].release_id else false;
    self.metadata_issues.selected = groups[index].id;
    self.metadata_issues.selected_index = index;
    showSelected(self, !same_release);
}

fn syncRows(self: *App) void {
    const issues = &self.metadata_issues;
    const list = issues.list orelse return;
    var section_widget = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list));
    while (section_widget) |box| : (section_widget = gtk.gtk_widget_get_next_sibling(box)) {
        var child = gtk.gtk_widget_get_first_child(box);
        while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
            const tagged = gtk.g_object_get_data(widget, "orca-issue") orelse continue;
            const index = @intFromPtr(tagged) - 1;
            const selected = index < issues.groups.items.len and issues.selected != null and issues.groups.items[index].id == issues.selected.?;
            setClass(widget, "selected", selected);
        }
    }
}

fn clearCards(self: *App) void {
    const issues = &self.metadata_issues;
    if (issues.cards_box) |box| clear(box);
    issues.cards = &.{};
    if (issues.cards_arena) |*arena| _ = arena.reset(.retain_capacity);
}

fn showSelected(self: *App, rebuild: bool) void {
    const issues = &self.metadata_issues;
    syncRows(self);
    const detail = issues.detail orelse return;
    const index = groupIndex(self, issues.selected) orelse {
        clearCards(self);
        gtk.gtk_widget_set_visible(detail, gtk.false_);
        return;
    };
    issues.selected_index = index;
    gtk.gtk_widget_set_visible(detail, gtk.true_);
    showBusy(self);
    if (!rebuild and issues.cards.len != 0) return;
    const group = issues.groups.items[index];
    var buffer: [512]u8 = undefined;
    if (issues.heading) |heading| gtk.gtk_label_set_text(heading, strings.terminated(&buffer, if (group.title.len != 0) group.title else "Untitled album").ptr);
    if (issues.subtitle) |subtitle| gtk.gtk_label_set_text(subtitle, headerText(&buffer, group, releaseYear(self, group.release_id)).ptr);
    if (issues.cover) |cover| {
        art.setInitials(cover, group.title);
        art.show(self, cover, art.Key.release(group.release_id, art.Size.atLeast(cover_pixels)));
    }
    clearCards(self);
    buildCards(self, group.release_id) catch self.toast("Could not show the album's issues");
}

fn headerText(buffer: []u8, group: Group, year: ?[4]u8) [:0]const u8 {
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    if (group.artist.len != 0) writer.print("{s}" ++ separator, .{group.artist}) catch {};
    if (year) |known| writer.print("{s}" ++ separator, .{&known}) catch {};
    writer.print("{d} {s}", .{ group.track_count, plural(group.track_count, "track", "tracks") }) catch {};
    const written = writer.buffered();
    buffer[written.len] = 0;
    return buffer[0..written.len :0];
}

fn showBusy(self: *App) void {
    const issues = &self.metadata_issues;
    const idle = @intFromBool(issues.action == null);
    if (issues.apply_button) |widget| gtk.gtk_widget_set_sensitive(widget, idle);
    if (issues.skip_button) |widget| gtk.gtk_widget_set_sensitive(widget, idle);
}

fn isTable(group: Group) bool {
    return group.category == .track_numbering or group.missing != 0 or group.precision or group.options.len < 2;
}

fn cardTitle(group: Group) [*:0]const u8 {
    return switch (group.category) {
        .album_artist => "Album artist differs within the album",
        .dates => if (group.missing != 0)
            "Date missing on some tracks"
        else if (group.precision)
            "Date precision differs"
        else if (group.options.len < 2)
            "Date Orca cannot read"
        else
            "Dates differ within the album",
        .track_numbering => "Track numbers repeat or are missing",
        .genre_variants => "Genre spelled more than one way",
        .musicbrainz_differs => switch (group.field) {
            .album => if (group.case_only) "Album title differs from MusicBrainz in capitalization" else "Album title differs from MusicBrainz",
            .album_artist => "Album artist differs from MusicBrainz",
            .date => "Date differs from MusicBrainz",
            .track_number, .genre => "Differs from MusicBrainz",
        },
    };
}

fn cardDescription(group: Group) ?[*:0]const u8 {
    return switch (group.category) {
        .album_artist => "When album artist varies, Orca may split one album into two. Choose the value every track should use.",
        .dates => if (group.missing != 0)
            "Some tracks state no date. Orca proposes the date the other tracks state."
        else if (group.precision)
            null
        else if (group.options.len < 2)
            "Orca reads dates written as YYYY, YYYY-MM or YYYY-MM-DD. The proposal keeps the year these dates state."
        else
            "Choose the date every track should use.",
        .track_numbering => "Tracks that repeat a number or state none take the next free numbers.",
        .genre_variants => "Each spelling is listed apart in Genres. Choose the spelling every track should use.",
        .musicbrainz_differs => "The accepted MusicBrainz release says otherwise. Choose the value every track should use.",
    };
}

fn countText(buffer: []u8, group: Group) [:0]const u8 {
    const differing: u64 = group.proposals.len;
    if (isTable(group)) return strings.format(buffer, "{d} of {d} tracks", .{ differing, group.track_count });
    return strings.format(buffer, "{d} of {d} tracks {s}", .{ differing, group.track_count, plural(differing, "differs", "differ") });
}

fn buildCards(self: *App, release_id: i64) !void {
    const issues = &self.metadata_issues;
    const box = issues.cards_box orelse return;
    if (issues.cards_arena == null) issues.cards_arena = .init(self.allocator);
    const arena = issues.cards_arena.?.allocator();
    var cards: std.ArrayList(Card) = .empty;
    for (issues.groups.items, 0..) |group, index| {
        if (group.release_id != release_id) continue;
        var entry: Card = .{ .group = index };
        gtk.gtk_box_append(box, try card(self, arena, group, &entry));
        try cards.append(arena, entry);
    }
    issues.cards = cards.items;
    syncOptions(self);
}

fn card(self: *App, arena: std.mem.Allocator, group: Group, entry: *Card) !*gtk.Widget {
    var buffer: [128]u8 = undefined;
    const title = label(cardTitle(group), "metadata-issues-card-title");
    gtk.gtk_widget_set_hexpand(title, gtk.true_);
    gtk.gtk_widget_set_valign(title, gtk.ALIGN_BASELINE_FILL);
    const count = label(countText(&buffer, group).ptr, "metadata-issues-card-count");
    gtk.gtk_widget_set_valign(count, gtk.ALIGN_BASELINE_FILL);
    const top = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    append(top, &.{ title, count });
    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(widget, "metadata-issues-card");
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), top);
    if (cardDescription(group)) |text| gtk.gtk_box_append(gtk.cast(gtk.Box, widget), wrapped(text, "metadata-issues-card-text"));
    if (isTable(group)) {
        gtk.gtk_box_append(gtk.cast(gtk.Box, widget), try table(self, arena, group, entry));
    } else {
        gtk.gtk_box_append(gtk.cast(gtk.Box, widget), try options(self, arena, group, entry));
    }
    return widget;
}

fn options(self: *App, arena: std.mem.Allocator, group: Group, entry: *Card) !*gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
    const radios = try arena.alloc(*gtk.CheckButton, group.options.len);
    const rows = try arena.alloc(*gtk.Widget, group.options.len);
    var first: ?*gtk.CheckButton = null;
    var value_buffer: [512]u8 = undefined;
    for (group.options, radios, rows, 0..) |option, *radio, *option_row, index| {
        const check = gtk.gtk_check_button_new_with_label(strings.terminated(&value_buffer, option.value).ptr);
        gtk.gtk_widget_add_css_class(check, "metadata-issues-radio");
        gtk.gtk_widget_set_hexpand(check, gtk.true_);
        radio.* = gtk.cast(gtk.CheckButton, check);
        gtk.gtk_check_button_set_group(radio.*, first);
        if (first == null) first = radio.*;
        gtk.gtk_check_button_set_active(radio.*, @intFromBool(index == 0));
        _ = gtk.signalConnect(check, "toggled", gtk.callback(optionToggled), self);
        const support = label(strings.terminated(&value_buffer, option.support.slice()).ptr, "metadata-issues-support");
        gtk.gtk_widget_set_valign(support, gtk.ALIGN_CENTER);
        option_row.* = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
        gtk.gtk_widget_add_css_class(option_row.*, "metadata-issues-option");
        append(option_row.*, &.{ check, support });
        gtk.gtk_box_append(gtk.cast(gtk.Box, box), option_row.*);
    }
    entry.radios = radios;
    entry.rows = rows;
    if (group.field == .track_number) return box;

    const custom = gtk.gtk_check_button_new_with_label(null);
    gtk.gtk_widget_add_css_class(custom, "metadata-issues-radio");
    gtk.gtk_widget_set_valign(custom, gtk.ALIGN_CENTER);
    gtk.gtk_check_button_set_group(gtk.cast(gtk.CheckButton, custom), first);
    _ = gtk.signalConnect(custom, "toggled", gtk.callback(optionToggled), self);
    const text = gtk.gtk_entry_new();
    gtk.gtk_entry_set_placeholder_text(gtk.cast(gtk.Entry, text), "Custom value…");
    gtk.gtk_widget_add_css_class(text, "metadata-issues-custom");
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.g_object_set_data(text, "orca-radio", custom);
    _ = gtk.signalConnect(text, "changed", gtk.callback(customChanged), self);
    const custom_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_add_css_class(custom_row, "metadata-issues-option");
    append(custom_row, &.{ custom, text });
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), custom_row);
    entry.custom = gtk.cast(gtk.CheckButton, custom);
    entry.custom_row = custom_row;
    entry.entry = gtk.cast(gtk.Editable, text);
    return box;
}

fn optionToggled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    syncOptions(state(data));
}

fn customChanged(widget: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const radio = gtk.g_object_get_data(widget.?, "orca-radio") orelse return;
    const text = std.mem.span(gtk.gtk_editable_get_text(gtk.cast(gtk.Editable, widget.?)));
    if (text.len != 0) gtk.gtk_check_button_set_active(@ptrCast(@alignCast(radio)), gtk.true_);
}

fn active(radio: *gtk.CheckButton) bool {
    return gtk.gtk_check_button_get_active(radio) != 0;
}

fn syncOptions(self: *App) void {
    for (self.metadata_issues.cards) |entry| {
        for (entry.radios, entry.rows) |radio, option_row| setClass(option_row, "selected", active(radio));
        if (entry.custom) |custom| if (entry.custom_row) |custom_row| setClass(custom_row, "selected", active(custom));
    }
}

fn cell(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, "metadata-issues-cell");
    gtk.gtk_widget_add_css_class(widget, class);
    return widget;
}

fn table(self: *App, arena: std.mem.Allocator, group: Group, entry: *Card) !*gtk.Widget {
    _ = self;
    const widget = gtk.gtk_grid_new();
    const grid = gtk.cast(gtk.Grid, widget);
    gtk.gtk_widget_add_css_class(widget, "metadata-issues-table");
    const heads = [_][*:0]const u8{ "TRACK", "CURRENT", "PROPOSED", "APPLY" };
    for (heads, 0..) |text, column| {
        const head = label(text, "metadata-issues-head");
        if (column == 0) gtk.gtk_widget_set_hexpand(head, gtk.true_);
        if (column == 1 or column == 2) gtk.gtk_widget_set_size_request(head, value_width, -1);
        if (column == 3) gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, head), 1);
        gtk.gtk_grid_attach(grid, head, @intCast(column), 0, 1, 1);
    }
    const checks = try arena.alloc(Check, group.proposals.len);
    var buffer: [512]u8 = undefined;
    for (group.proposals, checks, 1..) |proposal, *check, line| {
        const at: c_int = @intCast(line);
        const title = cell(strings.terminated(&buffer, if (proposal.title.len != 0) proposal.title else "Untitled track").ptr, "metadata-issues-track");
        gtk.gtk_grid_attach(grid, title, 0, at, 1, 1);
        const current = cell(strings.terminated(&buffer, proposal.current orelse "—").ptr, "metadata-issues-current");
        if (proposal.current == null) gtk.gtk_widget_add_css_class(current, "none");
        gtk.gtk_grid_attach(grid, current, 1, at, 1, 1);
        gtk.gtk_grid_attach(grid, cell(strings.terminated(&buffer, proposal.proposed).ptr, "metadata-issues-proposed"), 2, at, 1, 1);
        const box = gtk.gtk_check_button_new_with_label(null);
        gtk.gtk_widget_add_css_class(box, "metadata-issues-check-box");
        gtk.gtk_check_button_set_active(gtk.cast(gtk.CheckButton, box), gtk.true_);
        gtk.gtk_widget_set_halign(box, gtk.ALIGN_END);
        gtk.gtk_widget_set_tooltip_text(box, "Apply to this track");
        const holder = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_add_css_class(holder, "metadata-issues-cell");
        gtk.gtk_widget_set_halign(box, gtk.ALIGN_END);
        gtk.gtk_widget_set_hexpand(box, gtk.true_);
        gtk.gtk_box_append(gtk.cast(gtk.Box, holder), box);
        gtk.gtk_grid_attach(grid, holder, 3, at, 1, 1);
        check.* = .{ .track_id = proposal.track_id, .button = gtk.cast(gtk.CheckButton, box) };
    }
    entry.checks = checks;
    return widget;
}

fn startAction(self: *App, kind: ActionKind) ?*Action {
    const library = self.library orelse return null;
    const action = self.allocator.create(Action) catch return null;
    action.* = .{
        .runtime = self.runtime,
        .library = library,
        .waker = self.waker(),
        .arena = .init(self.allocator),
        .kind = kind,
    };
    return action;
}

fn launch(self: *App, action: *Action) void {
    action.thread = std.Thread.spawn(.{}, Action.run, .{action}) catch {
        action.destroy(self.allocator);
        return self.toast("Could not change the album");
    };
    self.metadata_issues.action = action;
    showBusy(self);
}

const Gathered = union(enum) { ok: []Application, empty_custom, nothing };

fn gather(self: *App, arena: std.mem.Allocator) !Gathered {
    const issues = &self.metadata_issues;
    var applications: std.ArrayList(Application) = .empty;
    for (issues.cards) |entry| {
        const group = issues.groups.items[entry.group];
        if (entry.checks.len != 0) {
            if (group.options.len == 0) continue;
            var tracks: std.ArrayList(i64) = .empty;
            for (entry.checks) |check| if (active(check.button)) try tracks.append(arena, check.track_id);
            if (tracks.items.len == 0) continue;
            try applications.append(arena, .{ .group_id = group.id, .choice = .{ .option = group.options[0].id }, .tracks = tracks.items });
            continue;
        }
        const choice: liborca.MetadataIssueChoice = for (entry.radios, 0..) |radio, index| {
            if (active(radio)) break .{ .option = group.options[index].id };
        } else custom: {
            const custom = entry.custom orelse continue;
            if (!active(custom)) continue;
            const text = std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(entry.entry.?)), " \t\r\n");
            if (text.len == 0) return .empty_custom;
            break :custom .{ .custom = try arena.dupe(u8, text) };
        };
        try applications.append(arena, .{ .group_id = group.id, .choice = choice });
    }
    if (applications.items.len == 0) return .nothing;
    return .{ .ok = applications.items };
}

fn applyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.metadata_issues.action != null or self.metadata_issues.cards.len == 0) return;
    const action = startAction(self, .apply) orelse return;
    const gathered = gather(self, action.arena.allocator()) catch {
        action.destroy(self.allocator);
        return self.toast("Could not change the album");
    };
    switch (gathered) {
        .ok => |applications| action.applications = applications,
        .empty_custom => {
            action.destroy(self.allocator);
            return self.toast("Type a custom value, or choose one of the values");
        },
        .nothing => {
            action.destroy(self.allocator);
            return self.toast("Tick at least one track to apply");
        },
    }
    launch(self, action);
}

fn skipClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const issues = &self.metadata_issues;
    if (issues.action != null or issues.cards.len == 0) return;
    const action = startAction(self, .skip) orelse return;
    const skips = action.arena.allocator().alloc(i64, issues.cards.len) catch {
        action.destroy(self.allocator);
        return;
    };
    for (issues.cards, skips) |entry, *group_id| group_id.* = issues.groups.items[entry.group].id;
    action.skips = skips;
    launch(self, action);
}

fn failureText(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.IssueOutOfDate => "The album changed since its metadata was checked; check again first",
        error.IssueNotOpen, error.IssueNotFound => "These issues were already resolved",
        error.InvalidEditValue => "Dates take the form YYYY, YYYY-MM or YYYY-MM-DD, and a value cannot be empty",
        error.GenreDoesNotMatchIssue => "A custom genre must be a spelling of the same genre",
        error.CustomValueNotAllowed => "Track numbers cannot take a custom value",
        else => "Could not change the album",
    };
}

fn tickAction(self: *App) void {
    const issues = &self.metadata_issues;
    const action = issues.action orelse return;
    if (!action.finished.load(.acquire)) return;
    issues.action = null;
    defer action.destroy(self.allocator);
    showBusy(self);
    if (action.failure) |err| {
        if (err == error.IssueOutOfDate) {
            issues.out_of_date = true;
            showNotice(self);
        }
        self.toast(failureText(err));
        if (action.kind == .skip and action.skipped != 0) reload(self);
        if (err == error.IssueNotOpen or err == error.IssueNotFound) reload(self);
        return;
    }
    var buffer: [96]u8 = undefined;
    switch (action.kind) {
        .apply => {
            self.toast(if (action.changed == 0)
                "Applied; every track already had that value"
            else
                strings.format(&buffer, "Updated {f} {s} in Orca", .{ strings.grouped(action.changed), plural(action.changed, "track", "tracks") }));
            jobs.reloadLibraryViews(self);
        },
        .skip => {
            self.toast("Skipped the album until its values change");
            health.reload(self);
        },
    }
    issues.selected = null;
    reload(self);
}
