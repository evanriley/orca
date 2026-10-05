//! The Match Review page: one album beside its best MusicBrainz release,
//! field by field and track by track, with the fields to take chosen one at
//! a time. liborca compares them on a loader thread and applies the chosen
//! set; this only lays them out.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const jobs = @import("jobs.zig");
const matches = @import("matches.zig");
const window = @import("window.zig");
const page_ui = @import("page.zig");

const App = app.App;
const Field = liborca.ReleaseField;

const separator = " · ";
const release_url = "https://musicbrainz.org/release/";
const cover_pixels: c_int = 72;
const window_size: u32 = 100;

pub const Entry = struct {
    release_id: i64,
    confidence: f32,
};

pub const Scope = struct {
    bucket: matches.Bucket = .needs_review,
    confident_at: f32 = 0.9,
    filter: matches.Filter = .{},
};

const Loader = struct {
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    waker: liborca.HostWaker,
    scope: Scope,
    generation: u32,
    index: usize,
    release_id: ?i64,
    windowed: bool = false,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    window: ?liborca.ReleaseMatchPage = null,
    window_offset: usize = 0,
    total: u64 = 0,
    diff: ?liborca.ReleaseMatchDiff = null,

    fn run(self: *Loader) void {
        if (self.release_id == null) {
            self.windowed = true;
            self.readWindow();
        }
        if (self.release_id) |release_id| {
            self.diff = self.runtime.libraryReleaseMatchDiff(self.library, std.heap.smp_allocator, release_id, null) catch null;
        }
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn readWindow(self: *Loader) void {
        const filter = self.scope.filter.text();
        const counts = self.runtime.libraryReleaseMatchCounts(self.library, self.scope.confident_at, filter) catch return;
        self.total = switch (self.scope.bucket) {
            .confident => counts.confident,
            .needs_review => counts.needs_review,
            .unmatched => counts.unmatched,
        };
        if (self.total == 0) return;
        self.index = @min(self.index, self.total - 1);
        self.window_offset = self.index / window_size * window_size;
        const offset = std.math.cast(u32, self.window_offset) orelse return;
        const page = self.runtime.libraryReleaseMatchPage(self.library, std.heap.smp_allocator, self.scope.bucket, self.scope.confident_at, filter, window_size, offset) catch return;
        self.window = page;
        if (page.items.len == 0) return;
        self.index = @min(self.index, self.window_offset + page.items.len - 1);
        self.release_id = page.items[self.index - self.window_offset].release_id;
    }

    fn destroy(self: *Loader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.window) |*page| page.deinit();
        if (self.diff) |*diff| diff.deinit();
        allocator.destroy(self);
    }
};

pub const State = struct {
    built: bool = false,
    scope: Scope = .{},
    entries: std.ArrayList(Entry) = .empty,
    window_offset: usize = 0,
    total: u64 = 0,
    index: usize = 0,
    diff: ?liborca.ReleaseMatchDiff = null,
    loader: ?*Loader = null,
    stale: bool = false,
    generation: u32 = 0,
    window_stale: bool = false,
    skip_release: ?i64 = null,
    checks: std.EnumArray(Field, ?*gtk.Widget) = .initFill(null),
    rows: std.EnumArray(Field, ?*gtk.Widget) = .initFill(null),
    cover: ?*gtk.Widget = null,
    title: ?*gtk.Label = null,
    summary: ?*gtk.Label = null,
    link: ?*gtk.Widget = null,
    crumb: ?*gtk.Label = null,
    position: ?*gtk.Label = null,
    previous: ?*gtk.Widget = null,
    next: ?*gtk.Widget = null,
    apply: ?*gtk.Widget = null,
    not_this: ?*gtk.Widget = null,
    search: ?*gtk.Widget = null,
    fields: ?*gtk.Box = null,
    tracks: ?*gtk.Box = null,
    tracks_title: ?*gtk.Label = null,
    content: ?*gtk.Widget = null,
    message: ?*gtk.Label = null,
    scroller: ?*gtk.ScrolledWindow = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.diff) |*diff| diff.deinit();
        self.diff = null;
        self.entries.deinit(allocator);
        self.entries = .empty;
    }
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn current(self: *App) ?Entry {
    const review = &self.match_review;
    if (review.window_stale or review.index < review.window_offset) return null;
    const at = review.index - review.window_offset;
    if (at >= review.entries.items.len) return null;
    return review.entries.items[at];
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    return widget;
}

fn cell(text: [*:0]const u8, class: [*:0]const u8, width: c_int) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, widget), 1);
    if (width > 0) gtk.gtk_widget_set_size_request(widget, width, -1) else gtk.gtk_widget_set_hexpand(widget, gtk.true_);
    return widget;
}

fn append(box: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

fn fieldName(field: Field) [*:0]const u8 {
    return switch (field) {
        .album => "Album",
        .album_artist => "Album artist",
        .release_date => "Release date",
        .release_type => "Release type",
        .release_id => "Release ID",
        .genre => "Genre",
        .artwork => "Artwork",
        .track_titles => "Track titles",
    };
}

fn applicable(field: Field) bool {
    return switch (field) {
        .release_type, .genre, .artwork => false,
        else => true,
    };
}

fn checkedByDefault(diff: liborca.ReleaseFieldDiff) bool {
    return diff.differs and switch (diff.field) {
        .album, .album_artist, .release_date, .release_id => true,
        else => false,
    };
}

fn artworkText(buffer: []u8, text: []const u8, size: ?liborca.ArtworkSize) [:0]const u8 {
    if (text.len == 0) return strings.terminated(buffer, "—");
    const source = text[0 .. std.mem.indexOf(u8, text, separator) orelse text.len];
    const name = if (std.mem.eql(u8, source, "Cover Art Archive") or std.mem.eql(u8, source, "fetched")) "Cover Art Archive" else "Local";
    const measured = size orelse return strings.format(buffer, "{s}" ++ separator ++ "—", .{name});
    return strings.format(buffer, "{s}" ++ separator ++ "{d} × {d}", .{ name, measured.width, measured.height });
}

fn titlesDiffer(diff: liborca.ReleaseMatchDiff) u32 {
    var count: u32 = 0;
    for (diff.tracks) |track| {
        if (track.candidate_title.len != 0 and !std.mem.eql(u8, track.local_title, track.candidate_title)) count += 1;
    }
    return count;
}

fn onlyCaseDiffers(diff: liborca.ReleaseMatchDiff) bool {
    for (diff.tracks) |track| {
        if (track.candidate_title.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(track.local_title, track.candidate_title)) return false;
    }
    return true;
}

fn localText(buffer: []u8, diff: liborca.ReleaseMatchDiff, each: liborca.ReleaseFieldDiff) [:0]const u8 {
    return switch (each.field) {
        .artwork => artworkText(buffer, each.local, diff.local_artwork_size),
        .release_id => if (each.local.len == 0)
            strings.terminated(buffer, "—")
        else if (std.mem.eql(u8, each.local, each.candidate))
            strings.terminated(buffer, "MusicBrainz release ID")
        else
            strings.format(buffer, "{s}…", .{each.local[0..@min(each.local.len, 8)]}),
        .track_titles => switch (titlesDiffer(diff)) {
            0 => strings.terminated(buffer, "All agree"),
            1 => strings.terminated(buffer, "1 differs"),
            else => |count| strings.format(buffer, "{d} differ", .{count}),
        },
        else => strings.terminated(buffer, if (each.local.len != 0) each.local else "—"),
    };
}

fn candidateText(buffer: []u8, diff: liborca.ReleaseMatchDiff, each: liborca.ReleaseFieldDiff) [:0]const u8 {
    return switch (each.field) {
        .artwork => artworkText(buffer, each.candidate, diff.candidate_artwork_size),
        .release_id => strings.terminated(buffer, if (each.candidate.len != 0) "MusicBrainz release ID" else "—"),
        .track_titles => strings.terminated(buffer, if (titlesDiffer(diff) == 0)
            "As released"
        else if (onlyCaseDiffers(diff))
            "Capitalized as released"
        else
            "As released"),
        else => strings.terminated(buffer, if (each.candidate.len != 0) each.candidate else "—"),
    };
}

fn checkedFields(self: *App) liborca.ReleaseFieldSet {
    var fields: liborca.ReleaseFieldSet = .empty;
    for (std.enums.values(Field)) |field| {
        const check = self.match_review.checks.get(field) orelse continue;
        if (!applicable(field)) continue;
        if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0) fields.insert(field);
    }
    return fields;
}

fn showChecked(self: *App) void {
    const review = &self.match_review;
    for (std.enums.values(Field)) |field| {
        const row = review.rows.get(field) orelse continue;
        const check = review.checks.get(field) orelse continue;
        if (gtk.gtk_check_button_get_active(gtk.cast(gtk.CheckButton, check)) != 0)
            gtk.gtk_widget_add_css_class(row, "checked")
        else
            gtk.gtk_widget_remove_css_class(row, "checked");
    }
    const count = checkedFields(self).count();
    const apply = review.apply orelse return;
    var buffer: [48]u8 = undefined;
    gtk.gtk_button_set_label(gtk.cast(gtk.Button, apply), if (count == 1)
        "Apply 1 Field to Orca"
    else
        strings.format(&buffer, "Apply {d} Fields to Orca", .{count}).ptr);
    gtk.gtk_widget_set_sensitive(apply, @intFromBool(count != 0 and review.diff != null));
}

fn checkToggled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    showChecked(state(data));
}

fn fieldRow(self: *App, diff: liborca.ReleaseMatchDiff, each: liborca.ReleaseFieldDiff) *gtk.Widget {
    const check = gtk.gtk_check_button_new_with_label(null);
    gtk.gtk_widget_add_css_class(check, "match-review-check");
    gtk.gtk_widget_set_size_request(check, 40, -1);
    gtk.gtk_widget_set_valign(check, gtk.ALIGN_CENTER);
    var name_buffer: [48]u8 = undefined;
    gtk.gtk_widget_set_tooltip_text(check, if (applicable(each.field))
        strings.format(&name_buffer, "Adopt {s}", .{std.mem.span(fieldName(each.field))}).ptr
    else
        "Orca compares this but does not take it from a release");
    if (applicable(each.field)) {
        gtk.gtk_check_button_set_active(gtk.cast(gtk.CheckButton, check), @intFromBool(checkedByDefault(each)));
    } else {
        gtk.gtk_widget_set_sensitive(check, gtk.false_);
    }
    _ = gtk.signalConnect(check, "toggled", gtk.callback(checkToggled), self);

    var buffer: [512]u8 = undefined;
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, "match-review-field");
    append(row, &.{
        check,
        cell(fieldName(each.field), "match-review-name", 118),
        cell(localText(&buffer, diff, each).ptr, "match-review-local", 175),
        cell(candidateText(&buffer, diff, each).ptr, "match-review-candidate", 0),
    });
    self.match_review.checks.set(each.field, check);
    self.match_review.rows.set(each.field, row);
    return row;
}

fn heading(texts: []const [*:0]const u8, widths: []const c_int, class: [*:0]const u8) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, class);
    for (texts, widths) |text, width| gtk.gtk_box_append(gtk.cast(gtk.Box, row), cell(text, "match-review-column", width));
    return row;
}

fn delta(buffer: []u8, delta_ms: ?i64) [:0]const u8 {
    const ms = delta_ms orelse return strings.terminated(buffer, "—");
    const seconds = @divFloor(ms + 500, 1000);
    if (seconds == 0) return strings.terminated(buffer, "0 s");
    const magnitude: u64 = @abs(seconds);
    return strings.format(buffer, "{s}{d} s", .{ if (seconds > 0) "+" else "−", magnitude });
}

fn trackRow(track: liborca.ReleaseTrackAlignment) *gtk.Widget {
    var buffer: [512]u8 = undefined;
    const differs = track.candidate_title.len != 0 and !std.mem.eql(u8, track.local_title, track.candidate_title);
    const number = cell(strings.format(&buffer, "{d}", .{track.position}).ptr, "match-review-number", 26);
    gtk.gtk_widget_add_css_class(number, "numeric");
    const local = cell(strings.terminated(&buffer, track.local_title).ptr, if (differs) "match-review-differs" else "match-review-local", 0);
    const candidate = cell(strings.terminated(&buffer, if (track.candidate_title.len != 0) track.candidate_title else "—").ptr, "match-review-candidate", 0);
    const time = label(delta(&buffer, track.delta_ms).ptr, "match-review-delta");
    gtk.gtk_widget_add_css_class(time, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, time), 1);
    gtk.gtk_widget_set_size_request(time, 64, -1);
    const print = label(if (track.fingerprint) "✓" else "", "match-review-print");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, print), 1);
    gtk.gtk_widget_set_size_request(print, 44, -1);
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, "match-review-track");
    append(row, &.{ number, local, candidate, time, print });
    return row;
}

fn clear(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn showMessage(self: *App, text: ?[*:0]const u8) void {
    const review = &self.match_review;
    if (review.content) |content| gtk.gtk_widget_set_visible(content, @intFromBool(text == null));
    const message = review.message orelse return;
    gtk.gtk_label_set_text(message, text orelse "");
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, message), @intFromBool(text != null));
}

fn showPosition(self: *App) void {
    const review = &self.match_review;
    const total = review.total;
    var buffer: [64]u8 = undefined;
    if (review.position) |position| gtk.gtk_label_set_text(position, if (total == 0)
        ""
    else
        strings.format(&buffer, "Review {d} of {d}", .{ review.index + 1, total }).ptr);
    if (review.previous) |previous| gtk.gtk_widget_set_sensitive(previous, @intFromBool(review.index > 0));
    if (review.next) |next| gtk.gtk_widget_set_sensitive(next, @intFromBool(review.index + 1 < total));
}

fn show(self: *App) void {
    const review = &self.match_review;
    if (!review.built) return;
    showPosition(self);
    const entry = current(self) orelse return showMessage(self, if (review.loader != null) "Comparing…" else "Nothing left to review.");
    const diff = review.diff orelse return showMessage(self, if (review.loader != null) "Comparing…" else "This album has no MusicBrainz candidate any more.");
    showMessage(self, null);
    var buffer: [512]u8 = undefined;

    const album = for (diff.fields) |each| {
        if (each.field == .album) break each.local;
    } else "";
    const title_text = strings.terminated(&buffer, if (album.len != 0) album else "Untitled album");
    if (review.title) |title| gtk.gtk_label_set_text(title, title_text.ptr);
    if (review.crumb) |crumb| gtk.gtk_label_set_text(crumb, title_text.ptr);
    if (review.cover) |cover| {
        art.setInitials(cover, album);
        art.show(self, cover, art.Key.release(entry.release_id, art.Size.atLeast(cover_pixels)));
    }
    if (review.summary) |summary| gtk.gtk_label_set_text(summary, strings.format(&buffer, "Local album vs MusicBrainz candidate" ++ separator ++ "{d}% confidence" ++ separator, .{matches.percent(entry.confidence)}).ptr);

    review.checks = .initFill(null);
    review.rows = .initFill(null);
    if (review.fields) |fields| {
        clear(fields);
        gtk.gtk_box_append(fields, heading(&.{ "Use", "Field", "Local", "MusicBrainz" }, &.{ 40, 118, 175, 0 }, "match-review-head"));
        for (diff.fields) |each| gtk.gtk_box_append(fields, fieldRow(self, diff, each));
    }
    if (review.tracks_title) |tracks_title| gtk.gtk_label_set_text(tracks_title, strings.format(&buffer, "Tracks" ++ separator ++ "{d} of {d} aligned", .{ diff.aligned, diff.tracks.len }).ptr);
    if (review.tracks) |tracks| {
        clear(tracks);
        const head = heading(&.{ "#", "Local", "Candidate" }, &.{ 26, 0, 0 }, "match-review-head");
        const time = label("Δ time", "match-review-column");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, time), 1);
        gtk.gtk_widget_set_size_request(time, 64, -1);
        const print = label("Print", "match-review-column");
        gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, print), 1);
        gtk.gtk_widget_set_size_request(print, 44, -1);
        append(head, &.{ time, print });
        gtk.gtk_box_append(tracks, head);
        for (diff.tracks) |track| gtk.gtk_box_append(tracks, trackRow(track));
    }
    showChecked(self);
}

fn load(self: *App) void {
    const review = &self.match_review;
    const library = self.library orelse return;
    if (review.loader != null) return;
    const entry = current(self);
    const loader = self.allocator.create(Loader) catch return;
    loader.* = .{
        .runtime = self.runtime,
        .library = library,
        .waker = self.waker(),
        .scope = review.scope,
        .generation = review.generation,
        .index = review.index,
        .release_id = if (entry) |each| each.release_id else null,
    };
    loader.thread = std.Thread.spawn(.{}, Loader.run, .{loader}) catch {
        self.allocator.destroy(loader);
        return;
    };
    review.loader = loader;
    review.stale = false;
    if (review.diff) |*diff| diff.deinit();
    review.diff = null;
    show(self);
}

fn adoptWindow(self: *App, loader: *Loader) bool {
    const review = &self.match_review;
    review.entries.clearRetainingCapacity();
    review.window_offset = loader.window_offset;
    review.total = loader.total;
    review.index = loader.index;
    if (loader.window) |page| {
        review.entries.ensureTotalCapacity(self.allocator, page.items.len) catch {};
        for (page.items) |item| {
            const confidence = if (item.best) |best| best.confidence else 0;
            review.entries.append(self.allocator, .{ .release_id = item.release_id, .confidence = confidence }) catch break;
        }
    }
    review.window_stale = false;
    if (review.total == 0 or review.entries.items.len == 0) {
        review.total = 0;
        return true;
    }
    const skip = review.skip_release orelse return true;
    review.skip_release = null;
    const entry = current(self) orelse return true;
    if (entry.release_id != skip or review.index + 1 >= review.total) return true;
    review.index += 1;
    return current(self) != null;
}

pub fn tick(self: *App) void {
    const review = &self.match_review;
    const loader = review.loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    review.loader = null;
    defer loader.destroy(self.allocator);
    if (loader.generation != review.generation) return load(self);
    if (loader.windowed) {
        if (!adoptWindow(self, loader)) return load(self);
        if (review.total == 0) {
            show(self);
            if (self.current_page == .match_review) window.goTo(self, .matches);
            return;
        }
    }
    const entry = current(self);
    if (entry == null or loader.release_id == null or entry.?.release_id != loader.release_id.?) return load(self);
    review.diff = loader.diff;
    loader.diff = null;
    show(self);
}

pub fn shutdown(self: *App) void {
    const review = &self.match_review;
    if (review.loader) |loader| loader.destroy(self.allocator);
    review.loader = null;
}

pub fn forgetLibrary(self: *App) void {
    shutdown(self);
    const review = &self.match_review;
    if (review.diff) |*diff| diff.deinit();
    review.diff = null;
    review.entries.clearRetainingCapacity();
    review.window_offset = 0;
    review.total = 0;
    review.index = 0;
    review.skip_release = null;
    review.stale = true;
    review.window_stale = false;
    review.generation +%= 1;
}

pub fn open(self: *App, scope: Scope, entries: []const Entry, total: u64, at: usize) void {
    const review = &self.match_review;
    review.entries.clearRetainingCapacity();
    review.entries.appendSlice(self.allocator, entries) catch return;
    review.scope = scope;
    review.window_offset = 0;
    review.total = @max(total, entries.len);
    review.index = @min(at, entries.len -| 1);
    review.window_stale = false;
    review.skip_release = null;
    review.generation +%= 1;
    if (review.diff) |*diff| diff.deinit();
    review.diff = null;
    review.stale = true;
    window.goTo(self, .match_review);
    load(self);
}

pub fn invalidate(self: *App) void {
    const review = &self.match_review;
    review.stale = true;
    review.window_stale = true;
    review.generation +%= 1;
    if (self.current_page == .match_review and review.loader == null) load(self);
}

pub fn shown(self: *App) void {
    const review = &self.match_review;
    if (review.stale or review.diff == null) load(self) else show(self);
}

fn step(self: *App, forward: bool) void {
    const review = &self.match_review;
    if (forward and review.index + 1 >= review.total) return;
    if (!forward and review.index == 0) return;
    review.index = if (forward) review.index + 1 else review.index - 1;
    if (review.diff) |*diff| diff.deinit();
    review.diff = null;
    load(self);
}

fn previousClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    step(state(data), false);
}

fn nextClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    step(state(data), true);
}

fn handled(self: *App, skip: bool) void {
    const review = &self.match_review;
    review.skip_release = if (skip) if (current(self)) |entry| entry.release_id else null else null;
    if (review.diff) |*diff| diff.deinit();
    review.diff = null;
    matches.invalidate(self);
    invalidate(self);
}

fn applyClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const entry = current(self) orelse return;
    const fields = checkedFields(self);
    if (fields.count() == 0) return;
    const written = self.runtime.libraryApplyMatchedRelease(library, entry.release_id, fields) catch
        return self.toast("Could not apply the release");
    if (written == 0) return self.toast("Every track must be on the release first");
    var buffer: [48]u8 = undefined;
    self.toast(if (fields.count() == 1) "Applied 1 field" else strings.format(&buffer, "Applied {d} fields", .{fields.count()}));
    matches.accepted(self);
    handled(self, true);
}

fn notThisClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const library = self.library orelse return;
    const entry = current(self) orelse return;
    const diff = self.match_review.diff orelse return;
    self.runtime.libraryDismissReleaseCandidate(library, entry.release_id, diff.release_mbid) catch
        return self.toast("Could not dismiss the release");
    self.toast("Release dismissed");
    handled(self, false);
}

fn searchClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const entry = current(self) orelse return;
    jobs.startAlbumReidentification(self, entry.release_id);
}

fn linkClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const diff = self.match_review.diff orelse return;
    var buffer: [128]u8 = undefined;
    matches.openUrl(self, strings.printZ(&buffer, release_url ++ "{s}", .{diff.release_mbid}) catch return);
}

fn matchesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .matches);
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Matches");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(matchesClicked), self);
    const crumb_separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(crumb_separator, "breadcrumb-separator");
    const crumb = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(crumb, "breadcrumb-current");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, crumb), gtk.ELLIPSIZE_END);
    self.match_review.crumb = gtk.cast(gtk.Label, crumb);
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, crumb_separator, crumb });
    page_ui.addTrail(self, .match_review, crumbs);

    const previous = gtk.gtk_button_new_from_icon_name("orca-back-symbolic");
    gtk.gtk_widget_add_css_class(previous, "flat");
    gtk.gtk_widget_add_css_class(previous, "match-review-step");
    gtk.gtk_widget_set_tooltip_text(previous, "Previous album");
    _ = gtk.signalConnect(previous, "clicked", gtk.callback(previousClicked), self);
    const next = gtk.gtk_button_new_from_icon_name("orca-forward-symbolic");
    gtk.gtk_widget_add_css_class(next, "flat");
    gtk.gtk_widget_add_css_class(next, "match-review-step");
    gtk.gtk_widget_set_tooltip_text(next, "Next album");
    _ = gtk.signalConnect(next, "clicked", gtk.callback(nextClicked), self);
    const position = label("", "match-review-position");
    gtk.gtk_widget_add_css_class(position, "numeric");
    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 4);
    gtk.gtk_widget_set_valign(end, gtk.ALIGN_CENTER);
    append(end, &.{ previous, position, next });
    self.match_review.previous = previous;
    self.match_review.next = next;
    self.match_review.position = gtk.cast(gtk.Label, position);
    page_ui.addEnd(self, .match_review, end);
}

fn button(text: [*:0]const u8, class: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, self: *App) *gtk.Widget {
    const widget = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_widget_set_valign(widget, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(widget, tooltip);
    _ = gtk.signalConnect(widget, "clicked", handler, self);
    return widget;
}

fn buildHeader(self: *App) *gtk.Widget {
    const review = &self.match_review;
    const cover = art.newCover(self, art.initialsPlaceholder(), cover_pixels);
    gtk.gtk_widget_add_css_class(cover, "match-review-cover");
    gtk.gtk_widget_set_valign(cover, gtk.ALIGN_CENTER);
    review.cover = cover;

    const title = label("", "match-review-title");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, title), gtk.ELLIPSIZE_END);
    review.title = gtk.cast(gtk.Label, title);
    const summary = label("", "match-review-summary");
    review.summary = gtk.cast(gtk.Label, summary);
    const link_content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 3);
    const link_icon = gtk.gtk_image_new_from_icon_name("orca-external-link-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, link_icon), 12);
    append(link_content, &.{ gtk.gtk_label_new("Open release"), link_icon });
    const link = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, link), link_content);
    gtk.gtk_widget_add_css_class(link, "flat");
    gtk.gtk_widget_add_css_class(link, "match-review-link");
    gtk.gtk_widget_set_tooltip_text(link, "Open this release on MusicBrainz");
    _ = gtk.signalConnect(link, "clicked", gtk.callback(linkClicked), self);
    review.link = link;
    const subtitle = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    append(subtitle, &.{ summary, link });
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ title, subtitle });

    review.not_this = button("Not This Release", "match-again", "Dismiss this candidate; the album moves to Unmatched", gtk.callback(notThisClicked), self);
    review.search = button("Search MusicBrainz…", "match-again", "Search MusicBrainz for this album again, ignoring its IDs", gtk.callback(searchClicked), self);
    review.apply = button("Apply 0 Fields to Orca", "match-review-apply", "Take the checked fields into Orca's library; no file is written", gtk.callback(applyClicked), self);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_valign(actions, gtk.ALIGN_CENTER);
    append(actions, &.{ review.not_this.?, review.search.?, review.apply.? });

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 20);
    gtk.gtk_widget_add_css_class(header, "match-review-header");
    append(header, &.{ cover, text, actions });
    return header;
}

fn section(title: *gtk.Widget, body: *gtk.Widget, width: c_int) *gtk.Widget {
    const box = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(box, "match-review-section");
    gtk.gtk_widget_set_size_request(box, width, -1);
    gtk.gtk_widget_set_hexpand(box, gtk.true_);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_START);
    append(box, &.{ title, body });
    return box;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.match_review.scroller = null;
    self.match_review.built = false;
}

pub fn build(self: *App) *gtk.Widget {
    const review = &self.match_review;
    buildTrail(self);

    const fields = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(fields, "match-review-table");
    review.fields = gtk.cast(gtk.Box, fields);
    const tracks = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tracks, "match-review-table");
    review.tracks = gtk.cast(gtk.Box, tracks);
    const tracks_title = label("Tracks", "match-review-heading");
    review.tracks_title = gtk.cast(gtk.Label, tracks_title);

    const sections = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    append(sections, &.{
        section(label("Choose what to adopt", "match-review-heading"), fields, 560),
        section(tracks_title, tracks, 480),
    });

    const message = label("", "match-review-message");
    review.message = gtk.cast(gtk.Label, message);
    gtk.gtk_widget_set_visible(message, gtk.false_);

    const header = buildHeader(self);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(content, &.{ header, sections });
    review.content = content;

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "match-review-page");
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    append(column, &.{ content, message });

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    review.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(scrollerDestroyed), self);
    review.built = true;
    const bin = page_ui.breakpointBin(scroller);
    page_ui.stackBelow(bin, "max-width: 1140px", &.{sections}, &.{});
    page_ui.stackBelow(bin, "max-width: 750px", &.{ sections, header }, &.{});
    return bin;
}
