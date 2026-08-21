const std = @import("std");

pub const c = @import("sqlite");

pub const Error = error{
    OpenFailed,
    SqlFailed,
    BindFailed,
    SchemaVersionTooNew,
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

    pub fn lastError(self: Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn changes(self: Database) u64 {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

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
