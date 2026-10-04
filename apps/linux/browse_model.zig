//! A GObject row for the Artist and Release browse panes, registered by hand.
//!
//! Artists and Releases are different questions to liborca and identical to
//! GTK: a row that shows a name, a line of detail, and carries the id the next
//! query is scoped by. One type serves both panes, which is why the id is
//! optional — the first row of each pane is the unscoped "All" entry, and an
//! absent id is exactly what "no filter" means to a `TrackQuery`.
//!
//! Registration follows `track_model.zig`: `G_DECLARE_FINAL_TYPE` and
//! `G_DEFINE_FINAL_TYPE` do not exist without the C preprocessor, so the
//! `GTypeInfo`, the class init that installs `finalize`, and the lazily
//! registered `GType` are written out.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");

/// Owns every string a row holds. Set once from `main` before any row exists.
pub var allocator: std.mem.Allocator = undefined;

/// The Zig-native half of the instance, kept out of the `extern struct` for the
/// same reason `track_model.Fields` is: an optional is not a C type.
pub const Fields = struct {
    /// The Artist or Release this row scopes the track query to. `null` is the
    /// "All" row, and it is a filter of none rather than an id of zero.
    id: ?i64 = null,
    name: [:0]u8 = &empty,
    detail: [:0]u8 = &empty,
    caption: [:0]u8 = &empty,
    release: Release = .{},
    artist: Artist = .{},
    section: ?SectionRow = null,
    placeholder: bool = false,
};

pub const Artist = struct {
    has_photo: bool = false,
    cover_release_id: ?i64 = null,
    release_count: u32 = 0,
};

/// What an Albums list row or tile shows beyond its name, artist and year.
pub const Release = struct {
    format: [:0]u8 = &empty,
    track_count: u32 = 0,
    duration_ms: i64 = 0,
    loved: bool = false,
    explicit: bool = false,
};

var empty: [0:0]u8 = .{};

pub const BrowseObject = extern struct {
    parent: gtk.GObject,
    storage: [@sizeOf(Fields)]u8 align(@alignOf(Fields)),

    pub fn fields(self: *BrowseObject) *Fields {
        return @ptrCast(&self.storage);
    }

    pub fn id(self: *BrowseObject) ?i64 {
        return self.fields().id;
    }

    pub fn name(self: *BrowseObject) [:0]const u8 {
        return self.fields().name;
    }

    pub fn detail(self: *BrowseObject) [:0]const u8 {
        return self.fields().detail;
    }

    pub fn caption(self: *BrowseObject) [:0]const u8 {
        return self.fields().caption;
    }

    pub fn release(self: *BrowseObject) *const Release {
        return &self.fields().release;
    }

    pub fn artist(self: *BrowseObject) *const Artist {
        return &self.fields().artist;
    }

    pub fn section(self: *BrowseObject) ?SectionRow {
        return self.fields().section;
    }

    pub fn isPlaceholder(self: *BrowseObject) bool {
        return self.fields().placeholder;
    }
};

var registered_type: gtk.GType = 0;
var parent_class: ?*gtk.GObjectClass = null;

pub fn getType() gtk.GType {
    if (registered_type != 0) return registered_type;
    const info: gtk.GTypeInfo = .{
        .class_size = @sizeOf(gtk.GObjectClass),
        .class_init = classInit,
        .instance_size = @sizeOf(BrowseObject),
        .instance_init = instanceInit,
    };
    registered_type = gtk.g_type_register_static(
        gtk.g_object_get_type(),
        "OrcaBrowseObject",
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
    const self: *BrowseObject = @ptrCast(@alignCast(instance));
    self.fields().* = .{};
}

fn finalize(object: *gtk.GObject) callconv(.c) void {
    const self: *BrowseObject = @ptrCast(object);
    const values = self.fields();
    freeText(values.name);
    freeText(values.detail);
    freeText(values.caption);
    freeText(values.release.format);
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

/// Copies the strings: the page they came from is caller-owned and is released
/// as soon as it has been appended to the store.
pub fn new(id: ?i64, name: []const u8, detail: []const u8) ?*BrowseObject {
    return newWithCaption(id, name, detail, "");
}

pub fn newWithCaption(id: ?i64, name: []const u8, detail: []const u8, caption: []const u8) ?*BrowseObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const self: *BrowseObject = @ptrCast(object);
    const values = self.fields();
    values.id = id;
    values.name = dupe(name);
    values.detail = dupe(detail);
    values.caption = dupe(caption);
    return self;
}

pub fn newArtist(id: i64, name: []const u8, detail: []const u8, artist: Artist) ?*BrowseObject {
    const self = new(id, name, detail) orelse return null;
    self.fields().artist = artist;
    return self;
}

/// `format` is copied like the other strings and replaces `release.format`.
pub fn newRelease(id: i64, name: []const u8, detail: []const u8, caption: []const u8, format: []const u8, release: Release) ?*BrowseObject {
    const self = newWithCaption(id, name, detail, caption) orelse return null;
    const values = self.fields();
    values.release = release;
    values.release.format = dupe(format);
    return self;
}

/// A copy of a Release row with `loved` set: a list view binds a row again
/// only when its object changes.
pub fn releaseWithLove(source: *BrowseObject, loved: bool) ?*BrowseObject {
    var release = source.release().*;
    release.loved = loved;
    return newRelease(source.id() orelse return null, source.name(), source.detail(), source.caption(), release.format, release);
}

pub fn releasePlaceholder() ?*BrowseObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const self: *BrowseObject = @ptrCast(object);
    self.fields().placeholder = true;
    return self;
}

pub const SectionRow = union(enum) {
    header: usize,
    tiles: Tiles,

    pub const Tiles = struct {
        bucket: usize,
        offset: u64,
        count: u32,
    };
};

fn tileRows(bucket: liborca.LetterBucket, columns: u32) u64 {
    return std.math.divCeil(u64, bucket.count, columns) catch 0;
}

pub fn sectionRowCount(buckets: []const liborca.LetterBucket, columns: u32) u32 {
    var rows: u64 = 0;
    for (buckets) |bucket| rows += 1 + tileRows(bucket, @max(columns, 1));
    return @intCast(@min(rows, std.math.maxInt(u32)));
}

pub fn sectionRowAt(buckets: []const liborca.LetterBucket, columns: u32, position: u32) ?SectionRow {
    const width = @max(columns, 1);
    var start: u64 = 0;
    for (buckets, 0..) |bucket, index| {
        if (position == start) return .{ .header = index };
        const rows = tileRows(bucket, width);
        if (position <= start + rows) {
            const row = position - start - 1;
            const offset = row * width;
            return .{ .tiles = .{
                .bucket = index,
                .offset = bucket.first_offset + offset,
                .count = @intCast(@min(width, bucket.count - offset)),
            } };
        }
        start += 1 + rows;
    }
    return null;
}

pub fn sectionHeaderPosition(buckets: []const liborca.LetterBucket, columns: u32, bucket: usize) u32 {
    var position: u64 = 0;
    for (buckets[0..@min(bucket, buckets.len)]) |before| position += 1 + tileRows(before, @max(columns, 1));
    return @intCast(@min(position, std.math.maxInt(u32)));
}

/// A `GListModel` of `SectionRow`s over borrowed letter buckets, registered
/// by hand like `BrowseObject`. Rows are made when GTK asks for them, so the
/// model holds nothing per Release.
pub const SectionModel = extern struct {
    parent: gtk.GObject,
    storage: [@sizeOf(SectionState)]u8 align(@alignOf(SectionState)),

    fn sections(self: *SectionModel) *SectionState {
        return @ptrCast(&self.storage);
    }

    /// `buckets` must outlive the model or the next call.
    pub fn set(self: *SectionModel, buckets: []const liborca.LetterBucket, width: u32) void {
        const values = self.sections();
        const removed = values.count;
        values.* = .{ .buckets = buckets, .columns = @max(width, 1) };
        values.count = sectionRowCount(buckets, values.columns);
        if (removed != 0 or values.count != 0)
            gtk.g_list_model_items_changed(gtk.cast(gtk.ListModel, self), 0, removed, values.count);
    }

    pub fn columns(self: *SectionModel) u32 {
        return self.sections().columns;
    }
};

const SectionState = struct {
    buckets: []const liborca.LetterBucket = &.{},
    columns: u32 = 1,
    count: u32 = 0,
};

var section_model_type: gtk.GType = 0;

pub fn newSectionModel() ?*SectionModel {
    const object = gtk.g_object_new_with_properties(sectionModelType(), 0, null, null) orelse return null;
    return @ptrCast(object);
}

fn sectionModelType() gtk.GType {
    if (section_model_type != 0) return section_model_type;
    const info: gtk.GTypeInfo = .{
        .class_size = @sizeOf(gtk.GObjectClass),
        .instance_size = @sizeOf(SectionModel),
        .instance_init = sectionModelInit,
    };
    section_model_type = gtk.g_type_register_static(gtk.g_object_get_type(), "OrcaSectionModel", &info, 0);
    const interface: gtk.GInterfaceInfo = .{ .interface_init = listModelInit };
    gtk.g_type_add_interface_static(section_model_type, gtk.g_list_model_get_type(), &interface);
    return section_model_type;
}

fn sectionModelInit(instance: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const self: *SectionModel = @ptrCast(@alignCast(instance));
    self.sections().* = .{};
}

fn listModelInit(interface: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const methods: *gtk.ListModelInterface = @ptrCast(@alignCast(interface));
    methods.get_item_type = sectionItemType;
    methods.get_n_items = sectionCount;
    methods.get_item = sectionItem;
}

fn sectionItemType(_: *gtk.ListModel) callconv(.c) gtk.GType {
    return getType();
}

fn sectionCount(list: *gtk.ListModel) callconv(.c) c_uint {
    const self: *SectionModel = @ptrCast(@alignCast(list));
    return self.sections().count;
}

fn sectionItem(list: *gtk.ListModel, position: c_uint) callconv(.c) ?*anyopaque {
    const self: *SectionModel = @ptrCast(@alignCast(list));
    const values = self.sections();
    if (position >= values.count) return null;
    const row = sectionRowAt(values.buckets, values.columns, position) orelse return null;
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const item: *BrowseObject = @ptrCast(object);
    item.fields().section = row;
    return item;
}

test "a letter's rows follow its header, columns to a row" {
    const buckets = [_]liborca.LetterBucket{
        .{ .letter = '#', .count = 2, .first_offset = 0 },
        .{ .letter = 'A', .count = 7, .first_offset = 2 },
        .{ .letter = 'K', .count = 3, .first_offset = 9 },
    };
    try std.testing.expectEqual(@as(u32, 2 + 4 + 2), sectionRowCount(&buckets, 3));
    try std.testing.expectEqual(SectionRow{ .header = 0 }, sectionRowAt(&buckets, 3, 0).?);
    try std.testing.expectEqual(SectionRow{ .tiles = .{ .bucket = 0, .offset = 0, .count = 2 } }, sectionRowAt(&buckets, 3, 1).?);
    try std.testing.expectEqual(SectionRow{ .header = 1 }, sectionRowAt(&buckets, 3, 2).?);
    try std.testing.expectEqual(SectionRow{ .tiles = .{ .bucket = 1, .offset = 8, .count = 1 } }, sectionRowAt(&buckets, 3, 5).?);
    try std.testing.expectEqual(SectionRow{ .header = 2 }, sectionRowAt(&buckets, 3, 6).?);
    try std.testing.expectEqual(SectionRow{ .tiles = .{ .bucket = 2, .offset = 9, .count = 3 } }, sectionRowAt(&buckets, 3, 7).?);
    try std.testing.expectEqual(@as(?SectionRow, null), sectionRowAt(&buckets, 3, 8));
}

test "a letter's header is found by position and its last row holds the remainder" {
    const buckets = [_]liborca.LetterBucket{
        .{ .letter = 'A', .count = 10, .first_offset = 0 },
        .{ .letter = 'K', .count = 4, .first_offset = 10 },
    };
    try std.testing.expectEqual(@as(u32, 0), sectionHeaderPosition(&buckets, 4, 0));
    try std.testing.expectEqual(@as(u32, 4), sectionHeaderPosition(&buckets, 4, 1));
    try std.testing.expectEqual(SectionRow{ .tiles = .{ .bucket = 0, .offset = 8, .count = 2 } }, sectionRowAt(&buckets, 4, 3).?);
    try std.testing.expectEqual(SectionRow{ .tiles = .{ .bucket = 1, .offset = 10, .count = 4 } }, sectionRowAt(&buckets, 4, 5).?);
}
