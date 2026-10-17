const std = @import("std");
const liborca = @import("liborca");
const seed = @import("upgrade_seed");

const database = liborca.internal.database;
const sqlite = database.sqlite;
const migrations = database.migrations;

const Scratch = struct {
    temporary: std.testing.TmpDir,
    path: []u8,

    fn init(io: std.Io) !Scratch {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.testing.allocator.dupe(u8, buffer[0..try temporary.dir.realPath(io, &buffer)]);
        return .{ .temporary = temporary, .path = path };
    }

    fn deinit(self: *Scratch) void {
        std.testing.allocator.free(self.path);
        self.temporary.cleanup();
    }

    fn file(self: *const Scratch, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ self.path, name }, 0);
    }
};

fn scalar(db: sqlite.Database, sql: [:0]const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

const Table = struct {
    name: []u8,
    select: [:0]u8,
    count: [:0]u8,
};

fn isShadowOfVirtual(db: sqlite.Database, name: []const u8) !bool {
    var statement = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%';");
    defer statement.deinit();
    while (try statement.step() == .row) {
        const virtual = statement.columnText(0);
        if (name.len > virtual.len + 1 and std.mem.startsWith(u8, name, virtual) and name[virtual.len] == '_') return true;
    }
    return false;
}

fn columnList(db: sqlite.Database, table: []const u8) ![]u8 {
    const sql = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "SELECT group_concat('quote(\"' || name || '\")', ' || ''|'' || ') FROM (SELECT name FROM pragma_table_info('{s}') ORDER BY name);",
        .{table},
        0,
    );
    defer std.testing.allocator.free(sql);
    var statement = try db.prepare(sql);
    defer statement.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    return std.testing.allocator.dupe(u8, statement.columnText(0));
}

fn tables(db: sqlite.Database) !std.ArrayList(Table) {
    var found: std.ArrayList(Table) = .empty;
    errdefer freeTables(&found);
    var statement = try db.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
    );
    defer statement.deinit();
    while (try statement.step() == .row) {
        const name = statement.columnText(0);
        if (try isShadowOfVirtual(db, name)) continue;
        const columns = try columnList(db, name);
        defer std.testing.allocator.free(columns);
        const owned_name = try std.testing.allocator.dupe(u8, name);
        errdefer std.testing.allocator.free(owned_name);
        const select = try std.fmt.allocPrintSentinel(
            std.testing.allocator,
            "SELECT row FROM (SELECT {s} AS row FROM \"{s}\") ORDER BY row;",
            .{ columns, name },
            0,
        );
        errdefer std.testing.allocator.free(select);
        const count = try std.fmt.allocPrintSentinel(std.testing.allocator, "SELECT count(*) FROM \"{s}\";", .{name}, 0);
        try found.append(std.testing.allocator, .{ .name = owned_name, .select = select, .count = count });
    }
    return found;
}

fn freeTables(found: *std.ArrayList(Table)) void {
    for (found.items) |table| {
        std.testing.allocator.free(table.name);
        std.testing.allocator.free(table.select);
        std.testing.allocator.free(table.count);
    }
    found.deinit(std.testing.allocator);
}

fn dump(db: sqlite.Database, table: Table) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(std.testing.allocator);
    var statement = try db.prepare(table.select);
    defer statement.deinit();
    while (try statement.step() == .row) {
        try text.appendSlice(std.testing.allocator, statement.columnText(0));
        try text.append(std.testing.allocator, '\n');
    }
    return text.toOwnedSlice(std.testing.allocator);
}

fn expectSameContents(label: []const u8, upgraded: sqlite.Database, fresh: sqlite.Database) !void {
    var upgraded_tables = try tables(upgraded);
    defer freeTables(&upgraded_tables);
    var fresh_tables = try tables(fresh);
    defer freeTables(&fresh_tables);
    try std.testing.expectEqual(fresh_tables.items.len, upgraded_tables.items.len);
    for (fresh_tables.items, upgraded_tables.items) |expected, actual| {
        std.testing.expectEqualStrings(expected.name, actual.name) catch |err| {
            std.debug.print("{s}: table set differs\n", .{label});
            return err;
        };
        std.testing.expectEqual(try scalar(fresh, expected.count), try scalar(upgraded, actual.count)) catch |err| {
            std.debug.print("{s}: row count differs in {s}\n", .{ label, expected.name });
            return err;
        };
        const expected_rows = try dump(fresh, expected);
        defer std.testing.allocator.free(expected_rows);
        const actual_rows = try dump(upgraded, actual);
        defer std.testing.allocator.free(actual_rows);
        std.testing.expectEqualStrings(expected_rows, actual_rows) catch |err| {
            std.debug.print("{s}: rows differ in {s}\n", .{ label, expected.name });
            return err;
        };
    }
}

fn readAll(io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(64 * 1024 * 1024));
}

fn copyFixture(io: std.Io, version: usize, destination: []const u8) !void {
    var name_buffer: [32]u8 = undefined;
    const name = try seed.fixtureName(&name_buffer, version);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ seed.fixture_directory, name });
    defer std.testing.allocator.free(source);
    try std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), destination, io, .{});
}

test "every released schema's database upgrades to the rows a fresh library holds" {
    const io = std.testing.io;
    var scratch = try Scratch.init(io);
    defer scratch.deinit();
    for (1..migrations.current_version + 1) |version| {
        var label_buffer: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "v{d}", .{version});
        const upgraded_name = try std.fmt.allocPrint(std.testing.allocator, "upgraded-{d}.db", .{version});
        defer std.testing.allocator.free(upgraded_name);
        const upgraded_path = try scratch.file(upgraded_name);
        defer std.testing.allocator.free(upgraded_path);
        try copyFixture(io, version, upgraded_path);

        {
            const shipped = try sqlite.Database.openReadOnly(upgraded_path);
            defer shipped.close();
            try std.testing.expectEqual(@as(i64, @intCast(version)), try scalar(shipped, "PRAGMA user_version;"));
        }

        var library = try database.LibraryDatabase.open(std.testing.allocator, io, upgraded_path);
        library.close();

        const upgraded = try sqlite.Database.open(upgraded_path);
        defer upgraded.close();
        try std.testing.expectEqual(@as(i64, migrations.current_version), try scalar(upgraded, "PRAGMA user_version;"));

        const fresh_name = try std.fmt.allocPrint(std.testing.allocator, "fresh-{d}.db", .{version});
        defer std.testing.allocator.free(fresh_name);
        const fresh_path = try scratch.file(fresh_name);
        defer std.testing.allocator.free(fresh_path);
        const fresh = try sqlite.Database.open(fresh_path);
        defer fresh.close();
        try seed.buildCurrent(fresh, version);

        try expectSameContents(label, upgraded, fresh);
        try std.testing.expectEqual(@as(i64, 0), try scalar(upgraded, migrations.genre_totals_drift_sql));
        try std.testing.expectEqual(@as(i64, 0), try scalar(upgraded, migrations.sort_columns_drift_sql));
    }
}

test "every user table of the current schema holds rows in the newest fixture" {
    const io = std.testing.io;
    var scratch = try Scratch.init(io);
    defer scratch.deinit();
    const path = try scratch.file("current.db");
    defer std.testing.allocator.free(path);
    try copyFixture(io, migrations.current_version, path);
    const db = try sqlite.Database.openReadOnly(path);
    defer db.close();
    var found = try tables(db);
    defer freeTables(&found);
    var empty: usize = 0;
    for (found.items) |table| {
        if (try scalar(db, table.count) == 0) {
            std.debug.print("empty table in the newest fixture: {s}\n", .{table.name});
            empty += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), empty);
}

test "opening an already current library leaves its file byte-identical" {
    const io = std.testing.io;
    var scratch = try Scratch.init(io);
    defer scratch.deinit();
    const path = try scratch.file("current.db");
    defer std.testing.allocator.free(path);
    try copyFixture(io, migrations.current_version, path);
    const before = try readAll(io, path);
    defer std.testing.allocator.free(before);
    {
        var library = try database.LibraryDatabase.open(std.testing.allocator, io, path);
        library.close();
    }
    const after = try readAll(io, path);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.eql(u8, before, after));
}
