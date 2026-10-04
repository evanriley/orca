//! A GObject row for the library list, registered by hand.
//!
//! `GtkColumnView` needs a `GListModel` of `GObject`s, and `GtkStringList`
//! cannot carry a Track id — a row that cannot name its Track cannot be
//! activated. Without `G_DECLARE_FINAL_TYPE` / `G_DEFINE_FINAL_TYPE` the type is
//! registered the way those macros do it: a `GTypeInfo` describing an instance
//! struct whose first field is the parent instance, a class init that installs
//! `finalize`, and a lazily-registered `GType`.
//!
//! The Zig-facing API hands over a `database.TrackSummary` with real optionals,
//! so a Track the library has no duration for is `null` here rather than a zero
//! paired with a `has_duration` flag. That distinction is what keeps an unknown
//! length rendering blank instead of `0:00`.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const strings = @import("strings.zig");

/// Owns every string a row holds. Set once from `main` before any row exists.
pub var allocator: std.mem.Allocator = undefined;

/// The Zig-native half of the instance. It lives inside the GObject allocation
/// rather than behind a pointer, but it cannot be a field of an `extern struct`
/// because optionals and slices are not C types — hence the aligned byte
/// storage and the accessor.
pub const Fields = struct {
    id: i64 = 0,
    duration_ms: ?i64 = null,
    track_number: ?i64 = null,
    disc_number: ?i64 = null,
    has_file: bool = false,
    feedback: liborca.Feedback = .none,
    rating: ?u8 = null,
    in_library: bool = true,
    placeholder: bool = false,
    recording_id: ?i64 = null,
    release_id: ?i64 = null,
    artist_id: ?i64 = null,
    title: [:0]u8 = &empty,
    artist: [:0]u8 = &empty,
    album: [:0]u8 = &empty,
    codec: [:0]u8 = &empty,
    sample_rate: ?u32 = null,
    bit_depth: ?u32 = null,
    lossy: bool = false,
    added_at: ?i64 = null,
    play_count: u64 = 0,
    last_played_at: ?i64 = null,
    explicit: bool = false,
    year: ?i32 = null,
    album_artist: [:0]u8 = &empty,
    genre: [:0]u8 = &empty,
    path: [:0]u8 = &empty,
    loudness: ?f32 = null,
    bitrate_kbps: ?u32 = null,
};

var empty: [0:0]u8 = .{};

pub const TrackObject = extern struct {
    parent: gtk.GObject,
    storage: [@sizeOf(Fields)]u8 align(@alignOf(Fields)),

    pub fn fields(self: *TrackObject) *Fields {
        return @ptrCast(&self.storage);
    }

    pub fn id(self: *TrackObject) i64 {
        return self.fields().id;
    }

    pub fn title(self: *TrackObject) [:0]const u8 {
        return self.fields().title;
    }

    pub fn artist(self: *TrackObject) [:0]const u8 {
        return self.fields().artist;
    }

    pub fn album(self: *TrackObject) [:0]const u8 {
        return self.fields().album;
    }

    pub fn hasFile(self: *TrackObject) bool {
        return self.fields().has_file;
    }

    pub fn feedback(self: *TrackObject) liborca.Feedback {
        return self.fields().feedback;
    }

    pub fn rating(self: *TrackObject) ?u8 {
        return self.fields().rating;
    }

    /// False for a playlist entry whose recording has no Track left.
    pub fn inLibrary(self: *TrackObject) bool {
        return self.fields().in_library;
    }

    pub fn recordingId(self: *TrackObject) ?i64 {
        return self.fields().recording_id;
    }

    pub fn releaseId(self: *TrackObject) ?i64 {
        return self.fields().release_id;
    }

    pub fn artistId(self: *TrackObject) ?i64 {
        return self.fields().artist_id;
    }

    /// Formatted for display. A Track with no known duration renders blank,
    /// never `0:00`.
    pub fn durationText(self: *TrackObject, buffer: []u8) [:0]const u8 {
        const duration = self.fields().duration_ms orelse return "";
        if (duration < 0) return "";
        // Unsigned on purpose: `{d:0>2}` renders a *signed* zero-padded value as
        // `+6` rather than `06`.
        return strings.formatMs(buffer, @intCast(duration));
    }

    pub fn numberText(self: *TrackObject, buffer: []u8) [:0]const u8 {
        const number = self.fields().track_number orelse return "";
        if (self.fields().disc_number) |disc| return strings.printZ(
            buffer,
            "{d}.{d}",
            .{ disc, number },
        ) catch "";
        return strings.printZ(buffer, "{d}", .{number}) catch "";
    }
};

var registered_type: gtk.GType = 0;
var parent_class: ?*gtk.GObjectClass = null;

pub fn getType() gtk.GType {
    if (registered_type != 0) return registered_type;
    const info: gtk.GTypeInfo = .{
        .class_size = @sizeOf(gtk.GObjectClass),
        .class_init = classInit,
        .instance_size = @sizeOf(TrackObject),
        .instance_init = instanceInit,
    };
    registered_type = gtk.g_type_register_static(
        gtk.g_object_get_type(),
        "OrcaTrackObject",
        &info,
        0,
    );
    return registered_type;
}

fn classInit(class: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(gtk.g_type_class_peek_parent(class)));
    const object_class: *gtk.GObjectClass = @ptrCast(@alignCast(class));
    object_class.finalize = finalize;
}

fn instanceInit(instance: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const self: *TrackObject = @ptrCast(@alignCast(instance));
    self.fields().* = .{};
}

fn finalize(object: *gtk.GObject) callconv(.c) void {
    const self: *TrackObject = @ptrCast(object);
    const values = self.fields();
    freeText(values.title);
    freeText(values.artist);
    freeText(values.album);
    freeText(values.codec);
    freeText(values.album_artist);
    freeText(values.genre);
    freeText(values.path);
    values.* = .{};
    if (parent_class) |parent| {
        if (parent.finalize) |chain| chain(object);
    }
}

fn freeText(text: [:0]u8) void {
    if (text.len == 0) return;
    allocator.free(text);
}

fn dupe(text: []const u8) [:0]u8 {
    if (text.len == 0) return &empty;
    return allocator.dupeSentinel(u8, text, 0) catch &empty;
}

/// Copies everything out of the summary: the page that produced it is
/// caller-owned and is released as soon as the page has been appended.
pub fn new(summary: liborca.TrackSummary) ?*TrackObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const self: *TrackObject = @ptrCast(object);
    const values = self.fields();
    values.id = summary.id;
    values.duration_ms = summary.duration_ms;
    values.track_number = summary.track_number;
    values.disc_number = summary.disc_number;
    values.has_file = summary.has_playable_file;
    values.feedback = summary.feedback;
    values.rating = summary.rating;
    values.recording_id = summary.recording_id;
    values.release_id = summary.release_id;
    values.artist_id = summary.artist_id;
    values.title = dupe(summary.title);
    // Track artist first; the release artist is the fallback a browser wants.
    values.artist = dupe(if (summary.artist.len != 0) summary.artist else summary.album_artist);
    values.album = dupe(summary.album);
    values.codec = dupe(summary.codec);
    values.sample_rate = summary.sample_rate;
    values.bit_depth = summary.bit_depth;
    values.lossy = summary.lossy;
    values.added_at = summary.added_at;
    values.play_count = summary.play_count;
    values.last_played_at = summary.last_played_at;
    values.explicit = summary.explicit == .explicit;
    values.year = summary.year;
    values.album_artist = dupe(summary.album_artist);
    values.genre = dupe(summary.genre);
    values.path = dupe(summary.path);
    values.loudness = summary.integrated_lufs;
    values.bitrate_kbps = summary.bitrate_kbps;
    return self;
}

/// A playlist entry whose recording has no Track: listed, never played.
pub fn unavailable(recording_id: i64) ?*TrackObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const self: *TrackObject = @ptrCast(object);
    self.fields().in_library = false;
    self.fields().recording_id = recording_id;
    self.fields().title = dupe("Not in your library");
    return self;
}

/// What changed about a recording, applied to every row that shows it.
pub const Change = union(enum) {
    feedback: liborca.Feedback,
    rating: ?u8,

    /// Sets the value on `fields`; false when it already had it.
    pub fn apply(self: Change, fields: *Fields) bool {
        switch (self) {
            .feedback => |value| {
                if (fields.feedback == value) return false;
                fields.feedback = value;
            },
            .rating => |value| {
                if (std.meta.eql(fields.rating, value)) return false;
                fields.rating = value;
            },
        }
        return true;
    }
};

/// A second object with the same fields. A list view reuses the widget of an
/// item it already shows, so swapping in a copy is how a row is made to bind
/// again when only its presentation changed.
pub fn clone(source: *TrackObject) ?*TrackObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const self: *TrackObject = @ptrCast(object);
    const from = source.fields();
    self.fields().* = from.*;
    self.fields().title = dupe(from.title);
    self.fields().artist = dupe(from.artist);
    self.fields().album = dupe(from.album);
    self.fields().codec = dupe(from.codec);
    self.fields().album_artist = dupe(from.album_artist);
    self.fields().genre = dupe(from.genre);
    self.fields().path = dupe(from.path);
    return self;
}

/// The columns the track list shows, and the engine sort key behind each one.
///
/// A header click re-queries liborca with that key and starts again at the
/// first page. Nothing here reorders rows that are already loaded: a page is a
/// window onto a total order the engine owns, and sorting the window would sort
/// a screenful of a listing that is thousands of rows long.
pub const Column = enum {
    number,
    title,
    artist,
    album,
    loved,
    rating,
    date_added,
    year,
    last_played,
    plays,
    duration,
    format,
    codec,
    rate_depth,
    album_artist,
    genre,
    bitrate,
    loudness,
    path,
    more,

    pub const all = std.enums.values(Column);

    pub fn sortKey(self: Column) ?liborca.TrackSort {
        return switch (self) {
            .number => .track_number,
            .title => .title,
            .artist => .artist,
            .album => .album,
            .loved => .loved,
            .rating => .rating,
            .date_added => .date_added,
            .year => .year,
            .last_played => .last_played,
            .plays => .play_count,
            .duration => .duration,
            .album_artist => .album_artist,
            .genre => .genre,
            .bitrate => .bitrate,
            .loudness => .loudness,
            .path => .path,
            .format, .codec, .rate_depth, .more => null,
        };
    }
};

/// A sorter that makes every row equal.
///
/// `GtkColumnView` treats a column with no sorter as unsortable and refuses to
/// let its header be clicked, and the click is the whole point — it is what
/// tells the frontend which key to re-query with. No sort model consumes this,
/// so it is never actually asked to compare anything.
pub fn headerSorter() *gtk.Sorter {
    return gtk.gtk_custom_sorter_new(null, null, null);
}

pub const page_rows = 512;
const cached_pages = 8;

/// What became of asking the engine for a page.
pub const Requested = union(enum) {
    issued: u64,
    /// The loader is full; the page is asked for again by `retryWaiting`.
    busy,
    failed,
};

/// Asks the engine for up to `limit` rows from `offset`; the rows arrive
/// later through `pageArrived` under the returned request id.
pub const Source = struct {
    context: *anyopaque,
    request: *const fn (context: *anyopaque, offset: u32, limit: u32) Requested,
    cancel: *const fn (context: *anyopaque, request: u64) void,
};

const Load = union(enum) {
    waiting,
    pending: u64,
    loaded,
    failed,
};

/// The row a `PagedModel` shows at a position whose page has not arrived.
/// It is not in the library, so nothing plays, rates or loves it.
fn placeholder() ?*TrackObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const row: *TrackObject = @ptrCast(object);
    row.fields().in_library = false;
    row.fields().placeholder = true;
    return row;
}

pub fn isPlaceholder(row: *TrackObject) bool {
    return row.fields().placeholder;
}

const TrackRows = struct {
    pub const Row = TrackObject;
    pub const Page = liborca.TrackPage;
    pub const type_name = "OrcaPagedTrackModel";
    pub const itemType = getType;
    pub const empty = placeholder;

    pub fn fromItem(item: *const liborca.TrackSummary) ?*TrackObject {
        return new(item.*);
    }
};

pub const PagedModel = Paged(TrackRows);

pub fn newPagedModel() ?*PagedModel {
    return PagedModel.create();
}

/// A `GListModel` of `Rows.Row`s over a listing the engine pages: it knows
/// only the listing's length, and asks for a 512-row page when GTK asks for
/// a row it has not cached, keeping the few pages used most recently.
/// Until a page arrives each of its rows is `Rows.empty()`.
pub fn Paged(comptime Rows: type) type {
    const Row = Rows.Row;

    const CachedPage = struct {
        index: u32 = 0,
        used: u64 = 0,
        load: Load = .waiting,
        count: u32 = 0,
        rows: []?*Row = &.{},
    };

    const PagedState = struct {
        source: ?Source = null,
        count: u32 = 0,
        clock: u64 = 0,
        pages: [cached_pages]CachedPage = @splat(.{}),
    };

    return extern struct {
        parent: gtk.GObject,
        storage: [@sizeOf(PagedState)]u8 align(@alignOf(PagedState)),

        const Self = @This();

        var model_type: gtk.GType = 0;
        var paged_parent_class: ?*gtk.GObjectClass = null;

        pub fn create() ?*Self {
            const object = gtk.g_object_new_with_properties(modelType(), 0, null, null) orelse return null;
            return @ptrCast(object);
        }

        fn paged(self: *Self) *PagedState {
            return @ptrCast(&self.storage);
        }

        pub fn setSource(self: *Self, source: Source) void {
            self.paged().source = source;
        }

        pub fn count(self: *Self) u32 {
            return self.paged().count;
        }

        /// Forgets every cached row, cancelling the pages still being read, and
        /// reports the listing as `length` new rows.
        pub fn reset(self: *Self, length: u32) void {
            const values = self.paged();
            const removed = values.count;
            dropPages(values);
            // One signal that both removes and adds makes GtkListItemManager and
            // GtkMultiSelection fetch every added row to find their tracked rows
            // again, which reads the whole listing a page at a time.
            values.count = 0;
            if (removed != 0) gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), 0, removed, 0);
            values.count = length;
            if (length != 0) gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), 0, 0, length);
        }

        /// Changes the listing's length at its end only, keeping the pages
        /// already asked for: they were asked for under the same listing.
        pub fn resize(self: *Self, length: u32) void {
            const values = self.paged();
            const previous = values.count;
            values.count = length;
            if (length > previous)
                gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), previous, 0, length - previous)
            else if (length < previous)
                gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), length, previous - length, 0);
        }

        /// Fills the page `request` was issued for and reports its rows as
        /// changed. A result no page is waiting for is ignored.
        pub fn pageArrived(self: *Self, request: u64, page: Rows.Page) void {
            const values = self.paged();
            const cached = pendingPage(values, request) orelse return;
            var made: u32 = 0;
            for (page.items[0..@min(page.items.len, cached.rows.len)]) |*item| {
                const row = Rows.fromItem(item) orelse break;
                if (cached.rows[made]) |shown| gtk.g_object_unref(shown);
                cached.rows[made] = row;
                made += 1;
            }
            cached.count = made;
            cached.load = .loaded;
            const first = cached.index * page_rows;
            if (first >= values.count) return;
            const changed = @min(made, values.count - first);
            if (changed != 0) gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), first, changed, changed);
        }

        /// Leaves the page `request` was issued for showing placeholders until
        /// it is evicted or the listing is reset. False when no page waits for it.
        pub fn pageFailed(self: *Self, request: u64) bool {
            const cached = pendingPage(self.paged(), request) orelse return false;
            cached.load = .failed;
            return true;
        }

        /// Asks again for the pages the loader was too full to take. Returns
        /// whether any is still waiting.
        pub fn retryWaiting(self: *Self) bool {
            const values = self.paged();
            var waiting = false;
            for (&values.pages) |*page| {
                if (page.used == 0 or page.load != .waiting) continue;
                requestPage(values, page);
                if (page.load == .waiting) waiting = true;
            }
            return waiting;
        }

        /// Offers every cached row to `replace`, and swaps in the row it returns.
        /// Rows not cached are fetched fresh when next shown, so they need no
        /// update. Returns whether any row changed.
        pub fn update(
            self: *Self,
            context: anytype,
            comptime replace: fn (@TypeOf(context), *Row) ?*Row,
        ) bool {
            const values = self.paged();
            var changed = false;
            for (&values.pages) |*page| {
                if (page.used == 0 or page.load != .loaded) continue;
                for (page.rows[0..page.count], 0..) |*slot, index| {
                    const row = slot.* orelse continue;
                    const fresh = replace(context, row) orelse continue;
                    gtk.g_object_unref(row);
                    slot.* = fresh;
                    const position = page.index * page_rows + @as(u32, @intCast(index));
                    gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), position, 1, 1);
                    changed = true;
                }
            }
            return changed;
        }

        fn pendingPage(values: *PagedState, request: u64) ?*CachedPage {
            for (&values.pages) |*page| {
                if (page.used == 0) continue;
                switch (page.load) {
                    .pending => |id| if (id == request) return page,
                    else => {},
                }
            }
            return null;
        }

        fn requestPage(values: *PagedState, page: *CachedPage) void {
            const source = values.source orelse return;
            page.load = switch (source.request(source.context, page.index * page_rows, page_rows)) {
                .issued => |id| .{ .pending = id },
                .busy => .waiting,
                .failed => .failed,
            };
        }

        fn clearPage(values: *PagedState, page: *CachedPage) void {
            switch (page.load) {
                .pending => |id| if (values.source) |source| source.cancel(source.context, id),
                else => {},
            }
            for (page.rows) |*row| if (row.*) |object| {
                gtk.g_object_unref(object);
                row.* = null;
            };
            page.load = .waiting;
            page.count = 0;
        }

        fn dropPages(values: *PagedState) void {
            for (&values.pages) |*page| {
                clearPage(values, page);
                if (page.rows.len != 0) allocator.free(page.rows);
                page.* = .{};
            }
        }

        fn cachedPage(values: *PagedState, index: u32) ?*CachedPage {
            values.clock += 1;
            var oldest = &values.pages[0];
            for (&values.pages) |*page| {
                if (page.used != 0 and page.index == index) {
                    page.used = values.clock;
                    return page;
                }
                if (page.used < oldest.used) oldest = page;
            }
            if (values.source == null) return null;
            if (oldest.rows.len == 0) {
                oldest.rows = allocator.alloc(?*Row, page_rows) catch return null;
                @memset(oldest.rows, null);
            }
            clearPage(values, oldest);
            oldest.index = index;
            oldest.used = values.clock;
            requestPage(values, oldest);
            return oldest;
        }

        fn modelType() gtk.GType {
            if (model_type != 0) return model_type;
            const info: gtk.GTypeInfo = .{
                .class_size = @sizeOf(gtk.GObjectClass),
                .class_init = pagedClassInit,
                .instance_size = @sizeOf(Self),
                .instance_init = pagedInstanceInit,
            };
            model_type = gtk.g_type_register_static(gtk.g_object_get_type(), Rows.type_name, &info, 0);
            const interface: gtk.GInterfaceInfo = .{ .interface_init = listInit };
            gtk.g_type_add_interface_static(model_type, gtk.g_list_model_get_type(), &interface);
            return model_type;
        }

        fn pagedClassInit(class: *anyopaque, _: ?*anyopaque) callconv(.c) void {
            paged_parent_class = @ptrCast(@alignCast(gtk.g_type_class_peek_parent(class)));
            const object_class: *gtk.GObjectClass = @ptrCast(@alignCast(class));
            object_class.finalize = pagedFinalize;
        }

        fn pagedInstanceInit(instance: *anyopaque, _: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(instance));
            self.paged().* = .{};
        }

        fn pagedFinalize(object: *gtk.GObject) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(object));
            self.paged().source = null;
            dropPages(self.paged());
            if (paged_parent_class) |parent| {
                if (parent.finalize) |chain| chain(object);
            }
        }

        fn listInit(interface: *anyopaque, _: ?*anyopaque) callconv(.c) void {
            const methods: *gtk.ListModelInterface = @ptrCast(@alignCast(interface));
            methods.get_item_type = itemType;
            methods.get_n_items = itemCount;
            methods.get_item = itemAt;
        }

        fn itemType(_: *gtk.ListModel) callconv(.c) gtk.GType {
            return Rows.itemType();
        }

        fn itemCount(list: *gtk.ListModel) callconv(.c) c_uint {
            const self: *Self = @ptrCast(@alignCast(list));
            return self.paged().count;
        }

        fn itemAt(list: *gtk.ListModel, position: c_uint) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(list));
            const values = self.paged();
            if (position >= values.count) return null;
            const index = position % page_rows;
            // GtkListItemManager tells rows apart by object, so every position needs
            // its own placeholder: one shared object is a duplicate item to it.
            const page = cachedPage(values, position / page_rows) orelse return Rows.empty();
            if (page.rows[index] == null) page.rows[index] = Rows.empty();
            return gtk.g_object_ref(page.rows[index] orelse return null);
        }
    };
}
