const std = @import("std");
const sqlite = @import("../sqlite.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

/// Whether automatic genre fill from MusicBrainz may write provider genres.
pub const genre_fill_musicbrainz = "genre_fill.musicbrainz";

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
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "INSERT INTO library_settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
        );
        defer statement.deinit();
        try statement.bindText(1, key);
        try statement.bindText(2, if (value) "1" else "0");
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
