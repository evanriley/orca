const builtin = @import("builtin");
const std = @import("std");
const id3v1 = @import("id3v1.zig");
const mutation = @import("mutation.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const vorbis_comment = @import("vorbis_comment.zig");

const max_flac_metadata_block_size = (1 << 24) - 1;

/// Points at which a mutation can be interrupted by power loss. Production
/// callers pass null; recovery tests drive the same code path and stop it at a
/// real boundary rather than simulating one.
pub const Interrupt = enum {
    after_backup_rename,
    after_source_rename,
    after_rollback_displace,
    after_rollback_restore,
};

pub const InterruptError = error{SimulatedPowerLoss};

pub fn identity(io: std.Io, path: []const u8) !mutation.FileIdentity {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return identityOfFile(io, file);
}

fn identityOfFile(io: std.Io, file: std.Io.File) !mutation.FileIdentity {
    const stat = try file.stat(io);
    return .{
        .size_bytes = stat.size,
        .modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse
            return error.FileTimestampOutOfRange,
        .quick_hash = try quick_hash.fromFile(io, file, stat.size),
    };
}

/// fsync the directory that contains `path` so its namespace entries survive a
/// power loss. Directory synchronization is a POSIX guarantee; on Windows the
/// rename itself is the durability boundary and there is nothing to sync.
pub fn syncContainingDirectory(io: std.Io, path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const directory_path = std.Io.Dir.path.dirname(path) orelse ".";
    // Opened as a file so the descriptor can be fsynced directly; `std.Io.Dir`
    // exposes no sync of its own and its handle is not an fsync-able fd.
    const directory = try std.Io.Dir.cwd().openFile(io, directory_path, .{});
    defer directory.close(io);
    try directory.sync(io);
}

/// Sync every distinct directory named by `paths`. Tag replacement usually
/// keeps stage, backup and source in one directory, so this is one fsync.
fn syncContainingDirectories(io: std.Io, paths: []const []const u8) !void {
    for (paths, 0..) |path, index| {
        const directory_path = std.Io.Dir.path.dirname(path) orelse ".";
        var already_synced = false;
        for (paths[0..index]) |earlier| {
            const earlier_directory = std.Io.Dir.path.dirname(earlier) orelse ".";
            if (std.mem.eql(u8, earlier_directory, directory_path)) already_synced = true;
        }
        if (!already_synced) try syncContainingDirectory(io, path);
    }
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
    try requireIdentity(io, source, stat, expected);

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
    try syncContainingDirectory(io, stage_path);
}

/// Create and fsync a complete FLAC replacement with rewritten Vorbis comments.
/// Audio frames and metadata blocks not owned by Orca are copied byte-for-byte.
pub fn stageFlac(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    stage_path: []const u8,
    expected: mutation.FileIdentity,
    changes: []const mutation.Change,
) !void {
    const source = try std.Io.Dir.cwd().openFile(io, source_path, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    try requireIdentity(io, source, stat, expected);
    var magic: [4]u8 = undefined;
    try readExact(source, io, &magic, 0);
    if (!std.mem.eql(u8, &magic, "fLaC")) return error.InvalidFlacStream;

    const stage = try std.Io.Dir.cwd().createFile(io, stage_path, .{
        .exclusive = true,
        .permissions = stat.permissions,
    });
    errdefer {
        stage.close(io);
        std.Io.Dir.cwd().deleteFile(io, stage_path) catch {};
    }
    try stage.writeStreamingAll(io, &magic);
    var offset: u64 = magic.len;
    var block_index: usize = 0;
    var found_comment = false;
    while (true) : (block_index += 1) {
        var header: [4]u8 = undefined;
        try readExact(source, io, &header, offset);
        offset += header.len;
        const is_last = header[0] & 0x80 != 0;
        const block_type = header[0] & 0x7f;
        const length = readU24(header[1..4]);
        if (block_index == 0 and (block_type != 0 or length != 34))
            return error.InvalidFlacStream;
        if (offset + length > stat.size) return error.InvalidFlacStream;

        if (block_type == 4) {
            if (found_comment) return error.MultipleVorbisCommentBlocks;
            found_comment = true;
            const payload = try allocator.alloc(u8, length);
            defer allocator.free(payload);
            try readExact(source, io, payload, offset);
            const rewritten = try vorbis_comment.rewrite(allocator, payload, changes);
            defer allocator.free(rewritten);
            if (rewritten.len > max_flac_metadata_block_size)
                return error.MetadataValueTooLong;
            try writeMetadataHeader(stage, io, is_last, 4, @intCast(rewritten.len));
            try stage.writeStreamingAll(io, rewritten);
        } else {
            if (is_last and !found_comment) header[0] &= 0x7f;
            try stage.writeStreamingAll(io, &header);
            try copyRange(source, stage, io, offset, length);
        }
        offset += length;
        if (is_last) {
            if (!found_comment) {
                const created = try vorbis_comment.create(allocator, changes);
                defer allocator.free(created);
                if (created.len > max_flac_metadata_block_size)
                    return error.MetadataValueTooLong;
                try writeMetadataHeader(stage, io, true, 4, @intCast(created.len));
                try stage.writeStreamingAll(io, created);
            }
            break;
        }
    }
    try copyRange(source, stage, io, offset, stat.size - offset);
    try stage.sync(io);
    stage.close(io);
    try syncContainingDirectory(io, stage_path);
}

/// Replace the source while retaining its exact previous bytes at `backup_path`.
///
/// The source identity is revalidated immediately before the first rename: an
/// external edit between staging and commit must not be replaced silently. Both
/// rename boundaries fsync the containing directories so a power loss cannot
/// leave the namespace behind the committed SQLite journal.
pub fn commitReplacement(
    io: std.Io,
    source_path: []const u8,
    stage_path: []const u8,
    backup_path: []const u8,
    expected: mutation.FileIdentity,
) !void {
    return commitReplacementInterrupted(io, source_path, stage_path, backup_path, expected, null);
}

pub fn commitReplacementInterrupted(
    io: std.Io,
    source_path: []const u8,
    stage_path: []const u8,
    backup_path: []const u8,
    expected: mutation.FileIdentity,
    interrupt: ?Interrupt,
) !void {
    const cwd = std.Io.Dir.cwd();
    {
        const source = try cwd.openFile(io, source_path, .{});
        defer source.close(io);
        const stat = try source.stat(io);
        try requireIdentity(io, source, stat, expected);
    }
    try cwd.rename(source_path, cwd, backup_path, io);
    try syncContainingDirectories(io, &.{ source_path, backup_path });
    if (interrupt == .after_backup_rename) return error.SimulatedPowerLoss;
    {
        errdefer {
            cwd.rename(backup_path, cwd, source_path, io) catch {};
            syncContainingDirectories(io, &.{ source_path, backup_path }) catch {};
        }
        try cwd.rename(stage_path, cwd, source_path, io);
    }
    try syncContainingDirectories(io, &.{ source_path, stage_path });
    if (interrupt == .after_source_rename) return error.SimulatedPowerLoss;
}

/// Move `source_path` onto `destination_path` without clobbering an existing
/// destination, syncing both namespaces.
pub fn commitMove(io: std.Io, source_path: []const u8, destination_path: []const u8) !void {
    try std.Io.Dir.cwd().renamePreserve(
        source_path,
        std.Io.Dir.cwd(),
        destination_path,
        io,
    );
    try syncContainingDirectories(io, &.{ source_path, destination_path });
}

pub fn rollbackReplacement(
    io: std.Io,
    source_path: []const u8,
    backup_path: []const u8,
    displaced_path: []const u8,
) !void {
    return rollbackReplacementInterrupted(io, source_path, backup_path, displaced_path, null);
}

pub fn rollbackReplacementInterrupted(
    io: std.Io,
    source_path: []const u8,
    backup_path: []const u8,
    displaced_path: []const u8,
    interrupt: ?Interrupt,
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
    if (displaced) try syncContainingDirectories(io, &.{ source_path, displaced_path });
    if (interrupt == .after_rollback_displace) return error.SimulatedPowerLoss;
    {
        errdefer if (displaced) {
            cwd.rename(displaced_path, cwd, source_path, io) catch {};
            syncContainingDirectories(io, &.{ source_path, displaced_path }) catch {};
        };
        try cwd.rename(backup_path, cwd, source_path, io);
    }
    try syncContainingDirectories(io, &.{ source_path, backup_path });
    if (interrupt == .after_rollback_restore) return error.SimulatedPowerLoss;
    if (displaced) {
        try cwd.deleteFile(io, displaced_path);
        try syncContainingDirectory(io, displaced_path);
    }
}

fn requireIdentity(
    io: std.Io,
    file: std.Io.File,
    stat: std.Io.File.Stat,
    expected: mutation.FileIdentity,
) !void {
    const modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse
        return error.FileTimestampOutOfRange;
    if (stat.size != expected.size_bytes or modified_ns != expected.modified_ns)
        return error.FileIdentityChanged;
    const digest = try quick_hash.fromFile(io, file, stat.size);
    if (!std.mem.eql(u8, &digest, &expected.quick_hash)) return error.FileIdentityChanged;
}

fn readExact(file: std.Io.File, io: std.Io, destination: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, destination, offset) != destination.len)
        return error.UnexpectedEndOfFile;
}

fn copyRange(
    source: std.Io.File,
    destination: std.Io.File,
    io: std.Io,
    start: u64,
    length: u64,
) !void {
    var copied: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (copied < length) {
        const requested: usize = @intCast(@min(length - copied, buffer.len));
        const read_count = try source.readPositional(io, &.{buffer[0..requested]}, start + copied);
        if (read_count == 0) return error.UnexpectedEndOfFile;
        try destination.writeStreamingAll(io, buffer[0..read_count]);
        copied += read_count;
    }
}

fn readU24(bytes: *const [3]u8) u32 {
    return @as(u32, bytes[0]) << 16 | @as(u32, bytes[1]) << 8 | bytes[2];
}

fn writeMetadataHeader(
    file: std.Io.File,
    io: std.Io,
    is_last: bool,
    block_type: u7,
    length: u24,
) !void {
    const header = [4]u8{
        @as(u8, block_type) | @as(u8, if (is_last) 0x80 else 0),
        @intCast(length >> 16),
        @intCast(length >> 8),
        @intCast(length),
    };
    try file.writeStreamingAll(io, &header);
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
    try std.testing.expect(expected.eql(try identity(std.testing.io, source_path)));
    try commitReplacement(std.testing.io, source_path, stage_path, backup_path, expected);
    try expectTitle(source_path, "New title");
    try expectTitle(backup_path, "Old title");
    try rollbackReplacement(std.testing.io, source_path, backup_path, stage_path);
    try expectTitle(source_path, "Old title");
}

test "FLAC replacement rewrites comments and preserves audio bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.flac", .{prefix});
    defer std.testing.allocator.free(source_path);
    const stage_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/stage.flac", .{prefix});
    defer std.testing.allocator.free(stage_path);
    var comments: std.ArrayList(u8) = .empty;
    defer comments.deinit(std.testing.allocator);
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, 9, .little);
    try comments.appendSlice(std.testing.allocator, &length);
    try comments.appendSlice(std.testing.allocator, "Generated");
    std.mem.writeInt(u32, &length, 1, .little);
    try comments.appendSlice(std.testing.allocator, &length);
    std.mem.writeInt(u32, &length, 15, .little);
    try comments.appendSlice(std.testing.allocator, &length);
    try comments.appendSlice(std.testing.allocator, "TITLE=Old title");
    var source_bytes: std.ArrayList(u8) = .empty;
    defer source_bytes.deinit(std.testing.allocator);
    try source_bytes.appendSlice(std.testing.allocator, "fLaC\x00\x00\x00\x22");
    try source_bytes.appendNTimes(std.testing.allocator, 0, 34);
    const comment_length: u24 = @intCast(comments.items.len);
    try source_bytes.appendSlice(std.testing.allocator, &.{
        0x84,
        @intCast(comment_length >> 16),
        @intCast(comment_length >> 8),
        @intCast(comment_length),
    });
    try source_bytes.appendSlice(std.testing.allocator, comments.items);
    try source_bytes.appendSlice(std.testing.allocator, "generated audio frames");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.flac",
        .data = source_bytes.items,
    });
    const expected = try identity(std.testing.io, source_path);
    try stageFlac(
        std.testing.allocator,
        std.testing.io,
        source_path,
        stage_path,
        expected,
        &.{.{ .field = .title, .before = "Old title", .after = "New title" }},
    );
    const stage = try std.Io.Dir.cwd().openFile(std.testing.io, stage_path, .{});
    defer stage.close(std.testing.io);
    const stat = try stage.stat(std.testing.io);
    const staged = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(staged);
    try readExact(stage, std.testing.io, staged, 0);
    try std.testing.expect(std.mem.indexOf(u8, staged, "TITLE=New title") != null);
    try std.testing.expect(std.mem.endsWith(u8, staged, "generated audio frames"));
}

test "FLAC replacement remains decodable by the Zig-native codec" {
    const flac_codec = @import("../codec/flac.zig");
    const storage = @import("../storage/root.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const stage_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/tagged.flac",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(stage_path);
    const source_path = "fixtures/audio/generated-reference.flac";
    try stageFlac(
        std.testing.allocator,
        std.testing.io,
        source_path,
        stage_path,
        try identity(std.testing.io, source_path),
        &.{.{ .field = .title, .before = null, .after = "Generated reference" }},
    );
    var source = try storage.LocalFileSource.open(std.testing.io, stage_path);
    defer source.close();
    var decoder = try flac_codec.openDecoder(std.testing.allocator, source.readable());
    defer decoder.deinit();
    var samples: [64]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 32), try decoder.readFrames(&samples));
}

fn expectTitle(path: []const u8, expected: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    var bytes: [128]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &bytes, stat.size - bytes.len);
    try std.testing.expectEqualStrings(expected, id3v1.parse(&bytes).?.title);
}

/// Rewrite bytes in place and restore the original modification timestamp, so
/// the file is byte-different but (size, mtime) identical.
fn forgeInPlaceEdit(path: []const u8, offset: u64, replacement: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const before = try file.stat(std.testing.io);
    try file.writePositionalAll(std.testing.io, replacement, offset);
    try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = before.mtime } });
    const after = try file.stat(std.testing.io);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

test "staging rejects a same-size edit that preserved the modification time" {
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
    const tag = try id3v1.encode(.{
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
        .data = "generated audio payload" ++ tag,
    });
    const expected = try identity(std.testing.io, source_path);
    try forgeInPlaceEdit(source_path, 0, "GENERATED");
    try std.testing.expect(!expected.eql(try identity(std.testing.io, source_path)));
    try std.testing.expectError(error.FileIdentityChanged, stageId3v1(
        std.testing.io,
        source_path,
        stage_path,
        expected,
        &.{.{ .field = .title, .before = "Old title", .after = "New title" }},
    ));
}

test "commit refuses to replace a source edited between staging and rename" {
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
    const tag = try id3v1.encode(.{
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
        .data = "generated audio payload" ++ tag,
    });
    const expected = try identity(std.testing.io, source_path);
    try stageId3v1(std.testing.io, source_path, stage_path, expected, &.{.{
        .field = .title,
        .before = "Old title",
        .after = "New title",
    }});
    try forgeInPlaceEdit(source_path, 0, "GENERATED");
    try std.testing.expectError(error.FileIdentityChanged, commitReplacement(
        std.testing.io,
        source_path,
        stage_path,
        backup_path,
        expected,
    ));
    try expectTitle(source_path, "Old title");
    try std.testing.expect(std.Io.Dir.cwd().openFile(std.testing.io, backup_path, .{}) ==
        error.FileNotFound);
}
