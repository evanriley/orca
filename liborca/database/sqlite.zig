const std = @import("std");
const sqlite_locks = @import("sqlite_locks.zig");

/// How long a statement blocked by a shared-cache table lock waits for the
/// blocking transaction to finish, one millisecond per attempt. The busy
/// handler does not cover `SQLITE_LOCKED`, so this stands in for it; it
/// matches the five-second `busy_timeout` every connection sets.
const locked_wait_ms: usize = 5_000;

pub const c = @import("sqlite");

pub const Error = error{
    OpenFailed,
    SqlFailed,
    BindFailed,
    SchemaVersionTooNew,
    ForeignKeyViolation,
} || sqlite_locks.Error;

pub const Database = struct {
    handle: *c.sqlite3,
    /// Set only on the dynamic handle a Library hands to its repositories. Its
    /// owner probe picks the writer for a lane holder's thread and the reader
    /// for every other thread; null means this handle is used directly.
    connections: ?*Connections = null,
    /// How a statement that meets a shared-cache table lock waits it out. Null
    /// for a standalone handle, whose statements never retry.
    io: ?std.Io = null,

    fn resolved(self: Database) Database {
        const connections = self.connections orelse return self;
        return if (connections.ownsLane(connections.context))
            connections.writer
        else
            connections.reader;
    }

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
        try sqlite_locks.requireInstalled();
        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &raw, flags, null) != c.SQLITE_OK) {
            if (raw) |failed| _ = c.sqlite3_close_v2(failed);
            return error.OpenFailed;
        }
        const db = Database{ .handle = raw.? };
        errdefer db.close();
        try db.exec("PRAGMA foreign_keys=ON; PRAGMA recursive_triggers=OFF; PRAGMA busy_timeout=5000;");
        return db;
    }

    pub fn close(self: Database) void {
        const result = c.sqlite3_close_v2(self.handle);
        std.debug.assert(result == c.SQLITE_OK);
    }

    pub fn exec(self: Database, sql: [:0]const u8) Error!void {
        const db = self.resolved();
        var message: [*c]u8 = null;
        const result = c.sqlite3_exec(db.handle, sql.ptr, null, null, &message);
        if (message != null) c.sqlite3_free(message);
        if (result != c.SQLITE_OK) return error.SqlFailed;
    }

    pub fn prepare(self: Database, sql: [:0]const u8) Error!Statement {
        const db = self.resolved();
        var raw: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &raw, null) != c.SQLITE_OK) {
            return error.SqlFailed;
        }
        return .{ .handle = raw.?, .io = db.io };
    }

    pub fn filename(self: Database) ?[]const u8 {
        const db = self.resolved();
        const name = c.sqlite3_db_filename(db.handle, "main") orelse return null;
        const path = std.mem.span(name);
        return if (path.len == 0) null else path;
    }

    pub fn lastError(self: Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.resolved().handle));
    }

    pub fn changes(self: Database) u64 {
        return @intCast(c.sqlite3_changes64(self.resolved().handle));
    }

    pub fn lastInsertRowId(self: Database) i64 {
        return c.sqlite3_last_insert_rowid(self.resolved().handle);
    }

    pub fn interrupt(self: Database) void {
        c.sqlite3_interrupt(self.resolved().handle);
    }
};

/// The two handles a Library routes between, and the probe that tells a
/// dynamic `Database` which one the calling thread must use. The probe lives
/// here as a function pointer so this file need not know about `WriteLane`.
/// Context points at the Library's lane; `ownsLane` reports whether the
/// calling thread holds it.
pub const Connections = struct {
    writer: Database,
    reader: Database,
    context: *anyopaque,
    ownsLane: *const fn (context: *anyopaque) bool,
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    io: ?std.Io = null,

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

    pub fn bindOptionalDouble(self: Statement, index: c_int, value: ?f64) Error!void {
        if (value) |number| return self.bindDouble(index, number);
        if (c.sqlite3_bind_null(self.handle, index) != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn bindOptionalInt64(self: Statement, index: c_int, value: ?i64) Error!void {
        const result = if (value) |number|
            c.sqlite3_bind_int64(self.handle, index, number)
        else
            c.sqlite3_bind_null(self.handle, index);
        if (result != c.SQLITE_OK) return error.BindFailed;
    }

    pub fn step(self: Statement) Error!Step {
        var remaining = locked_wait_ms;
        while (true) {
            return switch (c.sqlite3_step(self.handle)) {
                c.SQLITE_ROW => .row,
                c.SQLITE_DONE => .done,
                c.SQLITE_LOCKED => locked: {
                    if (self.io == null or remaining == 0) break :locked error.SqlFailed;
                    _ = c.sqlite3_reset(self.handle);
                    if (self.io) |io| io.sleep(.fromMilliseconds(1), .awake) catch {};
                    remaining -= 1;
                    continue;
                },
                else => error.SqlFailed,
            };
        }
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

test "a connection enforces foreign keys and keeps triggers non-recursive whatever SQLite's build defaults" {
    const db = try Database.open(":memory:");
    defer db.close();
    inline for (.{ .{ "PRAGMA foreign_keys;", 1 }, .{ "PRAGMA recursive_triggers;", 0 } }) |pragma| {
        var statement = try db.prepare(pragma[0]);
        defer statement.deinit();
        try std.testing.expectEqual(Step.row, try statement.step());
        try std.testing.expectEqual(@as(i64, pragma[1]), statement.columnInt64(0));
    }
}

test "an interrupt from another thread ends a statement that would never finish" {
    const db = try Database.open(":memory:");
    defer db.close();
    var statement = try db.prepare("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n;");
    defer statement.deinit();
    const Interrupter = struct {
        fn run(target: Database, done: *const std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                target.interrupt();
                const pause: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = std.c.nanosleep(&pause, null);
            }
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Interrupter.run, .{ db, &done });
    const outcome = statement.step();
    done.store(true, .release);
    thread.join();
    try std.testing.expectError(error.SqlFailed, outcome);
    try std.testing.expectEqual(c.SQLITE_INTERRUPT, c.sqlite3_errcode(db.handle));
}
