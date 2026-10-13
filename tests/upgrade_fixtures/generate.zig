const std = @import("std");
const liborca = @import("liborca");
const seed = @import("upgrade_seed");

const sqlite = liborca.internal.database.sqlite;
const migrations = liborca.internal.database.migrations;

const usage = "usage: generate-upgrade-fixtures DIRECTORY\n" ++
    "Writes v1.sqlite to v{current}.sqlite into DIRECTORY, one library per released schema version.\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("{s}", .{usage});
        return error.Usage;
    }
    const io = init.io;
    const directory = args[1];
    try std.Io.Dir.cwd().createDirPath(io, directory);
    for (1..migrations.current_version + 1) |version| {
        var name_buffer: [32]u8 = undefined;
        const name = try seed.fixtureName(&name_buffer, version);
        const path = try std.fmt.allocPrintSentinel(init.arena.allocator(), "{s}/{s}", .{ directory, name }, 0);
        for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
            const stale = try std.fmt.allocPrint(init.arena.allocator(), "{s}{s}", .{ path, suffix });
            std.Io.Dir.cwd().deleteFile(io, stale) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        const db = try sqlite.Database.open(path);
        defer db.close();
        try db.exec("PRAGMA journal_mode=WAL;");
        try seed.buildReleased(db, version);
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);");
    }
}
