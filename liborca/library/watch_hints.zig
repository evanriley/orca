const std = @import("std");

pub const Reason = enum {
    /// A directory under the root changed; `path` names it.
    subtree,
    whole_root,
    /// The root was deleted, moved or unmounted, or could not be watched.
    root_unavailable,
    /// The kernel's watch limit was reached; some directories are unwatched.
    watch_limit,
};

/// Advisory signal from a watcher. Consumers reconcile what the filesystem
/// says now; a hint carries no file facts.
///
/// `path` is set for `.subtree` only: a directory relative to the root, in
/// the normal form `library.scanner.validateSubtree` accepts. It is allocated
/// with the watcher's allocator and owned by whoever holds the hint: the
/// control lane frees or keeps it when it takes the hint, and the watcher's
/// `destroy` frees the hints nobody took.
pub const Hint = struct {
    root_id: i64,
    reason: Reason,
    path: ?[]u8 = null,
};

/// Control lane to watcher. `arm_root.path` is allocated with the watcher's
/// allocator and owned by the command: the watcher keeps it, and `destroy`
/// frees commands the watcher never read.
pub const Command = union(enum) {
    arm_root: ArmRoot,
    disarm_root: i64,
};

pub const ArmRoot = struct {
    root_id: i64,
    path: []u8,
};

pub const max_directories = 64;

/// What under one root needs reconciling: the whole root, or at most
/// `max_directories` root-relative directories, none inside another.
pub const DirtySet = struct {
    whole_root: bool = false,
    directories: std.ArrayList([]u8) = .empty,

    pub fn isEmpty(self: *const DirtySet) bool {
        return !self.whole_root and self.directories.items.len == 0;
    }

    pub fn markWholeRoot(self: *DirtySet, allocator: std.mem.Allocator) void {
        self.freeDirectories(allocator);
        self.whole_root = true;
    }

    /// Takes ownership of `directory`. The empty path is the root itself.
    pub fn markDirectory(self: *DirtySet, allocator: std.mem.Allocator, directory: []u8) void {
        if (self.whole_root or directory.len == 0) {
            allocator.free(directory);
            if (!self.whole_root) self.markWholeRoot(allocator);
            return;
        }
        for (self.directories.items) |held| {
            if (isWithin(directory, held)) {
                allocator.free(directory);
                return;
            }
        }
        var index: usize = 0;
        while (index < self.directories.items.len) {
            if (isWithin(self.directories.items[index], directory)) {
                allocator.free(self.directories.swapRemove(index));
            } else index += 1;
        }
        if (self.directories.items.len == max_directories) {
            allocator.free(directory);
            self.markWholeRoot(allocator);
            return;
        }
        self.directories.append(allocator, directory) catch {
            allocator.free(directory);
            self.markWholeRoot(allocator);
        };
    }

    pub fn clear(self: *DirtySet, allocator: std.mem.Allocator) void {
        self.freeDirectories(allocator);
        self.whole_root = false;
    }

    pub fn deinit(self: *DirtySet, allocator: std.mem.Allocator) void {
        self.freeDirectories(allocator);
        self.directories.deinit(allocator);
        self.* = undefined;
    }

    fn freeDirectories(self: *DirtySet, allocator: std.mem.Allocator) void {
        for (self.directories.items) |directory| allocator.free(directory);
        self.directories.clearRetainingCapacity();
    }
};

/// Whether `path` is `ancestor` or lies below it. The empty ancestor is the
/// root, which holds everything.
pub fn isWithin(path: []const u8, ancestor: []const u8) bool {
    if (ancestor.len == 0) return true;
    if (!std.mem.startsWith(u8, path, ancestor)) return false;
    return path.len == ancestor.len or path[ancestor.len] == '/';
}

fn markOwned(set: *DirtySet, directory: []const u8) !void {
    set.markDirectory(std.testing.allocator, try std.testing.allocator.dupe(u8, directory));
}

test "a directory inside one already dirty is absorbed, and a dirty parent absorbs its children" {
    var set: DirtySet = .{};
    defer set.deinit(std.testing.allocator);
    try markOwned(&set, "A/B/C");
    try markOwned(&set, "A/B");
    try markOwned(&set, "A/B/D");
    try markOwned(&set, "A-x");
    try markOwned(&set, "A/Bee");
    try std.testing.expect(!set.whole_root);
    try std.testing.expectEqual(@as(usize, 3), set.directories.items.len);
    for (set.directories.items) |directory| {
        try std.testing.expect(std.mem.eql(u8, directory, "A/B") or
            std.mem.eql(u8, directory, "A-x") or
            std.mem.eql(u8, directory, "A/Bee"));
    }
}

test "more directories than the bound, or the root itself, make the set the whole root" {
    var set: DirtySet = .{};
    defer set.deinit(std.testing.allocator);
    var name: [16]u8 = undefined;
    for (0..max_directories) |index| try markOwned(&set, try std.fmt.bufPrint(&name, "D{d}", .{index}));
    try std.testing.expect(!set.whole_root);
    try markOwned(&set, "one-more");
    try std.testing.expect(set.whole_root);
    try std.testing.expectEqual(@as(usize, 0), set.directories.items.len);

    var root: DirtySet = .{};
    defer root.deinit(std.testing.allocator);
    try markOwned(&root, "A");
    try markOwned(&root, "");
    try std.testing.expect(root.whole_root);
    try markOwned(&root, "B");
    try std.testing.expectEqual(@as(usize, 0), root.directories.items.len);
}
