const std = @import("std");
const quick_hash = @import("quick_hash.zig");

const Blake3 = std.crypto.hash.Blake3;

pub const Digest = [Blake3.digest_length]u8;

/// BLAKE3-256 over every byte of the file, streamed through a fixed buffer.
/// Unlike the quick hash, equal digests mean equal content.
pub fn fromFile(io: std.Io, file: std.Io.File, size: u64) !Digest {
    return fromFileCancellable(io, file, size, null);
}

/// `fromFile`, returning `error.Cancelled` as soon as `context.cancelled()`
/// says so between chunks. A `null` context is never cancelled.
pub fn fromFileCancellable(io: std.Io, file: std.Io.File, size: u64, context: anytype) !Digest {
    var hasher = Blake3.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        if (@TypeOf(context) != @TypeOf(null)) {
            if (context.cancelled()) return error.Cancelled;
        }
        const wanted: usize = @intCast(@min(buffer.len, size - offset));
        const read = try file.readPositional(io, &.{buffer[0..wanted]}, offset);
        if (read == 0) return error.UnexpectedEndOfFile;
        hasher.update(buffer[0..read]);
        offset += read;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn fromPath(io: std.Io, path: []const u8) !Digest {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return fromFile(io, file, stat.size);
}

test "content hashes match a one-shot hash and catch an edit the quick hash misses" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const size = 2 * quick_hash.window_bytes + 4096;
    const payload = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large.bin", .data = payload });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/large.bin",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    var expected: Digest = undefined;
    Blake3.hash(payload, &expected, .{});
    const before = try fromPath(std.testing.io, path);
    try std.testing.expectEqualSlices(u8, &expected, &before);
    const quick_before = try quick_hash.fromPath(std.testing.io, path);

    payload[size / 2] +%= 1;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large.bin", .data = payload });
    try std.testing.expectEqualSlices(u8, &quick_before, &(try quick_hash.fromPath(std.testing.io, path)));
    try std.testing.expect(!std.mem.eql(u8, &before, &(try fromPath(std.testing.io, path))));
}
