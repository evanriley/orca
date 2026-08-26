const std = @import("std");
const source_module = @import("source.zig");

const ReadableSource = source_module.ReadableSource;

/// Number of leading and trailing bytes covered by a quick hash.
pub const window_bytes = 64 * 1024;

pub const Digest = [std.crypto.hash.Blake3.digest_length]u8;

pub const zero: Digest = @splat(0);

/// A cheap, storage-independent content signature: BLAKE3 over
/// (first 64 KiB ‖ last 64 KiB ‖ size). Two positional reads regardless of file
/// length, so it is affordable in a scanner, in a mutation identity check, and
/// as an analysis cache key. Files shorter than one window hash their bytes
/// twice, which keeps the definition a single unconditional shape.
pub fn fromSource(source: ReadableSource) !Digest {
    const Context = struct {
        source: ReadableSource,
        fn readAll(self: @This(), offset: u64, destination: []u8) !void {
            var filled: usize = 0;
            while (filled < destination.len) {
                const read = try self.source.readAt(offset + filled, destination[filled..]);
                if (read == 0) return error.UnexpectedEndOfFile;
                filled += read;
            }
        }
    };
    return compute(Context{ .source = source }, source.size());
}

pub fn fromFile(io: std.Io, file: std.Io.File, size: u64) !Digest {
    const Context = struct {
        io: std.Io,
        file: std.Io.File,
        fn readAll(self: @This(), offset: u64, destination: []u8) !void {
            if (try self.file.readPositionalAll(self.io, destination, offset) != destination.len)
                return error.UnexpectedEndOfFile;
        }
    };
    return compute(Context{ .io = io, .file = file }, size);
}

pub fn fromPath(io: std.Io, path: []const u8) !Digest {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return fromFile(io, file, stat.size);
}

fn compute(context: anytype, size: u64) !Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buffer: [window_bytes]u8 = undefined;
    const covered: usize = @intCast(@min(size, window_bytes));
    try context.readAll(0, buffer[0..covered]);
    hasher.update(buffer[0..covered]);
    try context.readAll(size - covered, buffer[0..covered]);
    hasher.update(buffer[0..covered]);
    var size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_bytes, size, .little);
    hasher.update(&size_bytes);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

test "quick hashes separate same-size content and agree across source kinds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "first.bin",
        .data = "generated payload A",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "second.bin",
        .data = "generated payload B",
    });
    const first_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/first.bin",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(first_path);
    const second_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/second.bin",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(second_path);

    const first = try fromPath(std.testing.io, first_path);
    const second = try fromPath(std.testing.io, second_path);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));

    var local = try source_module.LocalFileSource.open(std.testing.io, first_path);
    defer local.close();
    try std.testing.expectEqualSlices(u8, &first, &(try fromSource(local.readable())));
}

test "quick hashes cover trailing bytes of a file larger than one window" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const size = window_bytes + 4096;
    const payload = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large.bin", .data = payload });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/large.bin",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    const before = try fromPath(std.testing.io, path);

    payload[size - 1] +%= 1;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large.bin", .data = payload });
    try std.testing.expect(!std.mem.eql(u8, &before, &(try fromPath(std.testing.io, path))));
}
