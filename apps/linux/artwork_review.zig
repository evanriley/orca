//! Artwork Review: the albums whose front cover is missing, undersized, or
//! differs between the files and the folder, one at a time, with the cover
//! Orca has now beside the Cover Art Archive's candidates for it.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const art = @import("art.zig");
const page_ui = @import("page.zig");
const window = @import("window.zig");
const health = @import("health.zig");
const metadata_editor = @import("metadata_editor.zig");

const App = app.App;

const max_albums = 2048;
const max_cards = liborca.max_cover_art_candidates;
const thumbnail_pixels = 178;
const cards_per_row = 3;
const local_pixels = 200;
const content_fit_contain: c_int = 1;

const Pick = enum(c_uint) { front, back, booklet, none };
const pick_labels = [_]?[*:0]const u8{ "Front", "Back", "Booklet", "Don't use", null };

fn kindOf(pick: Pick) ?liborca.ReleaseArtworkKind {
    return switch (pick) {
        .front => .front,
        .back => .back,
        .booklet => .booklet,
        .none => null,
    };
}

const Album = struct {
    release_id: i64,
    problem: liborca.ArtworkProblem,
    width: ?u32 = null,
    height: ?u32 = null,
    title: ?[:0]u8 = null,
    artist: ?[]u8 = null,
    year: ?[4]u8 = null,

    fn deinit(self: Album, allocator: std.mem.Allocator) void {
        if (self.title) |text| allocator.free(text);
        if (self.artist) |text| allocator.free(text);
    }
};

const ListLoader = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    allocator: std.mem.Allocator,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    albums: std.ArrayList(Album) = .empty,
    total: usize = 0,
    failed: bool = false,

    fn run(self: *ListLoader) void {
        self.load() catch {
            self.failed = true;
        };
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn load(self: *ListLoader) !void {
        self.total = try self.runtime.libraryArtworkProblemReleaseCount(self.library);
        var offset: u32 = 0;
        while (self.albums.items.len < max_albums) {
            const page = try self.runtime.libraryArtworkProblemReleasePage(self.library, app.page_size, offset);
            defer page.deinit();
            for (page.items) |item| {
                if (self.albums.items.len == max_albums) break;
                try self.albums.append(self.allocator, .{
                    .release_id = item.release_id,
                    .problem = item.finding.problem,
                    .width = item.finding.width,
                    .height = item.finding.height,
                });
            }
            if (page.items.len < app.page_size) break;
            offset += app.page_size;
        }
        for (self.albums.items) |*album| {
            const summary = (self.runtime.libraryRelease(self.library, album.release_id) catch null) orelse continue;
            defer summary.deinit(self.runtime.allocator);
            album.title = try self.allocator.dupeSentinel(u8, summary.title, 0);
            album.artist = try self.allocator.dupe(u8, summary.album_artist);
            if (summary.release_date) |date| if (date.len >= 4) {
                album.year = date[0..4].*;
            };
        }
    }

    fn destroy(self: *ListLoader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        for (self.albums.items) |album| album.deinit(self.allocator);
        self.albums.deinit(self.allocator);
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

const Decoded = struct {
    texture: ?*gtk.GdkTexture = null,
    width: c_int = 0,
    height: c_int = 0,
};

fn decode(bytes: []const u8, pixels: c_int) Decoded {
    const borrowed = gtk.g_bytes_new_static(bytes.ptr, bytes.len);
    defer gtk.g_bytes_unref(borrowed);
    const stream = gtk.g_memory_input_stream_new_from_bytes(borrowed);
    defer gtk.g_object_unref(stream);
    var err: ?*gtk.GError = null;
    const pixbuf = gtk.gdk_pixbuf_new_from_stream_at_scale(stream, -1, -1, gtk.true_, null, &err) orelse {
        gtk.g_clear_error(&err);
        return .{};
    };
    defer gtk.g_object_unref(pixbuf);
    const width = gtk.gdk_pixbuf_get_width(pixbuf);
    const height = gtk.gdk_pixbuf_get_height(pixbuf);
    const longest = @max(width, height);
    if (longest <= pixels or longest == 0)
        return .{ .texture = gtk.gdk_texture_new_for_pixbuf(pixbuf), .width = width, .height = height };
    const scaled_width = @max(1, @divTrunc(width * pixels, longest));
    const scaled_height = @max(1, @divTrunc(height * pixels, longest));
    const scaled = gtk.gdk_pixbuf_scale_simple(pixbuf, scaled_width, scaled_height, gtk.INTERP_BILINEAR) orelse
        return .{ .width = width, .height = height };
    defer gtk.g_object_unref(scaled);
    return .{ .texture = gtk.gdk_texture_new_for_pixbuf(scaled), .width = width, .height = height };
}

fn imageType(mime: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, mime, "image/jpeg")) return "JPEG";
    if (std.mem.eql(u8, mime, "image/png")) return "PNG";
    if (std.mem.eql(u8, mime, "image/gif")) return "GIF";
    if (std.mem.eql(u8, mime, "image/bmp")) return "BMP";
    if (std.mem.eql(u8, mime, "image/webp")) return "WebP";
    return "Image";
}

const DetailLoader = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    allocator: std.mem.Allocator,
    release_id: i64,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    candidates: []liborca.CoverArtCandidate = &.{},
    thumbnails: [max_cards]?*gtk.GdkTexture = @splat(null),
    local: Decoded = .{},
    local_found: bool = false,
    local_type: [:0]const u8 = "",

    fn run(self: *DetailLoader) void {
        self.load();
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn load(self: *DetailLoader) void {
        if (self.runtime.libraryCoverArtCandidates(self.library, self.allocator, self.release_id)) |list| {
            self.candidates = list;
            for (list[0..@min(list.len, max_cards)], 0..) |candidate, index| {
                const bytes = candidate.thumbnail orelse continue;
                self.thumbnails[index] = decode(bytes, thumbnail_pixels).texture;
            }
        } else |_| {}
        const image = (self.runtime.libraryReleaseArtwork(self.library, self.threaded.io(), self.release_id) catch null) orelse return;
        defer image.deinit();
        self.local_found = true;
        self.local_type = imageType(image.mime_type);
        self.local = decode(image.bytes, local_pixels);
    }

    fn destroy(self: *DetailLoader, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        for (self.thumbnails) |texture| if (texture) |owned| gtk.g_object_unref(owned);
        if (self.local.texture) |owned| gtk.g_object_unref(owned);
        for (self.candidates) |candidate| candidate.deinit(self.allocator);
        self.allocator.free(self.candidates);
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

pub const Origin = enum { review, editor };

const ReadFailure = enum { none, unreadable, too_large, not_image };

const ImageRead = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    allocator: std.mem.Allocator,
    waker: liborca.HostWaker,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    path: [:0]u8,
    releases: []i64,
    origin: Origin,
    bytes: ?[]u8 = null,
    mime: []const u8 = "",
    failure: ReadFailure = .none,

    fn run(self: *ImageRead) void {
        self.read();
        self.finished.store(true, .release);
        self.waker.wake_fn(self.waker.context);
    }

    fn read(self: *ImageRead) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.threaded.io(), self.path, self.allocator, .limited(liborca.max_image_bytes + 1)) catch |err| {
            self.failure = if (err == error.StreamTooLong) .too_large else .unreadable;
            return;
        };
        self.mime = liborca.sniffImageMimeType(bytes) orelse {
            self.allocator.free(bytes);
            self.failure = .not_image;
            return;
        };
        self.bytes = bytes;
    }

    fn destroy(self: *ImageRead, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.path);
        self.allocator.free(self.releases);
        self.threaded.deinit();
        allocator.destroy(self);
    }
};

const Card = struct {
    widget: *gtk.Widget,
    drop_down: *gtk.DropDown,
    caa_id: i64,
};

const Tracked = struct {
    job: liborca.JobHandle,
    release_id: i64,
};

const Apply = struct {
    release_id: i64,
    picks: [3]?i64,
    next: usize = 0,
    job: ?liborca.JobHandle = null,
    applied: usize = 0,
    failed: usize = 0,
};

const Choice = struct {
    releases: []i64,
    origin: Origin,
};

pub const State = struct {
    built: bool = false,
    stale: bool = true,
    summary: ?*gtk.Label = null,
    list: ?*gtk.Box = null,
    empty: ?*gtk.Widget = null,
    detail: ?*gtk.Widget = null,
    heading: ?*gtk.Label = null,
    subtitle: ?*gtk.Label = null,
    local_stack: ?*gtk.Stack = null,
    local_picture: ?*gtk.Picture = null,
    local_note: ?*gtk.Label = null,
    choose: ?*gtk.Widget = null,
    candidates: ?*gtk.Grid = null,
    candidates_note: ?*gtk.Label = null,
    find: ?*gtk.Widget = null,
    use: ?*gtk.Widget = null,
    skip: ?*gtk.Widget = null,
    albums: std.ArrayList(Album) = .empty,
    total: usize = 0,
    selected: ?i64 = null,
    detail_release: ?i64 = null,
    candidate_count: usize = 0,
    cards: [max_cards]Card = undefined,
    card_count: usize = 0,
    syncing: bool = false,
    list_loader: ?*ListLoader = null,
    list_again: bool = false,
    detail_loader: ?*DetailLoader = null,
    find_job: ?Tracked = null,
    find_outcome: ?struct { release_id: i64, outcome: liborca.CoverArtOutcome } = null,
    apply: ?Apply = null,
    choice: ?Choice = null,
    image_read: ?*ImageRead = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.albums.items) |album| album.deinit(allocator);
        self.albums.deinit(allocator);
        if (self.choice) |choice| allocator.free(choice.releases);
        self.choice = null;
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

fn imageIcon(pixels: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("orca-image-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), pixels);
    gtk.gtk_widget_add_css_class(icon, "artwork-review-icon");
    return icon;
}

pub fn build(self: *App) *gtk.Widget {
    buildTrail(self);

    const title = page_ui.title("Artwork Review");
    gtk.gtk_widget_add_css_class(title.widget, "artwork-review-title");
    const meta = gtk.cast(gtk.Widget, title.meta);
    gtk.gtk_widget_remove_css_class(meta, "numeric");
    gtk.gtk_widget_add_css_class(meta, "artwork-review-summary");
    self.artwork_review.summary = title.meta;

    const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(list, "artwork-review-list");
    self.artwork_review.list = gtk.cast(gtk.Box, list);
    const empty = label("Every album has a front cover of a good size.", "artwork-review-empty");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, empty), gtk.true_);
    gtk.gtk_widget_set_visible(empty, gtk.false_);
    self.artwork_review.empty = empty;
    const list_column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    append(list_column, &.{ list, empty });
    const list_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, list_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, list_scroller), list_column);
    gtk.gtk_widget_set_size_request(list_scroller, 275, -1);
    gtk.gtk_widget_set_hexpand(list_scroller, gtk.false_);
    gtk.gtk_widget_add_css_class(list_scroller, "artwork-review-albums");
    _ = gtk.signalConnect(list_scroller, "destroy", gtk.callback(scrollerDestroyed), self);

    const detail_scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, detail_scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, detail_scroller), buildDetail(self));
    gtk.gtk_widget_set_hexpand(detail_scroller, gtk.true_);

    const split = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(split, "artwork-review-split");
    gtk.gtk_widget_set_vexpand(split, gtk.true_);
    append(split, &.{ list_scroller, detail_scroller });

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "artwork-review-page");
    append(column, &.{ title.widget, split });
    self.artwork_review.built = true;
    return column;
}

fn buildTrail(self: *App) void {
    const parent = gtk.gtk_button_new_with_label("Library Health");
    gtk.gtk_widget_add_css_class(parent, "flat");
    gtk.gtk_widget_add_css_class(parent, "breadcrumb-parent");
    _ = gtk.signalConnect(parent, "clicked", gtk.callback(healthClicked), self);
    const separator = gtk.gtk_label_new("›");
    gtk.gtk_widget_add_css_class(separator, "breadcrumb-separator");
    const current = gtk.gtk_label_new("Artwork");
    gtk.gtk_widget_add_css_class(current, "breadcrumb-current");
    const crumbs = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 2);
    gtk.gtk_widget_add_css_class(crumbs, "breadcrumb");
    append(crumbs, &.{ parent, separator, current });
    page_ui.addTrail(self, .artwork_review, crumbs);
}

fn healthClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.goTo(state(data), .health);
}

fn buildDetail(self: *App) *gtk.Widget {
    const review = &self.artwork_review;
    const heading = label("", "artwork-review-heading");
    gtk.gtk_widget_set_valign(heading, gtk.ALIGN_BASELINE_FILL);
    review.heading = gtk.cast(gtk.Label, heading);
    const subtitle = label("", "artwork-review-subtitle");
    gtk.gtk_widget_set_valign(subtitle, gtk.ALIGN_BASELINE_FILL);
    review.subtitle = gtk.cast(gtk.Label, subtitle);
    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    append(header, &.{ heading, subtitle });

    const columns = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    append(columns, &.{ buildLocal(self), buildCandidates(self) });

    const use = button("Use Selected Artwork", "btn-primary", gtk.callback(useClicked), self);
    gtk.gtk_widget_add_css_class(use, "artwork-review-use");
    review.use = use;
    const skip = button("Skip", "btn-secondary", gtk.callback(skipClicked), self);
    gtk.gtk_widget_add_css_class(skip, "artwork-review-skip");
    review.skip = skip;
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    append(actions, &.{ use, skip });

    const detail = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 20);
    gtk.gtk_widget_add_css_class(detail, "artwork-review-detail");
    append(detail, &.{ header, columns, actions });
    gtk.gtk_widget_set_visible(detail, gtk.false_);
    review.detail = detail;
    return detail;
}

fn buildLocal(self: *App) *gtk.Widget {
    const review = &self.artwork_review;
    const missing = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(missing, "artwork-review-missing");
    gtk.gtk_widget_set_valign(missing, gtk.ALIGN_FILL);
    const missing_icon = imageIcon(26);
    gtk.gtk_widget_set_valign(missing_icon, gtk.ALIGN_END);
    gtk.gtk_widget_set_vexpand(missing_icon, gtk.true_);
    const missing_text = gtk.gtk_label_new("No artwork found");
    gtk.gtk_widget_add_css_class(missing_text, "artwork-review-missing-text");
    gtk.gtk_widget_set_valign(missing_text, gtk.ALIGN_START);
    gtk.gtk_widget_set_vexpand(missing_text, gtk.true_);
    append(missing, &.{ missing_icon, missing_text });

    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, picture), gtk.true_);
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, picture), content_fit_contain);
    gtk.gtk_widget_add_css_class(picture, "artwork-review-local-image");
    gtk.gtk_widget_set_overflow(picture, gtk.OVERFLOW_HIDDEN);
    review.local_picture = gtk.cast(gtk.Picture, picture);

    const stack = gtk.gtk_stack_new();
    gtk.gtk_widget_set_size_request(stack, local_pixels, local_pixels);
    gtk.gtk_widget_set_vexpand(stack, gtk.false_);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), missing, "missing");
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, stack), picture, "image");
    review.local_stack = gtk.cast(gtk.Stack, stack);

    const note = label("", "artwork-review-note");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note), gtk.true_);
    review.local_note = gtk.cast(gtk.Label, note);

    const choose_content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(choose_content, gtk.ALIGN_CENTER);
    const plus = gtk.gtk_image_new_from_icon_name("orca-plus-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, plus), 13);
    append(choose_content, &.{ plus, gtk.gtk_label_new("Choose Image…") });
    const choose = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, choose), choose_content);
    gtk.gtk_widget_add_css_class(choose, "btn-secondary");
    gtk.gtk_widget_add_css_class(choose, "artwork-review-choose");
    _ = gtk.signalConnect(choose, "clicked", gtk.callback(chooseClicked), self);
    review.choose = choose;

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_set_size_request(column, local_pixels, -1);
    gtk.gtk_widget_set_hexpand(column, gtk.false_);
    gtk.gtk_widget_set_valign(column, gtk.ALIGN_START);
    append(column, &.{ label("LOCAL", "artwork-review-section"), stack, note, choose });
    return column;
}

fn buildCandidates(self: *App) *gtk.Widget {
    const review = &self.artwork_review;
    const cards = gtk.gtk_grid_new();
    const grid = gtk.cast(gtk.Grid, cards);
    gtk.gtk_grid_set_column_homogeneous(grid, gtk.true_);
    gtk.gtk_grid_set_column_spacing(grid, 16);
    gtk.gtk_grid_set_row_spacing(grid, 16);
    gtk.gtk_widget_set_halign(cards, gtk.ALIGN_START);
    gtk.gtk_widget_set_valign(cards, gtk.ALIGN_START);
    review.candidates = grid;

    const note = label("", "artwork-review-note");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note), gtk.true_);
    review.candidates_note = gtk.cast(gtk.Label, note);
    const find = button("Find Candidates", "btn-secondary", gtk.callback(findClicked), self);
    gtk.gtk_widget_add_css_class(find, "artwork-review-find");
    gtk.gtk_widget_set_halign(find, gtk.ALIGN_START);
    review.find = find;

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    append(column, &.{ label("COVER ART ARCHIVE CANDIDATES", "artwork-review-section"), cards, note, find });
    return column;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const review = &state(data).artwork_review;
    review.built = false;
    review.list = null;
    review.detail = null;
    review.candidates = null;
    review.card_count = 0;
}

pub fn shown(self: *App) void {
    reload(self);
}

pub fn invalidate(self: *App) void {
    self.artwork_review.stale = true;
    if (self.current_page == .artwork_review) reload(self);
}

fn reload(self: *App) void {
    const review = &self.artwork_review;
    if (!review.built) return;
    review.stale = false;
    const library = self.library orelse return;
    if (review.list_loader != null) {
        review.list_again = true;
        return;
    }
    const loader = self.allocator.create(ListLoader) catch return;
    loader.* = .{ .runtime = self.runtime, .library = library, .allocator = self.allocator, .waker = self.waker() };
    loader.thread = std.Thread.spawn(.{}, ListLoader.run, .{loader}) catch {
        loader.destroy(self.allocator);
        return self.toast("Could not read the albums' artwork");
    };
    review.list_loader = loader;
}

pub fn tick(self: *App) void {
    tickList(self);
    tickDetail(self);
    tickFind(self);
    tickApply(self);
    tickImageRead(self);
}

pub fn shutdown(self: *App) void {
    const review = &self.artwork_review;
    if (review.list_loader) |loader| loader.destroy(self.allocator);
    review.list_loader = null;
    if (review.detail_loader) |loader| loader.destroy(self.allocator);
    review.detail_loader = null;
    if (review.image_read) |read| read.destroy(self.allocator);
    review.image_read = null;
}

pub fn forgetLibrary(self: *App) void {
    shutdown(self);
    const review = &self.artwork_review;
    for (review.albums.items) |album| album.deinit(self.allocator);
    review.albums.clearRetainingCapacity();
    review.total = 0;
    review.selected = null;
    review.detail_release = null;
    review.list_again = false;
    review.find_job = null;
    review.find_outcome = null;
    review.apply = null;
    if (review.choice) |choice| self.allocator.free(choice.releases);
    review.choice = null;
    review.stale = true;
    showList(self);
}

fn tickList(self: *App) void {
    const review = &self.artwork_review;
    const loader = review.list_loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    review.list_loader = null;
    defer loader.destroy(self.allocator);
    if (loader.failed) {
        self.toast("Could not read the albums' artwork");
    } else {
        for (review.albums.items) |album| album.deinit(self.allocator);
        review.albums.deinit(self.allocator);
        review.albums = loader.albums;
        loader.albums = .empty;
        review.total = loader.total;
        showList(self);
    }
    if (review.list_again) {
        review.list_again = false;
        reload(self);
    }
}

fn albumIndex(self: *App, release_id: ?i64) ?usize {
    const wanted = release_id orelse return null;
    for (self.artwork_review.albums.items, 0..) |album, index| if (album.release_id == wanted) return index;
    return null;
}

fn showList(self: *App) void {
    const review = &self.artwork_review;
    if (!review.built) return;
    var buffer: [128]u8 = undefined;
    if (review.summary) |summary| gtk.gtk_label_set_text(summary, if (review.total == 0)
        "No albums with missing, undersized or conflicting artwork."
    else if (review.total == 1)
        "1 album with missing, undersized or conflicting artwork."
    else
        strings.format(&buffer, "{f} albums with missing, undersized or conflicting artwork.", .{strings.grouped(review.total)}));
    const list = review.list orelse return;
    clear(list);
    for (review.albums.items, 0..) |album, index| gtk.gtk_box_append(list, row(self, album, index));
    if (review.empty) |empty| gtk.gtk_widget_set_visible(empty, @intFromBool(review.albums.items.len == 0));
    if (albumIndex(self, review.selected) == null)
        review.selected = if (review.albums.items.len > 0) review.albums.items[0].release_id else null;
    review.detail_release = null;
    showSelected(self);
}

fn problemText(buffer: []u8, album: Album) [:0]const u8 {
    return switch (album.problem) {
        .missing_front => "Missing front",
        .undersized => if (album.width != null and album.height != null)
            strings.format(buffer, "{d} × {d} · undersized", .{ album.width.?, album.height.? })
        else
            "Undersized",
        .conflicting => "Embedded and folder differ",
    };
}

fn row(self: *App, album: Album, index: usize) *gtk.Widget {
    const tile = imageIcon(15);
    gtk.gtk_widget_set_size_request(tile, 40, 40);
    gtk.gtk_widget_set_valign(tile, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(tile, "artwork-review-tile");
    const title = label(if (album.title) |text| text.ptr else "Unknown album", "artwork-review-row-title");
    var buffer: [64]u8 = undefined;
    const subtitle = label(problemText(&buffer, album), "artwork-review-row-subtitle");
    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    append(text, &.{ title, subtitle });
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    append(content, &.{ tile, text });
    const widget = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, widget), content);
    gtk.gtk_widget_add_css_class(widget, "flat");
    gtk.gtk_widget_add_css_class(widget, "artwork-review-row");
    gtk.g_object_set_data(widget, "orca-album", @ptrFromInt(index + 1));
    _ = gtk.signalConnect(widget, "clicked", gtk.callback(rowClicked), self);
    return widget;
}

fn rowClicked(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const tagged = gtk.g_object_get_data(widget.?, "orca-album") orelse return;
    const index = @intFromPtr(tagged) - 1;
    const albums = self.artwork_review.albums.items;
    if (index >= albums.len) return;
    select(self, albums[index].release_id);
}

fn select(self: *App, release_id: i64) void {
    if (self.artwork_review.selected == release_id and self.artwork_review.detail_release == release_id) return;
    self.artwork_review.selected = release_id;
    showSelected(self);
}

fn syncRows(self: *App) void {
    const review = &self.artwork_review;
    const list = review.list orelse return;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list));
    var index: usize = 0;
    while (child) |widget| : (index += 1) {
        const items = review.albums.items;
        const selected = index < items.len and review.selected != null and items[index].release_id == review.selected.?;
        if (selected) gtk.gtk_widget_add_css_class(widget, "selected") else gtk.gtk_widget_remove_css_class(widget, "selected");
        child = gtk.gtk_widget_get_next_sibling(widget);
    }
}

fn headerText(buffer: []u8, album: Album) [:0]const u8 {
    const problem: []const u8 = switch (album.problem) {
        .missing_front => "no front cover",
        .undersized => "undersized front cover",
        .conflicting => "embedded and folder covers differ",
    };
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    if (album.artist) |artist| if (artist.len > 0) writer.print("{s} · ", .{artist}) catch {};
    if (album.year) |year| writer.print("{s} · ", .{&year}) catch {};
    writer.writeAll(problem) catch {};
    const written = writer.buffered();
    buffer[written.len] = 0;
    return buffer[0..written.len :0];
}

fn showSelected(self: *App) void {
    const review = &self.artwork_review;
    syncRows(self);
    const detail = review.detail orelse return;
    const index = albumIndex(self, review.selected) orelse {
        gtk.gtk_widget_set_visible(detail, gtk.false_);
        return;
    };
    gtk.gtk_widget_set_visible(detail, gtk.true_);
    const album = review.albums.items[index];
    if (review.heading) |heading| gtk.gtk_label_set_text(heading, if (album.title) |text| text.ptr else "Unknown album");
    var buffer: [320]u8 = undefined;
    if (review.subtitle) |subtitle| gtk.gtk_label_set_text(subtitle, headerText(&buffer, album));
    if (review.detail_release != album.release_id) {
        review.detail_release = album.release_id;
        showLocal(self, .{}, false, "");
        clearCards(self);
        review.candidate_count = 0;
        loadDetail(self);
    }
    syncControls(self);
}

fn loadDetail(self: *App) void {
    const review = &self.artwork_review;
    const library = self.library orelse return;
    const release_id = review.detail_release orelse return;
    if (review.detail_loader != null) return;
    const loader = self.allocator.create(DetailLoader) catch return;
    loader.* = .{
        .runtime = self.runtime,
        .library = library,
        .allocator = self.allocator,
        .release_id = release_id,
        .waker = self.waker(),
    };
    loader.thread = std.Thread.spawn(.{}, DetailLoader.run, .{loader}) catch {
        loader.destroy(self.allocator);
        return self.toast("Could not read the album's artwork");
    };
    review.detail_loader = loader;
}

fn tickDetail(self: *App) void {
    const review = &self.artwork_review;
    const loader = review.detail_loader orelse return;
    if (!loader.finished.load(.acquire)) return;
    review.detail_loader = null;
    defer loader.destroy(self.allocator);
    if (review.detail_release != loader.release_id) return loadDetail(self);
    showLocal(self, loader.local, loader.local_found, loader.local_type);
    showCards(self, loader);
    syncControls(self);
}

fn showLocal(self: *App, local: Decoded, found: bool, type_name: [:0]const u8) void {
    const review = &self.artwork_review;
    const stack = review.local_stack orelse return;
    const picture = review.local_picture orelse return;
    const note = review.local_note orelse return;
    if (!found or local.texture == null) {
        gtk.gtk_picture_set_paintable(picture, null);
        gtk.gtk_stack_set_visible_child_name(stack, "missing");
        gtk.gtk_label_set_text(note, if (found) "The cover would not read" else "Folder and embedded tags checked");
        return;
    }
    gtk.gtk_picture_set_paintable(picture, gtk.cast(gtk.GdkPaintable, local.texture.?));
    gtk.gtk_stack_set_visible_child_name(stack, "image");
    var buffer: [64]u8 = undefined;
    gtk.gtk_label_set_text(note, strings.format(&buffer, "{d} × {d} · {s}", .{ local.width, local.height, type_name }));
}

fn clearCards(self: *App) void {
    const review = &self.artwork_review;
    defer review.card_count = 0;
    const grid = review.candidates orelse return;
    for (review.cards[0..review.card_count]) |card| gtk.gtk_grid_remove(grid, card.widget);
}

fn candidateKind(candidate: liborca.CoverArtCandidate) [*:0]const u8 {
    return switch (candidate.kind) {
        .front => if (candidate.approved) "Release · approved" else "Release",
        .release_group => "Release group",
        .back => "Back cover",
        .booklet => "Booklet",
        .other => "Other",
    };
}

fn defaultPick(candidate: liborca.CoverArtCandidate, taken: *[3]bool) Pick {
    const pick: Pick = switch (candidate.kind) {
        .front, .release_group => .front,
        .back => .back,
        .booklet, .other => .none,
    };
    if (pick == .none) return .none;
    const slot = &taken[@backingInt(pick)];
    if (slot.*) return .none;
    slot.* = true;
    return pick;
}

fn showCards(self: *App, loader: *DetailLoader) void {
    const review = &self.artwork_review;
    clearCards(self);
    review.candidate_count = loader.candidates.len;
    const grid = review.candidates orelse return;
    var taken: [3]bool = @splat(false);
    review.syncing = true;
    defer review.syncing = false;
    for (loader.candidates[0..@min(loader.candidates.len, max_cards)], 0..) |candidate, index| {
        const card = newCard(self, candidate, loader.thumbnails[index], defaultPick(candidate, &taken));
        const column: c_int = @intCast(index % cards_per_row);
        const line: c_int = @intCast(index / cards_per_row);
        gtk.gtk_grid_attach(grid, card.widget, column, line, 1, 1);
        review.cards[review.card_count] = card;
        review.card_count += 1;
    }
    syncCards(self);
}

fn newCard(self: *App, candidate: liborca.CoverArtCandidate, thumbnail: ?*gtk.GdkTexture, pick: Pick) Card {
    const picture = gtk.gtk_picture_new();
    gtk.gtk_picture_set_can_shrink(gtk.cast(gtk.Picture, picture), gtk.true_);
    gtk.gtk_picture_set_content_fit(gtk.cast(gtk.Picture, picture), content_fit_contain);
    if (thumbnail) |texture| gtk.gtk_picture_set_paintable(gtk.cast(gtk.Picture, picture), gtk.cast(gtk.GdkPaintable, texture));
    const frame = gtk.gtk_stack_new();
    gtk.gtk_widget_add_css_class(frame, "artwork-review-thumb");
    gtk.gtk_widget_set_overflow(frame, gtk.OVERFLOW_HIDDEN);
    gtk.gtk_widget_set_size_request(frame, thumbnail_pixels, thumbnail_pixels);
    _ = gtk.gtk_stack_add_named(gtk.cast(gtk.Stack, frame), if (thumbnail == null) imageIcon(26) else picture, "thumb");

    var buffer: [64]u8 = undefined;
    const type_name = if (candidate.mime) |mime| imageType(mime) else "Image";
    const size_text = if (candidate.width != null and candidate.height != null)
        strings.format(&buffer, "{d} × {d} · {s}", .{ candidate.width.?, candidate.height.?, type_name })
    else
        strings.format(&buffer, "Size unknown · {s}", .{type_name});
    const size = label(size_text, "artwork-review-card-size");
    const kind = label(candidateKind(candidate), "artwork-review-card-kind");

    const use_as = label("Use as", "artwork-review-card-use");
    gtk.gtk_widget_set_hexpand(use_as, gtk.true_);
    gtk.gtk_widget_set_valign(use_as, gtk.ALIGN_CENTER);
    const drop_down = gtk.gtk_drop_down_new_from_strings(&pick_labels);
    gtk.gtk_widget_add_css_class(drop_down, "smart-control");
    gtk.gtk_widget_add_css_class(drop_down, "artwork-review-pick");
    gtk.gtk_widget_set_valign(drop_down, gtk.ALIGN_CENTER);
    gtk.gtk_drop_down_set_selected(gtk.cast(gtk.DropDown, drop_down), @backingInt(pick));
    _ = gtk.signalConnect(drop_down, "notify::selected", gtk.callback(pickChanged), self);
    const use_row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_add_css_class(use_row, "artwork-review-card-row");
    append(use_row, &.{ use_as, drop_down });

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    append(text, &.{ size, kind });
    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(widget, "artwork-review-card");
    gtk.gtk_widget_set_halign(widget, gtk.ALIGN_START);
    append(widget, &.{ frame, text, use_row });
    return .{ .widget = widget, .drop_down = gtk.cast(gtk.DropDown, drop_down), .caa_id = candidate.caa_id };
}

fn pickOf(card: Card) Pick {
    const selected = gtk.gtk_drop_down_get_selected(card.drop_down);
    return if (selected < 3) @fromBackingInt(@intCast(selected)) else .none;
}

fn pickChanged(drop_down: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const review = &self.artwork_review;
    if (review.syncing) return;
    const changed = gtk.cast(gtk.DropDown, drop_down);
    const pick = pickOf(.{ .widget = undefined, .drop_down = changed, .caa_id = 0 });
    review.syncing = true;
    defer review.syncing = false;
    if (pick != .none) for (review.cards[0..review.card_count]) |card| {
        if (card.drop_down == changed) continue;
        if (pickOf(card) == pick) gtk.gtk_drop_down_set_selected(card.drop_down, @backingInt(Pick.none));
    };
    syncCards(self);
    syncControls(self);
}

fn syncCards(self: *App) void {
    const review = &self.artwork_review;
    for (review.cards[0..review.card_count]) |card| {
        if (pickOf(card) == .front)
            gtk.gtk_widget_add_css_class(card.widget, "selected")
        else
            gtk.gtk_widget_remove_css_class(card.widget, "selected");
    }
}

fn hasPicks(self: *App) bool {
    const review = &self.artwork_review;
    for (review.cards[0..review.card_count]) |card| if (pickOf(card) != .none) return true;
    return false;
}

fn syncControls(self: *App) void {
    const review = &self.artwork_review;
    const busy = review.apply != null;
    const finding = if (review.find_job) |tracked| tracked.release_id == review.detail_release else false;
    const loading = review.detail_loader != null;
    if (review.use) |use| gtk.gtk_widget_set_sensitive(use, @intFromBool(!busy and !loading and hasPicks(self)));
    if (review.skip) |skip| gtk.gtk_widget_set_sensitive(skip, @intFromBool(!busy and review.albums.items.len > 1));
    if (review.choose) |choose| gtk.gtk_widget_set_sensitive(choose, @intFromBool(!busy and review.image_read == null));
    const note = review.candidates_note orelse return;
    const find = review.find orelse return;
    const listed = review.candidate_count > 0;
    gtk.gtk_widget_set_visible(find, @intFromBool(!listed and !loading));
    gtk.gtk_widget_set_sensitive(find, @intFromBool(!finding and !busy));
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, note), @intFromBool(!listed or busy));
    if (busy) return gtk.gtk_label_set_text(note, "Fetching the chosen images…");
    if (loading) return gtk.gtk_label_set_text(note, "");
    if (finding) return gtk.gtk_label_set_text(note, "Asking the Cover Art Archive…");
    const outcome = if (review.find_outcome) |found| (if (found.release_id == review.detail_release) found.outcome else null) else null;
    gtk.gtk_label_set_text(note, if (outcome) |value| switch (value) {
        .not_found => "The Cover Art Archive has no images for this album.",
        .no_release_id => "This album has no MusicBrainz release ID yet. Match it first.",
        else => "The Cover Art Archive could not be reached. Try again later.",
    } else "Look for this album's images on the Cover Art Archive.");
}

fn refusal(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.MatchingAlreadyRunning => "Already finding matches or covers; try again when that finishes",
        error.ClientIdentityRequired => "Cover Art Archive lookups are not available",
        error.JobQueueFull => "Too many tasks are waiting; try again when some have finished",
        error.UnknownCoverArtCandidate => "That image is no longer listed; find candidates again",
        else => "Could not ask the Cover Art Archive",
    };
}

fn findClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const review = &self.artwork_review;
    const library = self.library orelse return;
    const release_id = review.detail_release orelse return;
    if (review.find_job != null) return self.toast("Already asking the Cover Art Archive");
    const job = self.runtime.startCoverArtCandidates(library, release_id) catch |err| return self.toast(refusal(err));
    review.find_job = .{ .job = job, .release_id = release_id };
    syncControls(self);
    self.requestTick();
}

fn ended(state_value: liborca.JobState) bool {
    return switch (state_value) {
        .succeeded, .failed, .cancelled => true,
        else => false,
    };
}

fn tickFind(self: *App) void {
    const review = &self.artwork_review;
    const tracked = review.find_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(tracked.job) catch null;
    if (snapshot) |value| if (!ended(value.state)) return;
    review.find_job = null;
    const stats = self.runtime.jobMatchStats(tracked.job) catch null;
    review.find_outcome = .{ .release_id = tracked.release_id, .outcome = if (stats) |value| value.cover_art else .refused };
    if (snapshot) |value| if (value.state == .cancelled) self.toast("Stopped");
    if (review.detail_release == tracked.release_id) loadDetail(self);
    syncControls(self);
}

fn useClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const review = &self.artwork_review;
    if (review.apply != null) return;
    const release_id = review.detail_release orelse return;
    var picks: [3]?i64 = @splat(null);
    for (review.cards[0..review.card_count]) |card| {
        const pick = pickOf(card);
        if (pick != .none) picks[@backingInt(pick)] = card.caa_id;
    }
    review.apply = .{ .release_id = release_id, .picks = picks };
    advanceApply(self);
}

fn advanceApply(self: *App) void {
    const review = &self.artwork_review;
    const apply = &(review.apply orelse return);
    const library = self.library orelse return finishApply(self);
    while (apply.next < apply.picks.len) {
        const index = apply.next;
        apply.next += 1;
        const caa_id = apply.picks[index] orelse continue;
        const kind = kindOf(@fromBackingInt(@intCast(index))).?;
        apply.job = self.runtime.libraryUseCoverArtCandidate(library, apply.release_id, caa_id, kind) catch |err| {
            self.toast(refusal(err));
            apply.failed += 1;
            continue;
        };
        syncControls(self);
        self.requestTick();
        return;
    }
    finishApply(self);
}

fn tickApply(self: *App) void {
    const review = &self.artwork_review;
    const apply = &(review.apply orelse return);
    const job = apply.job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch null;
    if (snapshot) |value| if (!ended(value.state)) return;
    apply.job = null;
    if (snapshot != null and snapshot.?.state == .succeeded) apply.applied += 1 else apply.failed += 1;
    advanceApply(self);
}

fn finishApply(self: *App) void {
    const review = &self.artwork_review;
    const apply = review.apply orelse return;
    review.apply = null;
    if (apply.applied == 0) {
        if (apply.failed > 0) self.toast("Could not fetch the chosen artwork");
        return syncControls(self);
    }
    self.toast(if (apply.failed == 0) "Saved the album's artwork" else "Saved some of the album's artwork");
    if (review.detail_release == apply.release_id) moveOn(self, apply.release_id);
    coverChanged(self, &.{apply.release_id});
}

fn skipClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const release_id = self.artwork_review.selected orelse return;
    const next = neighbour(self, release_id) orelse return;
    select(self, next);
}

fn neighbour(self: *App, release_id: i64) ?i64 {
    const albums = self.artwork_review.albums.items;
    const index = albumIndex(self, release_id) orelse return null;
    if (albums.len < 2) return null;
    return albums[(index + 1) % albums.len].release_id;
}

fn moveOn(self: *App, release_id: i64) void {
    if (neighbour(self, release_id)) |next| select(self, next);
}

pub fn coverChanged(self: *App, releases: []const i64) void {
    for (releases) |release_id| art.refreshRelease(self, release_id);
    health.reload(self);
    invalidate(self);
    if (self.artwork_review.detail_release) |shown_release| for (releases) |release_id| {
        if (release_id != shown_release) continue;
        self.artwork_review.detail_release = null;
        showSelected(self);
        break;
    };
}

fn chooseClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const release_id = self.artwork_review.detail_release orelse return;
    chooseFrontImage(self, &.{release_id}, .review);
}

pub fn chooseFrontImage(self: *App, releases: []const i64, origin: Origin) void {
    const review = &self.artwork_review;
    if (releases.len == 0) return;
    if (self.library == null) return self.toast("No library is open");
    if (review.image_read != null) return self.toast("Still reading the last image");
    const owned = self.allocator.dupe(i64, releases) catch return self.toast("Out of memory");
    if (review.choice) |previous| self.allocator.free(previous.releases);
    review.choice = .{ .releases = owned, .origin = origin };

    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Choose Cover Image");
    const filter = gtk.gtk_file_filter_new();
    gtk.gtk_file_filter_set_name(filter, "Images");
    for ([_][*:0]const u8{ "jpg", "jpeg", "png", "gif", "bmp", "webp" }) |suffix| gtk.gtk_file_filter_add_suffix(filter, suffix);
    if (gtk.g_list_store_new(gtk.gtk_file_filter_get_type())) |filters| {
        gtk.g_list_store_append(filters, filter);
        gtk.gtk_file_dialog_set_filters(dialog, gtk.cast(gtk.ListModel, filters));
        gtk.g_object_unref(filters);
    }
    gtk.gtk_file_dialog_set_default_filter(dialog, filter);
    gtk.g_object_unref(filter);
    gtk.gtk_file_dialog_open(dialog, self.window, null, imageChosen, self);
    gtk.g_object_unref(dialog);
}

fn imageChosen(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const review = &self.artwork_review;
    const choice = review.choice orelse return;
    review.choice = null;
    var err: ?*gtk.GError = null;
    const file = gtk.gtk_file_dialog_open_finish(gtk.cast(gtk.FileDialog, source), result, &err) orelse {
        gtk.g_clear_error(&err);
        self.allocator.free(choice.releases);
        return;
    };
    const raw_path = gtk.g_file_get_path(file);
    gtk.g_object_unref(file);
    const path_pointer = raw_path orelse {
        self.allocator.free(choice.releases);
        return self.toast("That file is not on the local filesystem");
    };
    defer gtk.g_free(path_pointer);
    readImage(self, std.mem.span(path_pointer), choice);
}

fn readImage(self: *App, path: []const u8, choice: Choice) void {
    const review = &self.artwork_review;
    if (review.image_read != null) {
        self.allocator.free(choice.releases);
        return self.toast("Still reading the last image");
    }
    const path_copy = self.allocator.dupeSentinel(u8, path, 0) catch {
        self.allocator.free(choice.releases);
        return self.toast("Out of memory");
    };
    const read = self.allocator.create(ImageRead) catch {
        self.allocator.free(path_copy);
        self.allocator.free(choice.releases);
        return self.toast("Out of memory");
    };
    read.* = .{
        .allocator = self.allocator,
        .waker = self.waker(),
        .path = path_copy,
        .releases = choice.releases,
        .origin = choice.origin,
    };
    read.thread = std.Thread.spawn(.{}, ImageRead.run, .{read}) catch {
        read.destroy(self.allocator);
        return self.toast("Could not read the image");
    };
    review.image_read = read;
    syncControls(self);
}

fn tickImageRead(self: *App) void {
    const review = &self.artwork_review;
    const read = review.image_read orelse return;
    if (!read.finished.load(.acquire)) return;
    review.image_read = null;
    defer read.destroy(self.allocator);
    defer syncControls(self);
    const bytes = read.bytes orelse return self.toast(switch (read.failure) {
        .too_large => "That image is larger than 12 MB",
        .not_image => "That file is not a JPEG, PNG, GIF, BMP or WebP image",
        else => "Could not read the image",
    });
    const library = self.library orelse return;
    var kept: usize = 0;
    for (read.releases) |release_id| {
        self.runtime.librarySetReleaseArtwork(library, release_id, .front, bytes, read.mime) catch continue;
        kept += 1;
    }
    if (kept == 0) return self.toast("Could not keep the image as the cover");
    var buffer: [96]u8 = undefined;
    self.toast(if (read.releases.len == 1)
        "Kept the image as the album's cover"
    else
        strings.format(&buffer, "Kept the image as the cover of {d} albums", .{kept}));
    if (read.origin == .review and read.releases.len == 1 and review.detail_release == read.releases[0])
        moveOn(self, read.releases[0]);
    coverChanged(self, read.releases);
    if (read.origin == .editor) metadata_editor.coverChanged(self);
}
