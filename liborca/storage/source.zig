const std = @import("std");

pub const StorageIdentity = struct {
    inode: std.Io.File.INode,
    size: u64,
    modified_ns: i96,
};

/// Minimal capability interface consumed by decoders and analysis. Implementors
/// need not represent local paths, only bounded reads and stable source facts.
pub const ReadableSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_at: *const fn (*anyopaque, u64, []u8) anyerror!usize,
        size: *const fn (*anyopaque) u64,
        identity: *const fn (*anyopaque) StorageIdentity,
    };

    pub fn readAt(self: ReadableSource, offset: u64, buffer: []u8) !usize {
        return self.vtable.read_at(self.context, offset, buffer);
    }

    pub fn size(self: ReadableSource) u64 {
        return self.vtable.size(self.context);
    }

    pub fn identity(self: ReadableSource) StorageIdentity {
        return self.vtable.identity(self.context);
    }
};

/// Bridges Orca's positional source capability to Zig's buffered Reader API.
/// Codec adapters own this object so the interface and backing buffer remain at
/// stable addresses for the decoder lifetime.
pub const BufferedSourceReader = struct {
    source: ReadableSource,
    interface: std.Io.Reader,
    physical_position: u64 = 0,

    pub fn init(source: ReadableSource, buffer: []u8) BufferedSourceReader {
        return .{
            .source = source,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn seekTo(self: *BufferedSourceReader, offset: u64) !void {
        if (offset > self.source.size()) return error.OutOfBounds;
        self.physical_position = offset;
        self.interface.seek = 0;
        self.interface.end = 0;
    }

    pub fn logicalPosition(self: *const BufferedSourceReader) u64 {
        return self.physical_position - (self.interface.end - self.interface.seek);
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *BufferedSourceReader = @fieldParentPtr("interface", reader);
        var temporary: [4096]u8 = undefined;
        const destination = limit.slice(&temporary);
        if (destination.len == 0) return 0;
        const read = self.source.readAt(self.physical_position, destination) catch
            return error.ReadFailed;
        if (read == 0) return error.EndOfStream;
        const written = writer.write(destination[0..read]) catch return error.WriteFailed;
        self.physical_position += written;
        return written;
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *BufferedSourceReader = @fieldParentPtr("interface", reader);
        if (data[0].len > 0) {
            const read = self.source.readAt(self.physical_position, data[0]) catch
                return error.ReadFailed;
            if (read == 0) return error.EndOfStream;
            self.physical_position += read;
            return read;
        }
        const destination = reader.buffer[reader.end..];
        const read = self.source.readAt(self.physical_position, destination) catch
            return error.ReadFailed;
        if (read == 0) return error.EndOfStream;
        reader.end += read;
        self.physical_position += read;
        return 0;
    }

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
        .readVec = readVec,
    };
};

/// An in-memory `ReadableSource`, for tests and for callers that already hold
/// the bytes. Identity is synthetic and stable for the buffer it was built from.
pub const MemorySource = struct {
    bytes: []const u8,
    inode: std.Io.File.INode = 0,
    modified_ns: i96 = 0,

    pub fn readable(self: *MemorySource) ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *MemorySource = @ptrCast(@alignCast(context));
        if (offset >= self.bytes.len) return 0;
        const start: usize = @intCast(offset);
        const count = @min(buffer.len, self.bytes.len - start);
        @memcpy(buffer[0..count], self.bytes[start .. start + count]);
        return count;
    }

    fn getSize(context: *anyopaque) u64 {
        const self: *MemorySource = @ptrCast(@alignCast(context));
        return self.bytes.len;
    }

    fn getIdentity(context: *anyopaque) StorageIdentity {
        const self: *MemorySource = @ptrCast(@alignCast(context));
        return .{
            .inode = self.inode,
            .size = self.bytes.len,
            .modified_ns = self.modified_ns,
        };
    }

    const vtable = ReadableSource.VTable{
        .read_at = readAt,
        .size = getSize,
        .identity = getIdentity,
    };
};

/// Presents the bytes of another source from a fixed offset onward as if the
/// stream began there.
///
/// A container prefix that belongs to no encoding — an ID3v2 tag in front of a
/// FLAC stream — is a fact about the file, not about the codec, so the decoder
/// is handed a view rather than taught to skip it. Reads and sizes shift;
/// `identity` deliberately does **not**. Identity answers "which file is this
/// and has it changed", which scanning compares against `observed_files`, and a
/// view that reported a shortened size would make every tagged file look
/// modified on the next scan.
///
/// The view borrows `inner` and must not outlive it, and whatever holds the
/// view must outlive the decoder reading through it.
pub const OffsetSource = struct {
    inner: ReadableSource,
    offset: u64,

    pub fn readable(self: *OffsetSource) ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *OffsetSource = @ptrCast(@alignCast(context));
        const absolute = std.math.add(u64, self.offset, offset) catch return 0;
        if (absolute >= self.inner.size()) return 0;
        return self.inner.readAt(absolute, buffer);
    }

    fn getSize(context: *anyopaque) u64 {
        const self: *OffsetSource = @ptrCast(@alignCast(context));
        return self.inner.size() -| self.offset;
    }

    fn getIdentity(context: *anyopaque) StorageIdentity {
        const self: *OffsetSource = @ptrCast(@alignCast(context));
        return self.inner.identity();
    }

    const vtable = ReadableSource.VTable{
        .read_at = readAt,
        .size = getSize,
        .identity = getIdentity,
    };
};

pub const LocalFileSource = struct {
    io: std.Io,
    file: std.Io.File,
    stat: std.Io.File.Stat,

    pub fn open(io: std.Io, path: []const u8) !LocalFileSource {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        return .{
            .io = io,
            .file = file,
            .stat = try file.stat(io),
        };
    }

    pub fn close(self: *LocalFileSource) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn readable(self: *LocalFileSource) ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *LocalFileSource = @ptrCast(@alignCast(context));
        return self.file.readPositionalAll(self.io, buffer, offset);
    }

    fn getSize(context: *anyopaque) u64 {
        const self: *LocalFileSource = @ptrCast(@alignCast(context));
        return self.stat.size;
    }

    fn getIdentity(context: *anyopaque) StorageIdentity {
        const self: *LocalFileSource = @ptrCast(@alignCast(context));
        return .{
            .inode = self.stat.inode,
            .size = self.stat.size,
            .modified_ns = self.stat.mtime.nanoseconds,
        };
    }

    const vtable = ReadableSource.VTable{
        .read_at = readAt,
        .size = getSize,
        .identity = getIdentity,
    };
};

test "local files satisfy offset reads and identity capabilities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.bin",
        .data = "orca-source",
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/source.bin",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    var local = try LocalFileSource.open(std.testing.io, path);
    defer local.close();
    const source = local.readable();
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try source.readAt(5, &buffer));
    try std.testing.expectEqualStrings("source", &buffer);
    try std.testing.expectEqual(@as(u64, 11), source.size());
    try std.testing.expectEqual(source.size(), source.identity().size);
}

test "memory sources answer bounded reads past their end" {
    var memory = MemorySource{ .bytes = "orca" };
    const readable = memory.readable();
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try readable.readAt(2, &buffer));
    try std.testing.expectEqualStrings("ca", buffer[0..2]);
    try std.testing.expectEqual(@as(usize, 0), try readable.readAt(4, &buffer));
    try std.testing.expectEqual(@as(u64, 4), readable.size());
}

test "an offset view reads a suffix while still reporting the whole file's identity" {
    var memory = MemorySource{ .bytes = "ID3-tag-bytesfLaCstream", .inode = 77 };
    var view = OffsetSource{ .inner = memory.readable(), .offset = 13 };
    const readable = view.readable();

    var buffer: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), try readable.readAt(0, &buffer));
    try std.testing.expectEqualStrings("fLaCstream", &buffer);
    try std.testing.expectEqual(@as(usize, 6), try readable.readAt(4, &buffer));
    try std.testing.expectEqualStrings("stream", buffer[0..6]);
    try std.testing.expectEqual(@as(u64, 10), readable.size());

    // Change detection asks the file, not the view: a shortened size or a lost
    // inode here would make every tagged file look modified on the next scan.
    try std.testing.expectEqual(@as(u64, 23), readable.identity().size);
    try std.testing.expectEqual(@as(std.Io.File.INode, 77), readable.identity().inode);
}

test "an offset view past the end of its source reads nothing rather than wrapping" {
    var memory = MemorySource{ .bytes = "short" };
    var view = OffsetSource{ .inner = memory.readable(), .offset = 64 };
    const readable = view.readable();
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try readable.readAt(0, &buffer));
    try std.testing.expectEqual(@as(usize, 0), try readable.readAt(std.math.maxInt(u64), &buffer));
    try std.testing.expectEqual(@as(u64, 0), readable.size());
}
