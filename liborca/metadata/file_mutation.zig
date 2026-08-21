const std = @import("std");
const id3v1 = @import("id3v1.zig");
const mutation = @import("mutation.zig");

pub fn identity(io: std.Io, path: []const u8) !mutation.FileIdentity {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return .{
        .size_bytes = stat.size,
        .modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse
            return error.FileTimestampOutOfRange,
    };
}

/// Create and fsync a complete ID3v1 replacement without changing `source_path`.
/// The stage path must not exist and should reside on the same filesystem.
pub fn stageId3v1(
    io: std.Io,
    source_path: []const u8,
    stage_path: []const u8,
    expected: mutation.FileIdentity,
    changes: []const mutation.Change,
) !void {
    const source = try std.Io.Dir.cwd().openFile(io, source_path, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    try requireIdentity(stat, expected);

    var existing_bytes: [128]u8 = undefined;
    const existing = if (stat.size >= existing_bytes.len and
        try source.readPositionalAll(io, &existing_bytes, stat.size - existing_bytes.len) == existing_bytes.len)
        id3v1.parse(&existing_bytes)
    else
        null;
    var tag: id3v1.Tag = existing orelse .{
        .title = "",
        .artist = "",
        .album = "",
        .year = "",
        .comment = "",
        .track_number = null,
        .genre = 255,
    };
    try applyChanges(&tag, changes);
    const encoded = try id3v1.encode(tag);
    const payload_size = stat.size - if (existing != null) @as(u64, existing_bytes.len) else 0;

    const stage = try std.Io.Dir.cwd().createFile(io, stage_path, .{
        .exclusive = true,
        .permissions = stat.permissions,
    });
    errdefer {
        stage.close(io);
        std.Io.Dir.cwd().deleteFile(io, stage_path) catch {};
    }
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (offset < payload_size) {
        const requested: usize = @intCast(@min(payload_size - offset, buffer.len));
        const read_count = try source.readPositional(io, &.{buffer[0..requested]}, offset);
        if (read_count == 0) return error.UnexpectedEndOfFile;
        try stage.writeStreamingAll(io, buffer[0..read_count]);
        offset += read_count;
    }
    try stage.writeStreamingAll(io, &encoded);
    try stage.sync(io);
    stage.close(io);
}

/// Replace the source while retaining its exact previous bytes at `backup_path`.
pub fn commitReplacement(
    io: std.Io,
    source_path: []const u8,
    stage_path: []const u8,
    backup_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(source_path, cwd, backup_path, io);
    errdefer cwd.rename(backup_path, cwd, source_path, io) catch {};
    try cwd.rename(stage_path, cwd, source_path, io);
}

pub fn rollbackReplacement(
    io: std.Io,
    source_path: []const u8,
    backup_path: []const u8,
    displaced_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    // Verify the recovery source before moving the current file out of place.
    const backup = try cwd.openFile(io, backup_path, .{});
    backup.close(io);
    var displaced = true;
    cwd.rename(source_path, cwd, displaced_path, io) catch |err| switch (err) {
        error.FileNotFound => displaced = false,
        else => return err,
    };
    errdefer if (displaced) cwd.rename(displaced_path, cwd, source_path, io) catch {};
    try cwd.rename(backup_path, cwd, source_path, io);
    if (displaced) try cwd.deleteFile(io, displaced_path);
}

fn requireIdentity(stat: std.Io.File.Stat, expected: mutation.FileIdentity) !void {
    const modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse
        return error.FileTimestampOutOfRange;
    if (stat.size != expected.size_bytes or modified_ns != expected.modified_ns)
        return error.FileIdentityChanged;
}

fn applyChanges(tag: *id3v1.Tag, changes: []const mutation.Change) !void {
    for (changes) |change| {
        if (change.field == .track_number) {
            if (change.before) |before| {
                const parsed = std.fmt.parseInt(u8, before, 10) catch
                    return error.MetadataPreconditionChanged;
                if (tag.track_number == null or parsed != tag.track_number.?)
                    return error.MetadataPreconditionChanged;
            }
            tag.track_number = if (change.after) |text|
                try std.fmt.parseInt(u8, text, 10)
            else
                null;
            continue;
        }
        const current: ?[]const u8 = switch (change.field) {
            .title => tag.title,
            .artist => tag.artist,
            .album => tag.album,
            .track_number => unreachable,
        };
        if (change.before) |before| {
            if (current == null or !std.mem.eql(u8, before, current.?))
                return error.MetadataPreconditionChanged;
        }
        const after = change.after orelse "";
        switch (change.field) {
            .title => tag.title = after,
            .artist => tag.artist = after,
            .album => tag.album = after,
            .track_number => unreachable,
        }
    }
}

test "ID3v1 replacement stages, commits, and rolls back generated bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.mp3", .{prefix});
    defer std.testing.allocator.free(source_path);
    const stage_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/stage.mp3", .{prefix});
    defer std.testing.allocator.free(stage_path);
    const backup_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/backup.mp3", .{prefix});
    defer std.testing.allocator.free(backup_path);
    const original_tag = try id3v1.encode(.{
        .title = "Old title",
        .artist = "Generated artist",
        .album = "Generated album",
        .year = "2026",
        .comment = "Generated",
        .track_number = 1,
        .genre = 13,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.mp3",
        .data = "generated audio payload" ++ original_tag,
    });
    const expected = try identity(std.testing.io, source_path);
    try stageId3v1(std.testing.io, source_path, stage_path, expected, &.{.{
        .field = .title,
        .before = "Old title",
        .after = "New title",
    }});
    try std.testing.expectEqual(expected, try identity(std.testing.io, source_path));
    try commitReplacement(std.testing.io, source_path, stage_path, backup_path);
    try expectTitle(source_path, "New title");
    try expectTitle(backup_path, "Old title");
    try rollbackReplacement(std.testing.io, source_path, backup_path, stage_path);
    try expectTitle(source_path, "Old title");
}

fn expectTitle(path: []const u8, expected: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    var bytes: [128]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &bytes, stat.size - bytes.len);
    try std.testing.expectEqualStrings(expected, id3v1.parse(&bytes).?.title);
}
