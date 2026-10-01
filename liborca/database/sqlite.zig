const std = @import("std");
const sqlite_locks = @import("sqlite_locks.zig");

pub const c = @import("sqlite");

pub const Error = error{
    OpenFailed,
    SqlFailed,
    BindFailed,
    SchemaVersionTooNew,
    ForeignKeyViolation,
};

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Database {
        const flags = c.SQLITE_OPEN_READWRITE |
            c.SQLITE_OPEN_CREATE |
            c.SQLITE_OPEN_FULLMUTEX |
            c.SQLITE_OPEN_URI;
        return openWithFlags(path, flags);
    }

    pub fn openReadOnly(path: [:0]const u8) Error!Database {
        const flags = c.SQLITE_OPEN_READONLY |
            c.SQLITE_OPEN_FULLMUTEX |
            c.SQLITE_OPEN_URI;
        return openWithFlags(path, flags);
    }

    fn openWithFlags(path: [:0]const u8, flags: c_int) Error!Database {
        sqlite_locks.installOnce();
        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &raw, flags, null) != c.SQLITE_OK) {
            if (raw) |failed| _ = c.sqlite3_close_v2(failed);
            return error.OpenFailed;
        }
        const db = Database{ .handle = raw.? };
        errdefer db.close();
        try db.exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
        return db;
    }

    pub fn close(self: Database) void {
        const result = c.sqlite3_close_v2(self.handle);
        std.debug.assert(result == c.SQLITE_OK);
    }

    pub fn exec(self: Database, sql: [:0]const u8) Error!void {
        var message: [*c]u8 = null;
        const result = c.sqlite3_exec(self.handle, sql.ptr, null, null, &message);
        if (message != null) c.sqlite3_free(message);
        if (result != c.SQLITE_OK) return error.SqlFailed;
    }

    pub fn prepare(self: Database, sql: [:0]const u8) Error!Statement {
        var raw: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &raw, null) != c.SQLITE_OK) {
            return error.SqlFailed;
        }
        return .{ .handle = raw.? };
    }

    pub fn filename(self: Database) ?[]const u8 {
        const name = c.sqlite3_db_filename(self.handle, "main") orelse return null;
        const path = std.mem.span(name);
        return if (path.len == 0) null else path;
    }

    pub fn lastError(self: Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn changes(self: Database) u64 {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Register a deterministic, one-argument text function on this connection.
    ///
    /// This exists so a migration can call Zig from SQL. The artist key is
    /// computed by one function in one place (`text_key.zig`); a backfill that
    /// reimplemented that folding in SQL would be free to drift from what the
    /// projection writes, and a drifted key is an artist who exists twice.
    /// `SQLITE_DETERMINISTIC` is honest here: the folding depends on nothing
    /// but its argument.
    pub fn createTextFunction(
        self: Database,
        name: [:0]const u8,
        context: ?*anyopaque,
        function: TextFunction,
    ) Error!void {
        if (c.sqlite3_create_function_v2(
            self.handle,
            name.ptr,
            1,
            c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC,
            context,
            function,
            null,
            null,
            null,
        ) != c.SQLITE_OK) return error.SqlFailed;
    }
};

pub const TextFunction = *const fn (
    ?*c.sqlite3_context,
    c_int,
    [*c]?*c.sqlite3_value,
) callconv(.c) void;

/// The argument of a one-argument text function, as UTF-8 bytes.
pub fn valueText(value: ?*c.sqlite3_value) []const u8 {
    const raw = c.sqlite3_value_text(value);
    if (raw == null) return "";
    const len: usize = @intCast(c.sqlite3_value_bytes(value));
    return @as([*]const u8, @ptrCast(raw))[0..len];
}

/// Hand a copy of a caller-owned slice to SQLite, which frees it.
pub fn resultText(context: ?*c.sqlite3_context, value: []const u8) void {
    if (value.len == 0) return c.sqlite3_result_text64(context, "", 0, null, c.SQLITE_UTF8);
    const copy: [*]u8 = @ptrCast(c.sqlite3_malloc64(value.len) orelse
        return c.sqlite3_result_error_nomem(context));
    @memcpy(copy[0..value.len], value);
    c.sqlite3_result_text64(context, copy, value.len, &c.sqlite3_free, c.SQLITE_UTF8);
}

pub fn resultError(context: ?*c.sqlite3_context, message: [:0]const u8) void {
    c.sqlite3_result_error(context, message.ptr, -1);
}

pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindText(self: Statement, index: c_int, value: []const u8) Error!void {
        // SQLITE_STATIC is valid because every statement is stepped or reset
        // before the caller-owned slice can leave scope.
        if (c.sqlite3_bind_text(
            self.handle,
            index,
            value.ptr,
            @intCast(value.len),
            null,
        ) != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn bindOptionalText(self: Statement, index: c_int, value: ?[]const u8) Error!void {
        if (value) |text| return self.bindText(index, text);
        if (c.sqlite3_bind_null(self.handle, index) != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn bindBlob(self: Statement, index: c_int, value: []const u8) Error!void {
        if (c.sqlite3_bind_blob64(
            self.handle,
            index,
            value.ptr,
            value.len,
            null,
        ) != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn bindOptionalBlob(self: Statement, index: c_int, value: ?[]const u8) Error!void {
        if (value) |bytes| return self.bindBlob(index, bytes);
        if (c.sqlite3_bind_null(self.handle, index) != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn bindInt64(self: Statement, index: c_int, value: i64) Error!void {
        if (c.sqlite3_bind_int64(self.handle, index, value) != c.SQLITE_OK) {
            return error.BindFailed;
        }
    }

    pub fn bindDouble(self: Statement, index: c_int, value: f64) Error!void {
        if (c.sqlite3_bind_double(self.handle, index, value) != c.SQLITE_OK)
            return error.BindFailed;
    }

    pub fn bindOptionalInt64(self: Statement, index: c_int, value: ?i64) Error!void {
        const result = if (value) |number|
            c.sqlite3_bind_int64(self.handle, index, number)
        else
            c.sqlite3_bind_null(self.handle, index);
        if (result != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn step(self: Statement) Error!Step {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => error.SqlFailed,
        };
    }

    pub fn reset(self: Statement) Error!void {
        if (c.sqlite3_reset(self.handle) != c.SQLITE_OK) return error.SqlFailed;
        if (c.sqlite3_clear_bindings(self.handle) != c.SQLITE_OK) return error.SqlFailed;
    }

    pub fn columnInt64(self: Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn columnDouble(self: Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    pub fn columnText(self: Statement, index: c_int) []const u8 {
        const text = c.sqlite3_column_text(self.handle, index);
        if (text == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return @as([*]const u8, @ptrCast(text))[0..len];
    }

    pub fn columnBlob(self: Statement, index: c_int) []const u8 {
        const blob = c.sqlite3_column_blob(self.handle, index);
        if (blob == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return @as([*]const u8, @ptrCast(blob))[0..len];
    }

    pub fn columnIsNull(self: Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }
};

pub const Step = enum { row, done };
