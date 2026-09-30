const std = @import("std");
const sqlite = @import("sqlite.zig");
const quick_hash = @import("../storage/quick_hash.zig");

/// The largest page any repository hands back, matching the C ABI's own bound.
pub const max_page = 512;

pub fn presentText(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

/// A property too large for the column is stored as unknown rather than as a
/// wrapped or saturated number.
pub fn optionalCount(value: anytype) ?i64 {
    return std.math.cast(i64, value orelse return null);
}

pub fn countColumn(statement: sqlite.Statement, column: c_int) ?u32 {
    if (statement.columnIsNull(column)) return null;
    return std.math.cast(u32, statement.columnInt64(column));
}

pub fn dupeNullable(
    allocator: std.mem.Allocator,
    statement: sqlite.Statement,
    column: c_int,
) !?[]const u8 {
    if (statement.columnIsNull(column)) return null;
    return try allocator.dupe(u8, statement.columnText(column));
}

pub fn optionalInt64(statement: sqlite.Statement, column: c_int) ?i64 {
    if (statement.columnIsNull(column)) return null;
    return statement.columnInt64(column);
}

pub fn digestColumn(statement: sqlite.Statement, column: c_int) ?quick_hash.Digest {
    const bytes = statement.columnBlob(column);
    if (bytes.len != @typeInfo(quick_hash.Digest).array.len) return null;
    var digest: quick_hash.Digest = undefined;
    @memcpy(&digest, bytes);
    return digest;
}

pub fn duplicateNullableColumn(
    allocator: std.mem.Allocator,
    statement: sqlite.Statement,
    column: c_int,
) !?[]u8 {
    if (statement.columnIsNull(column)) return null;
    return try allocator.dupe(u8, statement.columnText(column));
}

pub fn scalar(db: sqlite.Database, sql: [:0]const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}
