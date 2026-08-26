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
    title: [:0]u8 = &empty,
    artist: [:0]u8 = &empty,
    album: [:0]u8 = &empty,
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
pub fn new(summary: liborca.database.TrackSummary) ?*TrackObject {
    const object = gtk.g_object_new_with_properties(getType(), 0, null, null) orelse return null;
    const self: *TrackObject = @ptrCast(object);
    const values = self.fields();
    values.id = summary.id;
    values.duration_ms = summary.duration_ms;
    values.track_number = summary.track_number;
    values.disc_number = summary.disc_number;
    values.has_file = summary.has_playable_file;
    values.title = dupe(summary.title);
    // Track artist first; the release artist is the fallback a browser wants.
    values.artist = dupe(if (summary.artist.len != 0) summary.artist else summary.album_artist);
    values.album = dupe(summary.album);
    return self;
}

// ---------------------------------------------------------------- sorting
//
// These sort the rows currently loaded. `libraryTrackPage` orders by Track id
// and takes no sort key, so column sorting is page-local by construction.

fn compareOptional(left: ?i64, right: ?i64) c_int {
    const a = left orelse return if (right == null) 0 else 1;
    const b = right orelse return -1;
    if (a < b) return -1;
    return if (a > b) 1 else 0;
}

fn compareText(left: [:0]const u8, right: [:0]const u8) c_int {
    // Empty sorts last so unknown values do not head the list.
    if (left.len == 0 and right.len != 0) return 1;
    if (right.len == 0 and left.len != 0) return -1;
    return gtk.g_utf8_collate(left.ptr, right.ptr);
}

fn rows(a: ?*const anyopaque, b: ?*const anyopaque) struct { *TrackObject, *TrackObject } {
    return .{
        @ptrCast(@alignCast(@constCast(a.?))),
        @ptrCast(@alignCast(@constCast(b.?))),
    };
}

fn compareTitle(a: ?*const anyopaque, b: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const pair = rows(a, b);
    return compareText(pair[0].title(), pair[1].title());
}

fn compareArtist(a: ?*const anyopaque, b: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const pair = rows(a, b);
    return compareText(pair[0].artist(), pair[1].artist());
}

fn compareAlbum(a: ?*const anyopaque, b: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const pair = rows(a, b);
    return compareText(pair[0].album(), pair[1].album());
}

fn compareDuration(a: ?*const anyopaque, b: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const pair = rows(a, b);
    return compareOptional(pair[0].fields().duration_ms, pair[1].fields().duration_ms);
}

fn compareNumber(a: ?*const anyopaque, b: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const pair = rows(a, b);
    const discs = compareOptional(
        pair[0].fields().disc_number orelse 0,
        pair[1].fields().disc_number orelse 0,
    );
    if (discs != 0) return discs;
    return compareOptional(pair[0].fields().track_number, pair[1].fields().track_number);
}

pub fn sorterTitle() *gtk.Sorter {
    return gtk.gtk_custom_sorter_new(compareTitle, null, null);
}
pub fn sorterArtist() *gtk.Sorter {
    return gtk.gtk_custom_sorter_new(compareArtist, null, null);
}
pub fn sorterAlbum() *gtk.Sorter {
    return gtk.gtk_custom_sorter_new(compareAlbum, null, null);
}
pub fn sorterDuration() *gtk.Sorter {
    return gtk.gtk_custom_sorter_new(compareDuration, null, null);
}
pub fn sorterNumber() *gtk.Sorter {
    return gtk.gtk_custom_sorter_new(compareNumber, null, null);
}
