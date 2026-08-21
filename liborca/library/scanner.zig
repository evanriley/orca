const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");

pub const CancellationToken = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.requested.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.requested.load(.acquire);
    }
};

pub const Result = struct {
    files_seen: u64 = 0,
    changed: u64 = 0,
    unchanged: u64 = 0,
    unsupported: u64 = 0,
    errors: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    observed_files: *database.ObservedFileRepository,
    cancellation: ?*const CancellationToken = null,
    batch_size: usize = 256,

    pub fn scan(self: *Scanner, root_path: []const u8) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        if (self.cancellation) |token| {
            if (token.isCancelled()) return .{ .cancelled = true };
        }
        const root = try std.Io.Dir.cwd().openDir(self.io, root_path, .{ .iterate = true });
        defer root.close(self.io);
        var walker = try root.walk(self.allocator);
        defer walker.deinit();

        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }
        var pending: std.ArrayList(database.ObservedFileInput) = .empty;
        defer pending.deinit(self.allocator);
        var metadata_values: std.ArrayList([]u8) = .empty;
        defer {
            for (metadata_values.items) |value| self.allocator.free(value);
            metadata_values.deinit(self.allocator);
        }
        var result: Result = .{};

        while (try walker.next(self.io)) |entry| {
            if (self.cancellation) |token| if (token.isCancelled()) {
                result.cancelled = true;
                break;
            };
            if (entry.kind != .file) continue;
            result.files_seen += 1;

            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ root_path, entry.path },
            );
            var local = storage.LocalFileSource.open(self.io, path) catch {
                self.allocator.free(path);
                result.errors += 1;
                continue;
            };
            defer local.close();
            const identity = local.readable().identity();
            const observed = database.ObservedFileInput{
                .path = path,
                .inode = std.math.cast(i64, identity.inode) orelse {
                    self.allocator.free(path);
                    result.errors += 1;
                    continue;
                },
                .size_bytes = std.math.cast(i64, identity.size) orelse {
                    self.allocator.free(path);
                    result.errors += 1;
                    continue;
                },
                .modified_ns = std.math.cast(i64, identity.modified_ns) orelse {
                    self.allocator.free(path);
                    result.errors += 1;
                    continue;
                },
                .audio_format = 0,
            };
            if (try self.observed_files.isUnchanged(observed)) {
                self.allocator.free(path);
                result.unchanged += 1;
                continue;
            }
            const audio_format = (try storage.format.sniff(local.readable())) orelse {
                self.allocator.free(path);
                result.unsupported += 1;
                continue;
            };
            var changed = observed;
            changed.audio_format = @backingInt(audio_format);
            paths.append(self.allocator, path) catch |err| {
                self.allocator.free(path);
                return err;
            };
            if (audio_format == .mp3) {
                var tag_buffer: [128]u8 = undefined;
                if (try metadata.id3v1.read(local.readable(), &tag_buffer)) |tag| {
                    changed.title = try self.ownText(&metadata_values, tag.title);
                    changed.artist = try self.ownText(&metadata_values, tag.artist);
                    changed.album = try self.ownText(&metadata_values, tag.album);
                    changed.track_number = if (tag.track_number) |number| number else null;
                }
            }
            try pending.append(self.allocator, changed);
            result.changed += 1;
            if (pending.items.len >= self.batch_size) {
                try self.flush(&paths, &pending, &metadata_values);
                result.batches_committed += 1;
            }
        }
        if (pending.items.len > 0) {
            try self.flush(&paths, &pending, &metadata_values);
            result.batches_committed += 1;
        }
        return result;
    }

    fn flush(
        self: *Scanner,
        paths: *std.ArrayList([]u8),
        pending: *std.ArrayList(database.ObservedFileInput),
        metadata_values: *std.ArrayList([]u8),
    ) !void {
        try self.observed_files.upsertBatch(pending.items);
        for (paths.items) |path| self.allocator.free(path);
        for (metadata_values.items) |value| self.allocator.free(value);
        paths.clearRetainingCapacity();
        pending.clearRetainingCapacity();
        metadata_values.clearRetainingCapacity();
    }

    fn ownText(
        self: *Scanner,
        values: *std.ArrayList([]u8),
        text: []const u8,
    ) !?[]const u8 {
        if (text.len == 0) return null;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try values.append(self.allocator, owned);
        return owned;
    }
};

test "scanner batches audio and skips unchanged files on restart" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "first.wav",
        .data = "RIFFxxxxWAVEfmt ",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "second.flac",
        .data = "fLaCgenerated",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "notes.txt",
        .data = "not audio",
    });
    var mp3: [256]u8 = @splat(0);
    @memcpy(mp3[0..3], "ID3");
    @memcpy(mp3[128..131], "TAG");
    @memcpy(mp3[131..145], "Observed title");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "tagged.mp3",
        .data = &mp3,
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-scanner-test?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .observed_files = &library.observed_files,
        .batch_size = 1,
    };

    const first = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 3), first.changed);
    try std.testing.expectEqual(@as(u64, 1), first.unsupported);
    try std.testing.expectEqual(@as(u64, 3), first.batches_committed);
    const second = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 0), second.changed);
    try std.testing.expectEqual(@as(u64, 3), second.unchanged);
    try std.testing.expectEqual(@as(u64, 3), try library.observed_files.count());
    const mp3_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/tagged.mp3",
        .{root_path},
    );
    defer std.testing.allocator.free(mp3_path);
    const observed_title = (try library.observed_files.title(
        std.testing.allocator,
        mp3_path,
    )).?;
    defer std.testing.allocator.free(observed_title);
    try std.testing.expectEqualStrings("Observed title", observed_title);
}

test "cancelled scans stop before filesystem work" {
    var token: CancellationToken = .{};
    token.cancel();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-cancelled-scanner?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .observed_files = &library.observed_files,
        .cancellation = &token,
    };
    const result = try scanner.scan(root_path);
    try std.testing.expect(result.cancelled);
}
