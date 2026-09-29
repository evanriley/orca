//! Provider credentials in the desktop's Secret Service, through libsecret:
//! the ListenBrainz user token and the AcoustID user key, each under the
//! service and account liborca asks for. They live nowhere else: not in
//! `settings.ini`, not in the Library.
//!
//! libsecret is LGPL, so it is linked into this frontend only. Workers read a
//! credential through `credential_store` with a synchronous search that never
//! unlocks the keyring, so a locked one reads as no credential and no prompt
//! appears from their threads; saving, clearing and checking whether one is
//! stored are asynchronous and run on the main loop, where a prompt is
//! acceptable.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");

const SchemaAttribute = extern struct {
    name: ?[*:0]const u8,
    attribute_type: c_int,
};

const Schema = extern struct {
    name: [*:0]const u8,
    flags: c_int,
    attributes: [32]SchemaAttribute,
    reserved: c_int = 0,
    reserved_pointers: [7]?*anyopaque = @splat(null),
};

const attribute_string: c_int = 0;
const schema_flags_none: c_int = 0;

const schema: Schema = .{
    .name = "org.orca.ListenBrainz",
    .flags = schema_flags_none,
    .attributes = attributes: {
        var list: [32]SchemaAttribute = @splat(.{ .name = null, .attribute_type = attribute_string });
        list[0] = .{ .name = "service", .attribute_type = attribute_string };
        list[1] = .{ .name = "account", .attribute_type = attribute_string };
        break :attributes list;
    },
};

const GList = extern struct {
    data: ?*anyopaque,
    next: ?*GList,
    prev: ?*GList,
};
const GHashTable = opaque {};
const SecretValue = opaque {};

const search_all: c_uint = 1 << 1;
const search_load_secrets: c_uint = 1 << 3;

extern fn g_str_hash(value: ?*const anyopaque) c_uint;
extern fn g_str_equal(a: ?*const anyopaque, b: ?*const anyopaque) c_int;
extern fn g_hash_table_new(hash: *const fn (?*const anyopaque) callconv(.c) c_uint, equal: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) *GHashTable;
extern fn g_hash_table_insert(table: *GHashTable, key: ?*anyopaque, value: ?*anyopaque) c_int;
extern fn g_hash_table_unref(table: *GHashTable) void;
extern fn g_list_free_full(list: ?*GList, free_func: *const fn (?*anyopaque) callconv(.c) void) void;
extern fn secret_service_search_sync(service: ?*anyopaque, schema: *const Schema, attributes: *GHashTable, flags: c_uint, cancellable: ?*anyopaque, err: *?*gtk.GError) ?*GList;
extern fn secret_service_search(service: ?*anyopaque, schema: *const Schema, attributes: *GHashTable, flags: c_uint, cancellable: ?*gtk.GCancellable, callback: *const AsyncReady, user_data: ?*anyopaque) void;
extern fn secret_service_search_finish(service: ?*anyopaque, result: *gtk.GAsyncResult, err: *?*gtk.GError) ?*GList;
extern fn secret_service_unlock(service: ?*anyopaque, objects: ?*GList, cancellable: ?*gtk.GCancellable, callback: *const AsyncReady, user_data: ?*anyopaque) void;
extern fn secret_service_unlock_finish(service: ?*anyopaque, result: *gtk.GAsyncResult, unlocked: ?*?*GList, err: *?*gtk.GError) c_int;
extern fn secret_item_get_locked(item: *anyopaque) c_int;
extern fn secret_item_get_secret(item: *anyopaque) ?*SecretValue;
extern fn secret_value_get_text(value: *SecretValue) ?[*:0]const u8;
extern fn secret_value_unref(value: *SecretValue) void;
pub const Completion = *const fn (succeeded: bool, data: ?*anyopaque) void;

pub const Presence = enum { absent, stored, locked, unavailable };
pub const LockedItems = enum { unlock, report };
pub const PresenceCompletion = *const fn (presence: Presence, data: ?*anyopaque) void;

const Pending = struct {
    completion: Completion,
    data: ?*anyopaque,
};

extern fn secret_password_store(schema: *const Schema, collection: [*:0]const u8, label: [*:0]const u8, password: [*:0]const u8, cancellable: ?*gtk.GCancellable, callback: *const AsyncReady, user_data: ?*anyopaque, ...) void;
extern fn secret_password_store_finish(result: *gtk.GAsyncResult, err: *?*gtk.GError) gtk.gboolean;
extern fn secret_password_clear(schema: *const Schema, cancellable: ?*gtk.GCancellable, callback: *const AsyncReady, user_data: ?*anyopaque, ...) void;
extern fn secret_password_clear_finish(result: *gtk.GAsyncResult, err: *?*gtk.GError) gtk.gboolean;

const PendingPresence = struct {
    completion: PresenceCompletion,
    data: ?*anyopaque,
    names: Names,
    locked_items: LockedItems,
    items: ?*GList = null,
};

const default_collection = "default";
const name_capacity = 128;

const Names = struct {
    service: [name_capacity:0]u8,
    account: [name_capacity:0]u8,

    fn init(service: []const u8, account: []const u8) error{NameTooLong}!Names {
        var names: Names = undefined;
        inline for (.{ "service", "account" }, .{ service, account }) |field, value| {
            if (value.len >= name_capacity) return error.NameTooLong;
            @memcpy(@field(names, field)[0..value.len], value);
            @field(names, field)[value.len] = 0;
        }
        return names;
    }
};

fn lookup(allocator: std.mem.Allocator, service: []const u8, account: []const u8) anyerror!?[]u8 {
    var names = try Names.init(service, account);
    const attributes = g_hash_table_new(&g_str_hash, &g_str_equal);
    defer g_hash_table_unref(attributes);
    _ = g_hash_table_insert(attributes, @constCast("service"), &names.service);
    _ = g_hash_table_insert(attributes, @constCast("account"), &names.account);

    var failure: ?*gtk.GError = null;
    const items = secret_service_search_sync(null, &schema, attributes, search_load_secrets, null, &failure);
    if (failure != null) {
        gtk.g_clear_error(&failure);
        return error.SecretServiceUnavailable;
    }
    defer g_list_free_full(items, &gtk.g_object_unref);
    var node = items;
    while (node) |entry| : (node = entry.next) {
        const item = entry.data orelse continue;
        const value = secret_item_get_secret(item) orelse continue;
        defer secret_value_unref(value);
        const text = secret_value_get_text(value) orelse continue;
        const token = std.mem.span(text);
        if (token.len == 0) continue;
        return try allocator.dupe(u8, token);
    }
    return null;
}

fn getFromCredentialStore(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    service: []const u8,
    account: []const u8,
) anyerror!?[]u8 {
    return lookup(allocator, service, account);
}

var store_marker: u8 = 0;

pub const credential_store: liborca.CredentialStore = .{
    .context = &store_marker,
    .get_fn = getFromCredentialStore,
};

const AsyncReady = fn (?*gtk.GObject, *gtk.GAsyncResult, ?*anyopaque) callconv(.c) void;

fn storeFinished(_: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pending: *Pending = @ptrCast(@alignCast(data.?));
    defer std.heap.smp_allocator.destroy(pending);
    var failure: ?*gtk.GError = null;
    const stored = secret_password_store_finish(result, &failure) != 0;
    if (failure != null) gtk.g_clear_error(&failure);
    pending.completion(stored, pending.data);
}

fn clearFinished(_: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pending: *Pending = @ptrCast(@alignCast(data.?));
    defer std.heap.smp_allocator.destroy(pending);
    var failure: ?*gtk.GError = null;
    _ = secret_password_clear_finish(result, &failure);
    const cleared = failure == null;
    if (failure != null) gtk.g_clear_error(&failure);
    pending.completion(cleared, pending.data);
}

fn finishPresence(pending: *PendingPresence, presence: Presence) void {
    const completion = pending.completion;
    const data = pending.data;
    g_list_free_full(pending.items, &gtk.g_object_unref);
    std.heap.smp_allocator.destroy(pending);
    completion(presence, data);
}

fn presenceFound(_: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pending: *PendingPresence = @ptrCast(@alignCast(data.?));
    var failure: ?*gtk.GError = null;
    pending.items = secret_service_search_finish(null, result, &failure);
    if (failure != null) {
        gtk.g_clear_error(&failure);
        return finishPresence(pending, .unavailable);
    }
    if (pending.items == null) return finishPresence(pending, .absent);
    var node = pending.items;
    while (node) |entry| : (node = entry.next) {
        const item = entry.data orelse continue;
        if (secret_item_get_locked(item) == 0) return finishPresence(pending, .stored);
    }
    if (pending.locked_items == .report) return finishPresence(pending, .locked);
    secret_service_unlock(null, pending.items, null, &presenceUnlocked, pending);
}

fn presenceUnlocked(_: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pending: *PendingPresence = @ptrCast(@alignCast(data.?));
    var failure: ?*gtk.GError = null;
    const unlocked = secret_service_unlock_finish(null, result, null, &failure);
    if (failure != null) gtk.g_clear_error(&failure);
    finishPresence(pending, if (unlocked > 0) .stored else .locked);
}

fn newPending(completion: Completion, data: ?*anyopaque) error{OutOfMemory}!*Pending {
    const pending = try std.heap.smp_allocator.create(Pending);
    pending.* = .{ .completion = completion, .data = data };
    return pending;
}

/// Asynchronous so an unlock prompt cannot freeze the main loop.
pub fn save(
    service: [:0]const u8,
    account: [:0]const u8,
    label: [:0]const u8,
    token: [*:0]const u8,
    completion: Completion,
    data: ?*anyopaque,
) error{OutOfMemory}!void {
    const pending = try newPending(completion, data);
    secret_password_store(
        &schema,
        default_collection,
        label.ptr,
        token,
        null,
        &storeFinished,
        pending,
        @as([*:0]const u8, "service"),
        @as([*:0]const u8, service.ptr),
        @as([*:0]const u8, "account"),
        @as([*:0]const u8, account.ptr),
        @as(?[*:0]const u8, null),
    );
}

pub fn check(
    service: []const u8,
    account: []const u8,
    locked_items: LockedItems,
    completion: PresenceCompletion,
    data: ?*anyopaque,
) error{ OutOfMemory, NameTooLong }!void {
    const pending = try std.heap.smp_allocator.create(PendingPresence);
    errdefer std.heap.smp_allocator.destroy(pending);
    pending.* = .{ .completion = completion, .data = data, .names = try Names.init(service, account), .locked_items = locked_items };
    const attributes = g_hash_table_new(&g_str_hash, &g_str_equal);
    defer g_hash_table_unref(attributes);
    _ = g_hash_table_insert(attributes, @constCast("service"), &pending.names.service);
    _ = g_hash_table_insert(attributes, @constCast("account"), &pending.names.account);
    secret_service_search(null, &schema, attributes, search_all, null, &presenceFound, pending);
}

pub fn clear(
    service: [:0]const u8,
    account: [:0]const u8,
    completion: Completion,
    data: ?*anyopaque,
) error{OutOfMemory}!void {
    const pending = try newPending(completion, data);
    secret_password_clear(
        &schema,
        null,
        &clearFinished,
        pending,
        @as([*:0]const u8, "service"),
        @as([*:0]const u8, service.ptr),
        @as([*:0]const u8, "account"),
        @as([*:0]const u8, account.ptr),
        @as(?[*:0]const u8, null),
    );
}

comptime {
    std.debug.assert(@sizeOf(SchemaAttribute) == 16);
    std.debug.assert(@offsetOf(Schema, "attributes") == 16);
    std.debug.assert(@sizeOf(Schema) == 16 + 32 * 16 + 8 + 7 * 8);
}
