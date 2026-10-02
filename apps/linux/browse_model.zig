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
