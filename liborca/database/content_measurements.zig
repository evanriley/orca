const std = @import("std");
const content_hash = @import("../storage/content_hash.zig");
const repository = @import("repository.zig");

const ContentEvidence = repository.ContentEvidence;
const ContentQuestion = repository.ContentQuestion;
const FileRepository = repository.FileRepository;
const MeasuredBytes = repository.MeasuredBytes;
const MeasuredLocation = repository.MeasuredLocation;
const StorageIdentityKey = repository.StorageIdentityKey;

/// Content hashes taken for the resolutions of one transaction, before it
/// begins.
///
/// `FileRepository.resolveForBytes` joins a path to a file through its quick
/// hash, and keeps a changed path on a file present at another path, only on
/// equal content hashes, and it runs under the write lane, where no file is
/// read. A caller measures here first what the resolution will
/// weigh, then hands it `evidence`. Clear between transactions: a measurement
/// is evidence only about the rows it was taken against.
pub const ContentMeasurements = struct {
    items: std.ArrayList(MeasuredLocation) = .empty,

    pub fn deinit(self: *ContentMeasurements, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.items.deinit(allocator);
    }

    pub fn clear(self: *ContentMeasurements, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item.uri);
        self.items.clearRetainingCapacity();
    }

    pub fn evidence(self: *const ContentMeasurements, own: ?*const content_hash.Digest) ContentEvidence {
        return .{ .own = own, .measured = self.items.items };
    }

    /// Notes the content hash of the bytes at `uri`, read by the caller while
    /// they had `identity`.
    pub fn record(
        self: *ContentMeasurements,
        allocator: std.mem.Allocator,
        uri: []const u8,
        identity: StorageIdentityKey,
        digest: *const content_hash.Digest,
    ) !void {
        if (self.find(identity.volume_id, uri) != null) return;
        try self.append(allocator, identity.volume_id, uri, .{ .read = .{ .identity = identity, .digest = digest.* } });
    }

    /// Hashes the bytes at `uri` unless they were measured already.
    pub fn measure(
        self: *ContentMeasurements,
        allocator: std.mem.Allocator,
        io: std.Io,
        volume_id: i64,
        uri: []const u8,
    ) error{ Canceled, OutOfMemory }!MeasuredBytes {
        if (self.find(volume_id, uri)) |bytes| return bytes;
        const bytes = try read(io, volume_id, uri);
        try self.append(allocator, volume_id, uri, bytes);
        return bytes;
    }

    /// Measures what resolving the bytes at `uri`, whose quick hash is
    /// `digest`, will weigh besides their own content hash: for tier 3, each
    /// file recording `digest` and no content hash, and for a changed path,
    /// the other copies of its file when it records no content hash. A
    /// file's locations are read in order until one is read as recorded.
    pub fn measureQuestion(
        self: *ContentMeasurements,
        allocator: std.mem.Allocator,
        io: std.Io,
        files: *const FileRepository,
        question: ContentQuestion,
        uri: []const u8,
        identity: StorageIdentityKey,
        digest: []const u8,
    ) !void {
        const locations = switch (question) {
            .none => return,
            .nominees => try files.nomineeLocations(allocator, uri, identity, digest),
            .copies => |file_id| try files.copyLocations(allocator, file_id, uri, identity),
        };
        defer locations.deinit();
        var read_file: ?i64 = null;
        for (locations.items) |location| {
            if (read_file == location.file_id) continue;
            switch (try self.measure(allocator, io, location.volume_id, location.uri)) {
                .read => |measured| if (measured.holds(location.recorded)) {
                    read_file = location.file_id;
                },
                .gone, .unreadable => {},
            }
        }
    }

    fn find(self: *const ContentMeasurements, volume_id: i64, uri: []const u8) ?MeasuredBytes {
        for (self.items.items) |item| {
            if (item.volume_id == volume_id and std.mem.eql(u8, item.uri, uri)) return item.bytes;
        }
        return null;
    }

    fn append(
        self: *ContentMeasurements,
        allocator: std.mem.Allocator,
        volume_id: i64,
        uri: []const u8,
        bytes: MeasuredBytes,
    ) !void {
        const owned = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned);
        try self.items.append(allocator, .{ .volume_id = volume_id, .uri = owned, .bytes = bytes });
    }
};

/// The content hash of `file`, which had `identity` when it was opened, or
/// null when it no longer has that identity once read whole: the bytes read
/// may then be no single version of the file.
pub fn hashHeld(io: std.Io, file: std.Io.File, identity: StorageIdentityKey) !?content_hash.Digest {
    const size = std.math.cast(u64, identity.size_bytes) orelse return null;
    const digest = try content_hash.fromFile(io, file, size);
    const after = statIdentity(identity.volume_id, try file.stat(io)) orelse return null;
    return if (std.meta.eql(after, identity)) digest else null;
}

fn statIdentity(volume_id: i64, stat: std.Io.File.Stat) ?StorageIdentityKey {
    return .{
        .volume_id = volume_id,
        .native_inode = @bitCast(@as(u64, stat.inode)),
        .size_bytes = std.math.cast(i64, stat.size) orelse return null,
        .modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse return null,
    };
}

fn read(io: std.Io, volume_id: i64, uri: []const u8) error{Canceled}!MeasuredBytes {
    const file = std.Io.Dir.cwd().openFile(io, uri, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.FileNotFound, error.NotDir => .gone,
        else => .unreadable,
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => .unreadable,
    };
    const identity = statIdentity(volume_id, stat) orelse return .unreadable;
    const digest = (hashHeld(io, file, identity) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => .unreadable,
    }) orelse return .unreadable;
    return .{ .read = .{ .identity = identity, .digest = digest } };
}
