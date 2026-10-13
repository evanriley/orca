const std = @import("std");
const migrations = @import("migrations.zig");
const sqlite = @import("sqlite.zig");
const syncContainingDirectory = @import("../metadata/file_mutation.zig").syncContainingDirectory;

const c = sqlite.c;

pub const Error = error{ PreUpgradeCopyFailed, OutOfMemory };

const version_prefix = ".pre-v";
const extension = ".sqlite";
const temporary_suffix = ".tmp";
const temporary_journal_suffix = temporary_suffix ++ "-journal";

const Named = struct {
    version: usize,
    finished: bool,
};

fn named(suffix: []const u8) ?Named {
    if (!std.mem.startsWith(u8, suffix, version_prefix)) return null;
    const rest = suffix[version_prefix.len..];
    const digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse return null;
    const version = std.fmt.parseInt(usize, rest[0..digits], 10) catch return null;
    if (!std.mem.startsWith(u8, rest[digits..], extension)) return null;
    const tail = rest[digits + extension.len ..];
    if (tail.len == 0) return .{ .version = version, .finished = true };
    if (std.mem.eql(u8, tail, temporary_suffix) or std.mem.eql(u8, tail, temporary_journal_suffix))
        return .{ .version = version, .finished = false };
    return null;
}

pub fn ownsSuffix(suffix: []const u8) bool {
    return named(suffix) != null;
}

pub const Copier = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Must run inside the upgrade's write transaction on `upgrading`: that
    /// lock is all that keeps another connection from changing the database
    /// between this copy and the first step. SQLite refuses a backup from a
    /// connection holding a write transaction, so the copy reads through a
    /// connection of its own.
    pub fn write(self: Copier, upgrading: sqlite.Database, version: usize) Error!void {
        const database_path = try self.allocator.dupeSentinel(u8, upgrading.filename() orelse return, 0);
        defer self.allocator.free(database_path);
        const final_path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}" ++ version_prefix ++ "{d}" ++ extension,
            .{ database_path, version },
            0,
        );
        defer self.allocator.free(final_path);
        const temporary_path = try std.fmt.allocPrintSentinel(self.allocator, "{s}" ++ temporary_suffix, .{final_path}, 0);
        defer self.allocator.free(temporary_path);
        const journal_path = try std.fmt.allocPrint(self.allocator, "{s}" ++ temporary_journal_suffix, .{final_path});
        defer self.allocator.free(journal_path);
        writeDurably(self.io, database_path, version, temporary_path, journal_path, final_path) catch |err| {
            std.log.warn("{s}: the copy made before a schema upgrade could not be written ({t})", .{ final_path, err });
            return error.PreUpgradeCopyFailed;
        };
    }

    pub fn removeOlder(self: Copier, database_path: []const u8, kept_version: usize) !void {
        const database_name = std.Io.Dir.path.basename(database_path);
        var directory = try std.Io.Dir.cwd().openDir(
            self.io,
            std.Io.Dir.path.dirname(database_path) orelse ".",
            .{ .iterate = true },
        );
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, database_name)) continue;
            const found = named(entry.name[database_name.len..]) orelse continue;
            if (found.version >= kept_version) continue;
            try directory.deleteFile(self.io, entry.name);
        }
    }
};

fn writeDurably(
    io: std.Io,
    database_path: [:0]const u8,
    version: usize,
    temporary_path: [:0]const u8,
    journal_path: []const u8,
    final_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    try deleteIfPresent(io, journal_path);
    try deleteIfPresent(io, temporary_path);
    errdefer {
        cwd.deleteFile(io, temporary_path) catch {};
        cwd.deleteFile(io, journal_path) catch {};
    }
    {
        const source = try sqlite.Database.openReadOnly(database_path);
        defer source.close();
        const copy = try sqlite.Database.open(temporary_path);
        defer copy.close();
        try backUp(source, copy);
        try copy.exec("PRAGMA journal_mode=DELETE;");
        if (try migrations.userVersion(copy) != version) return error.CopyDiffersFromSource;
    }
    {
        const file = try cwd.openFile(io, temporary_path, .{});
        defer file.close(io);
        try file.sync(io);
    }
    try cwd.rename(temporary_path, cwd, final_path, io);
    try syncContainingDirectory(io, final_path);
}

fn backUp(source: sqlite.Database, copy: sqlite.Database) !void {
    const backup = c.sqlite3_backup_init(copy.handle, "main", source.handle, "main") orelse return error.SqlFailed;
    const stepped = c.sqlite3_backup_step(backup, -1);
    const finished = c.sqlite3_backup_finish(backup);
    if (stepped != c.SQLITE_DONE or finished != c.SQLITE_OK) return error.SqlFailed;
}

fn deleteIfPresent(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn newest(io: std.Io, database_path: []const u8, buffer: []u8) ?[]u8 {
    const database_name = std.Io.Dir.path.basename(database_path);
    var directory = std.Io.Dir.cwd().openDir(
        io,
        std.Io.Dir.path.dirname(database_path) orelse ".",
        .{ .iterate = true },
    ) catch return null;
    defer directory.close(io);
    var newest_version: ?usize = null;
    var iterator = directory.iterate();
    while (iterator.next(io) catch return null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, database_name)) continue;
        const found = named(entry.name[database_name.len..]) orelse continue;
        if (!found.finished) continue;
        if (newest_version == null or found.version > newest_version.?) newest_version = found.version;
    }
    return std.fmt.bufPrint(
        buffer,
        "{s}" ++ version_prefix ++ "{d}" ++ extension,
        .{ database_path, newest_version orelse return null },
    ) catch null;
}

test "only a copy's own names are recognised, with the version they hold" {
    try std.testing.expectEqual(Named{ .version = 4, .finished = true }, named(".pre-v4.sqlite").?);
    try std.testing.expectEqual(Named{ .version = 12, .finished = false }, named(".pre-v12.sqlite.tmp").?);
    try std.testing.expectEqual(Named{ .version = 1, .finished = false }, named(".pre-v1.sqlite.tmp-journal").?);
    for ([_][]const u8{ "", "-wal", ".pre-v.sqlite", ".pre-v4", ".pre-v4.sqlite-wal", ".pre-vinyl.sqlite", ".pre-v4.sqlite.flac" }) |suffix|
        try std.testing.expect(!ownsSuffix(suffix));
}
