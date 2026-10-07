const std = @import("std");
const sqlite = @import("../sqlite.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

/// Whether automatic genre fill from MusicBrainz may write provider genres.
pub const genre_fill_musicbrainz = "genre_fill.musicbrainz";
/// How long a play must be heard to count, a `ListenPolicy` tag name.
pub const listen_policy = "listens.policy";
/// Whether plays are kept in the local listening history.
pub const listen_recording = "listens.record";
/// Whether Radio starts from what was heard last when the queue runs out.
pub const radio_continue = "radio.continue";
/// Whether Radio may pick Recordings that were never played.
pub const radio_include_unplayed = "radio.include_unplayed";
/// How many days a played Recording is left out of Radio and Daily Mixes.
pub const discovery_avoid_days = "discovery.avoid_days";
/// How many Daily Mixes are made each day.
pub const mixes_count = "mixes.count";

/// Per-Library settings kept in the Library itself, never credentials.
pub const LibrarySettingsRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// The stored flag, or `default` when it was never set.
    pub fn flag(self: *const LibrarySettingsRepository, key: []const u8, default: bool) !bool {
        var statement = try self.db.prepare("SELECT value FROM library_settings WHERE key=?1;");
        defer statement.deinit();
        try statement.bindText(1, key);
        if (try statement.step() != .row) return default;
        return !std.mem.eql(u8, statement.columnText(0), "0");
    }

    pub fn setFlag(self: *LibrarySettingsRepository, key: []const u8, value: bool) !void {
        try self.setText(key, if (value) "1" else "0");
    }

    /// The stored tag of `E`, or `default` when it was never set or names no
    /// tag of `E`.
    pub fn enumValue(self: *const LibrarySettingsRepository, comptime E: type, key: []const u8, default: E) !E {
        var statement = try self.db.prepare("SELECT value FROM library_settings WHERE key=?1;");
        defer statement.deinit();
        try statement.bindText(1, key);
        if (try statement.step() != .row) return default;
        return std.meta.stringToEnum(E, statement.columnText(0)) orelse default;
    }

    pub fn setEnum(self: *LibrarySettingsRepository, key: []const u8, value: anytype) !void {
        try self.setText(key, @tagName(value));
    }

    /// The stored integer, or `default` when it was never set or is not one.
    pub fn integer(self: *const LibrarySettingsRepository, key: []const u8, default: i64) !i64 {
        var statement = try self.db.prepare("SELECT value FROM library_settings WHERE key=?1;");
        defer statement.deinit();
        try statement.bindText(1, key);
        if (try statement.step() != .row) return default;
        return std.fmt.parseInt(i64, statement.columnText(0), 10) catch default;
    }

    pub fn setInteger(self: *LibrarySettingsRepository, key: []const u8, value: i64) !void {
        var buffer: [24]u8 = undefined;
        try self.setText(key, std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
    }

    fn setText(self: *LibrarySettingsRepository, key: []const u8, value: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "INSERT INTO library_settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
        );
        defer statement.deinit();
        try statement.bindText(1, key);
        try statement.bindText(2, value);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

test "a flag reads its default until set and keeps what was set" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-library-settings?mode=memory&cache=shared");
    defer library.close();
    try std.testing.expect(try library.settings.flag(genre_fill_musicbrainz, true));
    try std.testing.expect(!try library.settings.flag(genre_fill_musicbrainz, false));
    try library.settings.setFlag(genre_fill_musicbrainz, false);
    try std.testing.expect(!try library.settings.flag(genre_fill_musicbrainz, true));
    try library.settings.setFlag(genre_fill_musicbrainz, true);
    try std.testing.expect(try library.settings.flag(genre_fill_musicbrainz, false));
}

test "an enum setting reads its default until set, and again when it names no tag" {
    const Policy = enum { half, thirty, full };
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-library-settings-enum?mode=memory&cache=shared");
    defer library.close();
    try std.testing.expectEqual(Policy.half, try library.settings.enumValue(Policy, listen_policy, .half));
    try library.settings.setEnum(listen_policy, Policy.full);
    try std.testing.expectEqual(Policy.full, try library.settings.enumValue(Policy, listen_policy, .half));
    try library.database.exec("UPDATE library_settings SET value = 'never' WHERE key = 'listens.policy';");
    try std.testing.expectEqual(Policy.half, try library.settings.enumValue(Policy, listen_policy, .half));
}

test "an integer setting reads its default until set, and again when it is not an integer" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-library-settings-integer?mode=memory&cache=shared");
    defer library.close();
    try std.testing.expectEqual(@as(i64, 3), try library.settings.integer(discovery_avoid_days, 3));
    try library.settings.setInteger(discovery_avoid_days, 7);
    try std.testing.expectEqual(@as(i64, 7), try library.settings.integer(discovery_avoid_days, 3));
    try library.database.exec("UPDATE library_settings SET value = 'week' WHERE key = 'discovery.avoid_days';");
    try std.testing.expectEqual(@as(i64, 3), try library.settings.integer(discovery_avoid_days, 3));
}
