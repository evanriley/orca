const builtin = @import("builtin");
const std = @import("std");
const id3v1 = @import("id3v1.zig");
const id3v2 = @import("id3v2.zig");
const mutation = @import("mutation.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const storage_source = @import("../storage/source.zig");
const vorbis_comment = @import("vorbis_comment.zig");

const max_flac_metadata_block_size = (1 << 24) - 1;

/// Points at which a mutation can be interrupted by power loss. Production
/// callers pass null; recovery tests drive the same code path and stop it at a
/// real boundary rather than simulating one.
pub const Interrupt = enum {
    after_backup_copy,
    after_source_rename,
    after_restore_copy,
    after_restore_rename,
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

/// Sync every distinct directory named by `paths`. A replacement keeps its
/// stage or restore file beside the source, so this is usually one fsync.
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

/// Create and fsync a complete MPEG-audio or ADTS replacement whose leading
/// ID3v2 tag carries `changes`. The audio between the old tag and any ID3v1
/// trailer is copied byte for byte; see `id3v2.rewrite` for what the tag keeps.
pub fn stageMpeg(
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

    var readable = try storage_source.LocalFileSource.open(io, source_path);
    defer readable.close();
    const planned = try id3v2.rewrite(allocator, readable.readable(), changes);
    defer planned.deinit();
    if (planned.audio_start > planned.audio_end or planned.audio_end > stat.size)
        return error.InvalidMpegStream;

    const stage = try std.Io.Dir.cwd().createFile(io, stage_path, .{
        .exclusive = true,
        .permissions = stat.permissions,
    });
    errdefer {
        stage.close(io);
        std.Io.Dir.cwd().deleteFile(io, stage_path) catch {};
    }
    try stage.writeStreamingAll(io, planned.tag);
    try copyRange(source, stage, io, planned.audio_start, planned.audio_end - planned.audio_start);
    if (planned.trailer) |trailer| try stage.writeStreamingAll(io, &trailer);
    try stage.sync(io);
    stage.close(io);
    try syncContainingDirectory(io, stage_path);
}

/// Copy the source to `backup_path`, then rename the stage onto the source.
///
/// The backup is fsynced and verified to be `expected` before the source is
/// touched, and the source is revalidated immediately before the rename, so at
/// every point either the original is in place or a durable verified copy of it
/// exists.
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
    try requireIdentityAt(io, source_path, expected);
    try copyVerified(io, source_path, backup_path, expected);
    if (interrupt == .after_backup_copy) return error.SimulatedPowerLoss;
    try replaceVerified(io, stage_path, source_path, expected);
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

/// Copy the backup to `restore_path`, verify it is `original`, and rename it
/// onto the source, which must still be `replacing`. The backup is left in
/// place.
pub fn restoreFromBackup(
    io: std.Io,
    source_path: []const u8,
    backup_path: []const u8,
    restore_path: []const u8,
    original: mutation.FileIdentity,
    replacing: mutation.FileIdentity,
) !void {
    return restoreFromBackupInterrupted(io, source_path, backup_path, restore_path, original, replacing, null);
}

pub fn restoreFromBackupInterrupted(
    io: std.Io,
    source_path: []const u8,
    backup_path: []const u8,
    restore_path: []const u8,
    original: mutation.FileIdentity,
    replacing: mutation.FileIdentity,
    interrupt: ?Interrupt,
) !void {
    try deleteIfPresent(io, restore_path);
    try copyVerified(io, backup_path, restore_path, original);
    if (interrupt == .after_restore_copy) return error.SimulatedPowerLoss;
    replaceVerified(io, restore_path, source_path, replacing) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, restore_path) catch {};
        return err;
    };
    if (interrupt == .after_restore_rename) return error.SimulatedPowerLoss;
}

pub fn copyVerified(
    io: std.Io,
    source_path: []const u8,
    copy_path: []const u8,
    expected: mutation.FileIdentity,
) !void {
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.openFile(io, source_path, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    const copy = try cwd.createFile(io, copy_path, .{
        .read = true,
        .exclusive = true,
        .permissions = stat.permissions,
    });
    var copy_open = true;
    errdefer {
        if (copy_open) copy.close(io);
        cwd.deleteFile(io, copy_path) catch {};
    }
    try copyRange(source, copy, io, 0, stat.size);
    try copy.setTimestamps(io, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = expected.modified_ns } },
    });
    try copy.sync(io);
    const copied = try identityOfFile(io, copy);
    copy_open = false;
    copy.close(io);
    if (!copied.eql(expected)) return error.CopyIdentityMismatch;
    try syncContainingDirectory(io, copy_path);
}

pub fn createDirectoryDurably(io: std.Io, directory_path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, directory_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    try syncContainingDirectory(io, directory_path);
}

pub fn deleteIfPresent(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try syncContainingDirectory(io, path);
}

fn replaceVerified(
    io: std.Io,
    replacement_path: []const u8,
    target_path: []const u8,
    target_expected: mutation.FileIdentity,
) !void {
    try requireIdentityAt(io, target_path, target_expected);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(replacement_path, cwd, target_path, io);
    try syncContainingDirectories(io, &.{ target_path, replacement_path });
}

fn requireIdentityAt(io: std.Io, path: []const u8, expected: mutation.FileIdentity) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try requireIdentity(io, file, try file.stat(io), expected);
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

test "a replacement keeps an identical backup and a restore puts the original back" {
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
        .data = "\xff\xfb\x90\x64generated audio payload" ++ original_tag,
    });
    const expected = try identity(std.testing.io, source_path);
    try stageMpeg(std.testing.allocator, std.testing.io, source_path, stage_path, expected, &.{.{
        .field = .title,
        .before = "Old title",
        .after = "New title",
    }});
    try std.testing.expect(expected.eql(try identity(std.testing.io, source_path)));
    try commitReplacement(std.testing.io, source_path, stage_path, backup_path, expected);
    try expectTitle(source_path, "New title");
    try std.testing.expect(expected.eql(try identity(std.testing.io, backup_path)));
    try std.testing.expectError(error.FileNotFound, identity(std.testing.io, stage_path));

    const restore_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.restore.mp3", .{prefix});
    defer std.testing.allocator.free(restore_path);
    const replaced = try identity(std.testing.io, source_path);
    try restoreFromBackup(std.testing.io, source_path, backup_path, restore_path, expected, replaced);
    try std.testing.expect(expected.eql(try identity(std.testing.io, source_path)));
    try std.testing.expectError(error.FileNotFound, identity(std.testing.io, restore_path));
    try std.testing.expect(expected.eql(try identity(std.testing.io, backup_path)));
}

test "a restore leaves alone a source that changed after the write" {
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
    const restore_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.restore.mp3", .{prefix});
    defer std.testing.allocator.free(restore_path);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.mp3",
        .data = "\xff\xfb\x90\x64generated audio payload" ++ try id3v1.encode(.{
            .title = "Old title",
            .artist = "Generated artist",
            .album = "Generated album",
            .year = "2026",
            .comment = "Generated",
            .track_number = 1,
            .genre = 13,
        }),
    });
    const expected = try identity(std.testing.io, source_path);
    try stageMpeg(std.testing.allocator, std.testing.io, source_path, stage_path, expected, &.{.{
        .field = .title,
        .before = "Old title",
        .after = "New title",
    }});
    try commitReplacement(std.testing.io, source_path, stage_path, backup_path, expected);
    const replaced = try identity(std.testing.io, source_path);
    try forgeInPlaceEdit(source_path, 0, "GENERATED");

    try std.testing.expectError(error.FileIdentityChanged, restoreFromBackup(
        std.testing.io,
        source_path,
        backup_path,
        restore_path,
        expected,
        replaced,
    ));
    try expectTitle(source_path, "New title");
    try std.testing.expectError(error.FileNotFound, identity(std.testing.io, restore_path));
    try std.testing.expect(expected.eql(try identity(std.testing.io, backup_path)));
}

test "a copy that does not come out as the expected identity is deleted" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.bin", .{prefix});
    defer std.testing.allocator.free(source_path);
    const copy_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/copy.bin", .{prefix});
    defer std.testing.allocator.free(copy_path);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.bin", .data = "generated bytes" });
    var expected = try identity(std.testing.io, source_path);
    expected.quick_hash[0] ^= 1;

    try std.testing.expectError(
        error.CopyIdentityMismatch,
        copyVerified(std.testing.io, source_path, copy_path, expected),
    );
    try std.testing.expectError(error.FileNotFound, identity(std.testing.io, copy_path));
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
        .data = "\xff\xfb\x90\x64generated audio payload" ++ tag,
    });
    const expected = try identity(std.testing.io, source_path);
    try forgeInPlaceEdit(source_path, 0, "GENERATED");
    try std.testing.expect(!expected.eql(try identity(std.testing.io, source_path)));
    try std.testing.expectError(error.FileIdentityChanged, stageMpeg(
        std.testing.allocator,
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
        .data = "\xff\xfb\x90\x64generated audio payload" ++ tag,
    });
    const expected = try identity(std.testing.io, source_path);
    try stageMpeg(std.testing.allocator, std.testing.io, source_path, stage_path, expected, &.{.{
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
