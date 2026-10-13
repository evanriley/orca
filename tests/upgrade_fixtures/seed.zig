const std = @import("std");
const liborca = @import("liborca");

const database = liborca.internal.database;
const sqlite = database.sqlite;
const migrations = database.migrations;

pub const fixture_directory = "fixtures/library/upgrade";

pub const Stage = struct {
    version: usize,
    shared: [:0]const u8,
    legacy: [:0]const u8,
    settled: [:0]const u8,
};

const none: [:0]const u8 = "";

pub const stages = [migrations.current_version]Stage{
    .{ .version = 1, .shared = @embedFile("seed-v1.sql"), .legacy = none, .settled = none },
    .{ .version = 2, .shared = @embedFile("seed-v2.sql"), .legacy = @embedFile("legacy-v2.sql"), .settled = none },
    .{ .version = 3, .shared = @embedFile("seed-v3.sql"), .legacy = @embedFile("legacy-v3.sql"), .settled = @embedFile("settled-v3.sql") },
    .{ .version = 4, .shared = @embedFile("seed-v4.sql"), .legacy = none, .settled = none },
    .{ .version = 5, .shared = @embedFile("seed-v5.sql"), .legacy = none, .settled = none },
    .{ .version = 6, .shared = @embedFile("seed-v6.sql"), .legacy = none, .settled = none },
    .{ .version = 7, .shared = @embedFile("seed-v7.sql"), .legacy = none, .settled = none },
};

pub fn fixtureName(buffer: []u8, version: usize) ![]u8 {
    return std.fmt.bufPrint(buffer, "v{d}.sqlite", .{version});
}

const NoCopy = struct {
    pub fn write(_: NoCopy, _: sqlite.Database, _: usize) error{}!void {}
};

pub fn buildReleased(db: sqlite.Database, version: usize) !void {
    for (stages[0..version]) |stage| {
        _ = try migrations.upgrade(db, stage.version, NoCopy{});
        try db.exec(stage.shared);
        try db.exec(stage.legacy);
    }
}

pub fn buildCurrent(db: sqlite.Database, version: usize) !void {
    try migrations.apply(db);
    for (stages[0..version]) |stage| {
        try db.exec(stage.shared);
        try db.exec(stage.settled);
    }
}
