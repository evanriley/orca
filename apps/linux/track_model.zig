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
    recording_id: ?i64 = null,
    release_id: ?i64 = null,
    artist_id: ?i64 = null,
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
    return self;
}

/// The columns the track list shows, and the engine sort key behind each one.
///
/// A header click re-queries liborca with that key and starts again at the
/// first page. Nothing here reorders rows that are already loaded: a page is a
/// window onto a total order the engine owns, and sorting the window would sort
/// a screenful of a listing that is thousands of rows long.
pub const Column = enum(usize) {
    // Carried as the cell factory's user-data pointer, so zero — which is NULL
    // — is not an available value.
    number = 1,
    title,
    rating,
    artist,
    album,
    duration,

    /// Declaration order, which is also the order the headers appear in and the
    /// order `App.sort_columns` records them in.
    pub const all = [_]Column{ .number, .title, .rating, .artist, .album, .duration };

    pub fn sortKey(self: Column) liborca.TrackSort {
        return switch (self) {
            .number => .track_number,
            .title => .title,
            .rating => .rating,
            .artist => .artist,
            .album => .album,
            .duration => .duration,
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
