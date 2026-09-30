const std = @import("std");
const linux = std.os.linux;
const control = @import("../core/control.zig");
const spsc = @import("../audio/spsc.zig");
const work = @import("../core/work.zig");
const hints = @import("watch_hints.zig");
const volume_check = @import("volume_check.zig");
const watch = @import("watch.zig");

const directory_mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW | linux.IN.EXCL_UNLINK;

const read_buffer_bytes = 64 * 1024;

/// Buffers read per pass before the watcher publishes and checks for
/// cancellation, so an event storm cannot hold it in `read`.
const reads_per_pass = 16;

const Watch = struct {
    root_id: i64,
    /// Root-relative directory; empty for the root itself.
    relative: []u8,
};

const RootState = enum { arming, armed, unavailable };

const WatchedRoot = struct {
    id: i64,
    path: []u8,
    volume_key: ?[]u8,
    state: RootState = .arming,
    root_watch: ?i32 = null,
    dirty: hints.DirtySet = .{},
    first_change_ms: i64 = 0,
    last_change_ms: i64 = 0,
    publish_now: bool = false,
    unavailable_unreported: bool = false,
    limit_reached: bool = false,
    fallback_due_ms: ?i64 = null,

    fn deinit(self: *WatchedRoot, allocator: std.mem.Allocator) void {
        self.dirty.deinit(allocator);
        allocator.free(self.path);
        if (self.volume_key) |key| allocator.free(key);
    }

    fn needsFallback(self: *const WatchedRoot) bool {
        return switch (self.state) {
            .unavailable => true,
            .armed => self.limit_reached,
            .arming => false,
        };
    }
};

const Added = enum { added, known, elsewhere, skipped, limit };

/// One Library's inotify watcher and the thread that runs it.
///
/// Threading contract: the thread touches only this struct, its two file
/// descriptors, the directories it walks, and `host_signal`. It never
/// touches a database, a handle Pool or the work Registry. The control lane
/// talks to it through `send` and `takeHint`, reads `status`, and calls
/// `destroy` only after the thread has been joined.
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    registration: *work.Registration,
    host_signal: ?*control.HostSignal,
    options: watch.Options,
    ignore: watch.Ignore,
    inotify_fd: i32,
    wake_fd: i32,
    threaded: std.Io.Threaded = .init_single_threaded,
    commands: spsc.Queue(hints.Command, watch.command_capacity) = .{},
    hint_queue: spsc.Queue(hints.Hint, watch.hint_capacity) = .{},
    roots_watched: std.atomic.Value(u32) = .init(0),
    roots_unavailable: std.atomic.Value(u32) = .init(0),
    roots_degraded: std.atomic.Value(u32) = .init(0),
    directories_watched: std.atomic.Value(u64) = .init(0),
    watch_limit_reached: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),

    roots: std.ArrayList(WatchedRoot) = .empty,
    watches: std.AutoHashMapUnmanaged(i32, Watch) = .empty,
    doomed: std.ArrayList(i32) = .empty,
    limit_unreported: ?i64 = null,
    path_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined,
    relative_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    read_buffer: [read_buffer_bytes]u8 align(@alignOf(linux.inotify_event)) = undefined,

    /// Control lane. Opens the inotify instance and the wake descriptor and
    /// copies everything it is given; the thread arms `roots` when it starts.
    pub fn create(
        allocator: std.mem.Allocator,
        registration: *work.Registration,
        host_signal: ?*control.HostSignal,
        options: watch.Options,
        ignore: watch.Ignore,
        roots: []const watch.Root,
    ) !*Watcher {
        const inotify_rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        switch (linux.errno(inotify_rc)) {
            .SUCCESS => {},
            .MFILE => return error.WatchInstanceLimit,
            .NFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        const inotify_fd: i32 = @intCast(inotify_rc);
        errdefer _ = linux.close(inotify_fd);
        const wake_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        switch (linux.errno(wake_rc)) {
            .SUCCESS => {},
            .MFILE, .NFILE, .NOMEM, .NODEV => return error.SystemResources,
            else => return error.Unexpected,
        }
        const wake_fd: i32 = @intCast(wake_rc);
        errdefer _ = linux.close(wake_fd);

        const self = try allocator.create(Watcher);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .registration = registration,
            .host_signal = host_signal,
            .options = options,
            .ignore = .{},
            .inotify_fd = inotify_fd,
            .wake_fd = wake_fd,
        };
        errdefer self.freeState();
        if (ignore.database_name) |name| self.ignore.database_name = try allocator.dupe(u8, name);
        if (ignore.backup_name) |name| self.ignore.backup_name = try allocator.dupe(u8, name);
        try self.roots.ensureTotalCapacity(allocator, roots.len);
        for (roots) |root| {
            const path = try allocator.dupe(u8, root.path);
            errdefer allocator.free(path);
            const volume_key = if (root.volume_key) |key| try allocator.dupe(u8, key) else null;
            self.roots.appendAssumeCapacity(.{ .id = root.id, .path = path, .volume_key = volume_key });
        }
        return self;
    }

    /// Control lane, after the thread has been joined or when it never
    /// started.
    pub fn destroy(self: *Watcher) void {
        const allocator = self.allocator;
        self.freeState();
        _ = linux.close(self.inotify_fd);
        _ = linux.close(self.wake_fd);
        allocator.destroy(self);
    }

    fn freeState(self: *Watcher) void {
        const allocator = self.allocator;
        while (self.commands.pop()) |command| command.deinit(allocator);
        while (self.hint_queue.pop()) |hint| if (hint.path) |path| allocator.free(path);
        for (self.roots.items) |*root| root.deinit(allocator);
        self.roots.deinit(allocator);
        var entries = self.watches.valueIterator();
        while (entries.next()) |entry| allocator.free(entry.relative);
        self.watches.deinit(allocator);
        self.doomed.deinit(allocator);
        if (self.ignore.database_name) |name| allocator.free(name);
        if (self.ignore.backup_name) |name| allocator.free(name);
        self.threaded.deinit();
    }

    /// The registration's waker: cancellation interrupts the thread's poll.
    pub fn waker(self: *Watcher) work.Waker {
        return .{ .context = self, .wake_fn = wakeFromRegistration };
    }

    fn wakeFromRegistration(context: *anyopaque) callconv(.c) void {
        const self: *Watcher = @ptrCast(@alignCast(context));
        self.wake();
    }

    fn wake(self: *Watcher) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Control lane. False when the command queue is full; the command is
    /// then still the caller's.
    pub fn send(self: *Watcher, command: hints.Command) bool {
        if (!self.commands.push(command)) return false;
        self.wake();
        return true;
    }

    /// Control lane. The caller owns the hint's path.
    pub fn takeHint(self: *Watcher) ?hints.Hint {
        return self.hint_queue.pop();
    }

    pub fn hintsQueued(self: *const Watcher) bool {
        return self.hint_queue.len() != 0;
    }

    pub fn status(self: *const Watcher) watch.Status {
        return .{
            .roots_watched = self.roots_watched.load(.acquire),
            .roots_unavailable = self.roots_unavailable.load(.acquire),
            .roots_degraded = self.roots_degraded.load(.acquire),
            .directories_watched = self.directories_watched.load(.acquire),
            .watch_limit_reached = self.watch_limit_reached.load(.acquire),
            .stopped = self.stopped.load(.acquire),
        };
    }

    pub fn run(self: *Watcher) void {
        defer self.registration.finish();
        self.loop() catch {
            self.stopped.store(true, .release);
            if (self.host_signal) |signal| signal.raise();
        };
    }

    fn cancelled(self: *const Watcher) bool {
        return self.registration.cancellationRequested();
    }

    fn loop(self: *Watcher) !void {
        const io = self.threaded.io();
        while (!self.cancelled()) {
            self.takeCommands();
            self.runDueFallbacks(io, nowMs(io));
            self.armWaitingRoots(io);
            if (self.cancelled()) return;
            try self.readEvents(io);
            if (self.cancelled()) return;
            const now = nowMs(io);
            const publish_ms = self.publishDue(now);
            const fallback_ms = self.fallbackDue(now);
            try self.waitForActivity(if (fallback_ms) |due| earliest(publish_ms, due) else publish_ms);
        }
    }

    fn takeCommands(self: *Watcher) void {
        while (self.commands.pop()) |command| switch (command) {
            .arm_root => |arm| {
                self.removeRoot(arm.root_id);
                self.roots.append(self.allocator, .{
                    .id = arm.root_id,
                    .path = arm.path,
                    .volume_key = arm.volume_key,
                }) catch command.deinit(self.allocator);
            },
            .disarm_root => |root_id| self.removeRoot(root_id),
            .root_unavailable => |root_id| if (self.rootById(root_id)) |root| self.rootLost(root),
        };
        self.publishCounts();
    }

    fn armWaitingRoots(self: *Watcher, io: std.Io) void {
        var index: usize = 0;
        while (index < self.roots.items.len) : (index += 1) {
            if (self.cancelled()) return;
            if (self.roots.items[index].state != .arming) continue;
            self.armRoot(io, &self.roots.items[index]);
        }
    }

    /// Every arm marks the whole root dirty, published at once: nothing that
    /// changed while the root was unwatched produced an event. A root whose
    /// path is on another volume than the one recorded is never armed.
    fn armRoot(self: *Watcher, io: std.Io, root: *WatchedRoot) void {
        root.state = .armed;
        root.limit_reached = false;
        if (!self.onRecordedVolume(io, root)) {
            self.rootLost(root);
            self.publishCounts();
            return;
        }
        self.watchTree(io, root, "");
        if (root.root_watch == null) {
            self.rootLost(root);
        } else {
            root.dirty.markWholeRoot(self.allocator);
            root.publish_now = true;
        }
        self.publishCounts();
    }

    fn onRecordedVolume(self: *Watcher, io: std.Io, root: *const WatchedRoot) bool {
        return volume_check.onRecordedVolume(self.allocator, io, root.path, root.volume_key);
    }

    fn runDueFallbacks(self: *Watcher, io: std.Io, now: i64) void {
        for (self.roots.items) |*root| {
            const due = root.fallback_due_ms orelse continue;
            if (due > now or self.cancelled()) continue;
            root.fallback_due_ms = null;
            switch (root.state) {
                .unavailable => if (self.isArmable(io, root)) {
                    root.state = .arming;
                },
                .armed => if (root.limit_reached) self.rewatch(io, root, now),
                .arming => {},
            }
        }
    }

    fn isArmable(self: *Watcher, io: std.Io, root: *const WatchedRoot) bool {
        const directory = std.Io.Dir.cwd().openDir(io, root.path, .{}) catch return false;
        directory.close(io);
        return self.onRecordedVolume(io, root);
    }

    fn rewatch(self: *Watcher, io: std.Io, root: *WatchedRoot, now: i64) void {
        root.limit_reached = false;
        self.watchTree(io, root, "");
        if (root.root_watch == null) {
            self.rootLost(root);
        } else {
            self.markWholeRoot(root, now);
            root.publish_now = true;
        }
        self.publishCounts();
    }

    fn fallbackDue(self: *Watcher, now: i64) ?u64 {
        var next: ?u64 = null;
        for (self.roots.items) |*root| {
            if (!root.needsFallback()) {
                root.fallback_due_ms = null;
                continue;
            }
            const due = root.fallback_due_ms orelse now +| self.options.degraded_rescan_ms;
            root.fallback_due_ms = due;
            next = earliest(next, @intCast(@max(due - now, 0)));
        }
        return next;
    }

    fn removeRoot(self: *Watcher, root_id: i64) void {
        for (self.roots.items, 0..) |*root, index| {
            if (root.id != root_id) continue;
            self.unwatchTree(root_id, "");
            root.deinit(self.allocator);
            _ = self.roots.orderedRemove(index);
            return;
        }
    }

    fn rootById(self: *Watcher, root_id: i64) ?*WatchedRoot {
        for (self.roots.items) |*root| if (root.id == root_id) return root;
        return null;
    }

    /// A root that is gone is reported and never swept: an unmounted drive
    /// must not empty a library.
    fn rootLost(self: *Watcher, root: *WatchedRoot) void {
        if (root.state == .unavailable) return;
        self.unwatchTree(root.id, "");
        root.state = .unavailable;
        root.root_watch = null;
        root.limit_reached = false;
        root.dirty.clear(self.allocator);
        root.publish_now = false;
        root.unavailable_unreported = true;
        self.publishCounts();
    }

    fn publishCounts(self: *Watcher) void {
        var watched: u32 = 0;
        var unavailable: u32 = 0;
        var degraded: u32 = 0;
        for (self.roots.items) |root| switch (root.state) {
            .armed => {
                watched += 1;
                if (root.limit_reached) degraded += 1;
            },
            .unavailable => unavailable += 1,
            .arming => {},
        };
        self.roots_watched.store(watched, .release);
        self.roots_unavailable.store(unavailable, .release);
        self.roots_degraded.store(degraded, .release);
        self.watch_limit_reached.store(degraded != 0, .release);
        self.directories_watched.store(self.watches.count(), .release);
    }

    fn fullPath(self: *Watcher, root: *const WatchedRoot, relative: []const u8) ?[:0]const u8 {
        if (relative.len == 0) return std.fmt.bufPrintSentinel(&self.path_buffer, "{s}", .{root.path}, 0) catch null;
        return std.fmt.bufPrintSentinel(&self.path_buffer, "{s}/{s}", .{ root.path, relative }, 0) catch null;
    }

    fn addWatch(self: *Watcher, root: *WatchedRoot, relative: []const u8) Added {
        const path = self.fullPath(root, relative) orelse return .skipped;
        const rc = linux.inotify_add_watch(self.inotify_fd, path.ptr, directory_mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOSPC => return self.limitReached(root),
            else => return .skipped,
        }
        const descriptor: i32 = @intCast(rc);
        if (self.options.watch_limit) |limit| {
            if (!self.watches.contains(descriptor) and self.watches.count() >= limit) {
                _ = linux.inotify_rm_watch(self.inotify_fd, descriptor);
                return self.limitReached(root);
            }
        }
        if (self.watches.get(descriptor)) |existing| {
            if (existing.root_id == root.id and std.mem.eql(u8, existing.relative, relative)) return .known;
            if (relative.len == 0) root.root_watch = descriptor;
            return .elsewhere;
        }
        const owned = self.allocator.dupe(u8, relative) catch {
            _ = linux.inotify_rm_watch(self.inotify_fd, descriptor);
            return .skipped;
        };
        self.watches.put(self.allocator, descriptor, .{ .root_id = root.id, .relative = owned }) catch {
            self.allocator.free(owned);
            _ = linux.inotify_rm_watch(self.inotify_fd, descriptor);
            return .skipped;
        };
        if (relative.len == 0) root.root_watch = descriptor;
        self.directories_watched.store(self.watches.count(), .release);
        return .added;
    }

    fn limitReached(self: *Watcher, root: *WatchedRoot) Added {
        if (!root.limit_reached) {
            root.limit_reached = true;
            self.limit_unreported = root.id;
        }
        return .limit;
    }

    /// Watches `relative` and every directory below it. Symbolic links and
    /// ignored names are not followed, and a directory already watched under
    /// another path is not walked again, so a bind mount cannot loop.
    fn watchTree(self: *Watcher, io: std.Io, root: *WatchedRoot, relative: []const u8) void {
        switch (self.addWatch(root, relative)) {
            .added, .known => {},
            .elsewhere, .skipped, .limit => return,
        }
        const path = self.fullPath(root, relative) orelse return;
        const directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer directory.close(io);
        var walker = directory.walkSelectively(self.allocator) catch return;
        defer walker.deinit();
        while (!self.cancelled()) {
            const entry = (walker.next(io) catch continue) orelse return;
            if (entry.kind != .directory or self.ignore.matches(entry.basename)) continue;
            const child = if (relative.len == 0)
                entry.path
            else
                std.fmt.bufPrint(&self.relative_buffer, "{s}/{s}", .{ relative, entry.path }) catch continue;
            switch (self.addWatch(root, child)) {
                .added, .known => walker.enter(io, entry) catch {},
                .elsewhere, .skipped => {},
                .limit => return,
            }
        }
    }

    fn unwatchTree(self: *Watcher, root_id: i64, relative: []const u8) void {
        self.doomed.clearRetainingCapacity();
        var entries = self.watches.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.root_id != root_id or !hints.isWithin(entry.value_ptr.relative, relative)) continue;
            self.doomed.append(self.allocator, entry.key_ptr.*) catch {
                self.unwatchTreeSlowly(root_id, relative);
                return;
            };
        }
        for (self.doomed.items) |descriptor| self.forgetWatch(descriptor, .remove);
        self.directories_watched.store(self.watches.count(), .release);
    }

    fn unwatchTreeSlowly(self: *Watcher, root_id: i64, relative: []const u8) void {
        while (true) {
            var entries = self.watches.iterator();
            const doomed = while (entries.next()) |entry| {
                if (entry.value_ptr.root_id == root_id and hints.isWithin(entry.value_ptr.relative, relative))
                    break entry.key_ptr.*;
            } else return;
            self.forgetWatch(doomed, .remove);
        }
    }

    fn forgetWatch(self: *Watcher, descriptor: i32, kernel: enum { remove, already_removed }) void {
        const removed = self.watches.fetchRemove(descriptor) orelse return;
        self.allocator.free(removed.value.relative);
        if (kernel == .remove) _ = linux.inotify_rm_watch(self.inotify_fd, descriptor);
        for (self.roots.items) |*root| {
            if (root.root_watch == descriptor) root.root_watch = null;
        }
    }

    fn readEvents(self: *Watcher, io: std.Io) !void {
        for (0..reads_per_pass) |_| {
            const rc = linux.read(self.inotify_fd, &self.read_buffer, self.read_buffer.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return,
                .INTR => continue,
                else => return error.WatcherReadFailed,
            }
            if (rc == 0) return;
            const now = nowMs(io);
            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= rc) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&self.read_buffer[offset]));
                offset += @sizeOf(linux.inotify_event) + event.len;
                self.handleEvent(io, event, now);
            }
            self.publishCounts();
            if (self.cancelled()) return;
        }
    }

    fn handleEvent(self: *Watcher, io: std.Io, event: *const linux.inotify_event, now: i64) void {
        if (event.mask & linux.IN.Q_OVERFLOW != 0) {
            self.overflowed(io, now);
            return;
        }
        const watched = self.watches.get(event.wd) orelse return;
        const root = self.rootById(watched.root_id) orelse return;
        if (root.state != .armed) return;
        const is_root = root.root_watch == event.wd;
        if (event.mask & linux.IN.IGNORED != 0) {
            self.forgetWatch(event.wd, .already_removed);
            if (is_root) self.rootLost(root);
            return;
        }
        if (event.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.UNMOUNT) != 0) {
            if (is_root) self.rootLost(root);
            return;
        }
        const name = event.getName() orelse return;
        if (self.ignore.matches(name)) return;
        if (event.mask & linux.IN.ISDIR == 0) {
            self.markDirty(root, watched.relative, now);
            return;
        }
        const child = if (watched.relative.len == 0)
            name
        else
            std.fmt.bufPrint(&self.relative_buffer, "{s}/{s}", .{ watched.relative, name }) catch {
                self.markWholeRoot(root, now);
                return;
            };
        const owned = self.allocator.dupe(u8, child) catch {
            self.markWholeRoot(root, now);
            return;
        };
        if (event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) {
            self.unwatchTree(root.id, owned);
        } else {
            self.watchTree(io, root, owned);
        }
        self.noteChange(root, now);
        root.dirty.markDirectory(self.allocator, owned);
    }

    /// Events were lost: every root may have changed anywhere, and a
    /// directory created meanwhile may have no watch yet.
    fn overflowed(self: *Watcher, io: std.Io, now: i64) void {
        for (self.roots.items) |*root| {
            if (root.state != .armed) continue;
            self.watchTree(io, root, "");
            if (root.root_watch == null) {
                self.rootLost(root);
                continue;
            }
            self.markWholeRoot(root, now);
        }
    }

    fn markDirty(self: *Watcher, root: *WatchedRoot, relative: []const u8, now: i64) void {
        const owned = self.allocator.dupe(u8, relative) catch {
            self.markWholeRoot(root, now);
            return;
        };
        self.noteChange(root, now);
        root.dirty.markDirectory(self.allocator, owned);
    }

    fn markWholeRoot(self: *Watcher, root: *WatchedRoot, now: i64) void {
        self.noteChange(root, now);
        root.dirty.markWholeRoot(self.allocator);
    }

    fn noteChange(self: *Watcher, root: *WatchedRoot, now: i64) void {
        _ = self;
        if (root.dirty.isEmpty()) root.first_change_ms = now;
        root.last_change_ms = now;
    }

    /// Publishes every root whose changes are due and returns how long the
    /// thread may sleep before the next one is, or null when none waits.
    fn publishDue(self: *Watcher, now: i64) ?u64 {
        var next: ?u64 = null;
        var published = false;
        const retry_ms: u64 = self.options.quiet_ms;
        for (self.roots.items) |*root| {
            if (root.unavailable_unreported) {
                if (self.push(.{ .root_id = root.id, .reason = .root_unavailable })) {
                    root.unavailable_unreported = false;
                    published = true;
                } else next = earliest(next, retry_ms);
            }
            if (root.dirty.isEmpty()) continue;
            const due_ms = if (root.publish_now) now else @min(
                root.last_change_ms +| self.options.quiet_ms,
                root.first_change_ms +| self.options.max_delay_ms,
            );
            if (due_ms > now) {
                next = earliest(next, @intCast(due_ms - now));
                continue;
            }
            if (self.publishDirty(root)) published = true else next = earliest(next, retry_ms);
        }
        if (self.limit_unreported) |root_id| {
            if (self.push(.{ .root_id = root_id, .reason = .watch_limit })) {
                self.limit_unreported = null;
                published = true;
            } else next = earliest(next, retry_ms);
        }
        if (published) if (self.host_signal) |signal| signal.raise();
        return next;
    }

    /// A root whose directories do not all fit in the hint queue is
    /// published, or kept, as the whole root.
    fn publishDirty(self: *Watcher, root: *WatchedRoot) bool {
        const free = watch.hint_capacity - self.hint_queue.len();
        if (!root.dirty.whole_root and root.dirty.directories.items.len <= free) {
            for (root.dirty.directories.items) |directory| {
                const pushed = self.push(.{ .root_id = root.id, .reason = .subtree, .path = directory });
                std.debug.assert(pushed);
            }
            root.dirty.directories.clearRetainingCapacity();
        } else {
            root.dirty.markWholeRoot(self.allocator);
            if (free == 0) return false;
            const pushed = self.push(.{ .root_id = root.id, .reason = .whole_root });
            std.debug.assert(pushed);
            root.dirty.whole_root = false;
        }
        root.publish_now = false;
        return true;
    }

    fn push(self: *Watcher, hint: hints.Hint) bool {
        return self.hint_queue.push(hint);
    }

    fn waitForActivity(self: *Watcher, timeout_ms: ?u64) !void {
        var descriptors = [_]linux.pollfd{
            .{ .fd = self.inotify_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const timeout: i32 = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(i32))) else -1;
        const rc = linux.poll(&descriptors, descriptors.len, timeout);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return,
            else => return error.WatcherPollFailed,
        }
        if (descriptors[1].revents & linux.POLL.IN != 0) {
            var count: u64 = 0;
            _ = linux.read(self.wake_fd, std.mem.asBytes(&count), @sizeOf(u64));
        }
    }
};

fn earliest(current: ?u64, candidate: u64) u64 {
    return if (current) |value| @min(value, candidate) else candidate;
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

const TestWatcher = struct {
    temporary: std.testing.TmpDir,
    path: []u8,
    registration: work.Registration = .{},
    watcher: *Watcher,

    fn start(self: *TestWatcher, ignore: watch.Ignore) !void {
        self.temporary = std.testing.tmpDir(.{});
        errdefer self.temporary.cleanup();
        self.path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{self.temporary.sub_path});
        errdefer std.testing.allocator.free(self.path);
        try self.temporary.dir.createDirPath(std.testing.io, "A/B");
        self.registration = .{};
        self.watcher = try Watcher.create(
            std.testing.allocator,
            &self.registration,
            null,
            .{ .quiet_ms = 20, .max_delay_ms = 1000, .degraded_rescan_ms = 60_000 },
            ignore,
            &.{.{ .id = 7, .path = self.path, .volume_key = null }},
        );
        errdefer self.watcher.destroy();
        self.registration.waker = self.watcher.waker();
        self.registration.thread = try std.Thread.spawn(.{}, Watcher.run, .{self.watcher});
    }

    fn stop(self: *TestWatcher) void {
        self.registration.requestCancellation();
        self.registration.awaitCompletion();
        self.watcher.destroy();
        std.testing.allocator.free(self.path);
        self.temporary.cleanup();
    }

    fn nextHint(self: *TestWatcher, path_out: []u8) !struct { hint: hints.Hint, path: []const u8 } {
        for (0..5_000) |_| {
            if (self.watcher.takeHint()) |hint| {
                var path: []const u8 = "";
                if (hint.path) |owned| {
                    defer std.testing.allocator.free(owned);
                    @memcpy(path_out[0..owned.len], owned);
                    path = path_out[0..owned.len];
                }
                return .{ .hint = hint, .path = path };
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.NoHint;
    }

    fn expectQuiet(self: *TestWatcher, milliseconds: i64) !void {
        try std.testing.io.sleep(.fromMilliseconds(milliseconds), .awake);
        if (self.watcher.takeHint()) |hint| {
            if (hint.path) |path| std.testing.allocator.free(path);
            return error.UnexpectedHint;
        }
    }
};

test "arming publishes the whole root, and a file created in a nested directory dirties that directory" {
    var fixture: TestWatcher = undefined;
    try fixture.start(.{});
    defer fixture.stop();
    var path: [256]u8 = undefined;
    const armed = try fixture.nextHint(&path);
    try std.testing.expectEqual(hints.Reason.whole_root, armed.hint.reason);
    try std.testing.expectEqual(@as(i64, 7), armed.hint.root_id);
    try std.testing.expectEqual(@as(u64, 3), fixture.watcher.status().directories_watched);

    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "A/B/new.flac", .data = "fLaC" });
    const changed = try fixture.nextHint(&path);
    try std.testing.expectEqual(hints.Reason.subtree, changed.hint.reason);
    try std.testing.expectEqualStrings("A/B", changed.path);
}

test "a directory created and then populated is watched, and its own path is dirtied" {
    var fixture: TestWatcher = undefined;
    try fixture.start(.{});
    defer fixture.stop();
    var path: [256]u8 = undefined;
    _ = try fixture.nextHint(&path);

    try fixture.temporary.dir.createDirPath(std.testing.io, "A/New/Disc 1");
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "A/New/Disc 1/one.flac", .data = "fLaC" });
    const created = try fixture.nextHint(&path);
    try std.testing.expectEqual(hints.Reason.subtree, created.hint.reason);
    try std.testing.expectEqualStrings("A/New", created.path);

    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "A/New/Disc 1/two.flac", .data = "fLaC" });
    const later = try fixture.nextHint(&path);
    try std.testing.expectEqualStrings("A/New/Disc 1", later.path);
    try std.testing.expectEqual(@as(u64, 5), fixture.watcher.status().directories_watched);
}

test "Orca's own files never dirty anything" {
    var fixture: TestWatcher = undefined;
    try fixture.start(.{ .database_name = "library.db", .backup_name = "library.db.orca-backups" });
    defer fixture.stop();
    var path: [256]u8 = undefined;
    _ = try fixture.nextHint(&path);

    const dir = fixture.temporary.dir;
    try dir.writeFile(std.testing.io, .{ .sub_path = "A/.one.flac.orca-stage-4-0", .data = "fLaC" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "library.db", .data = "" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "library.db-wal", .data = "" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "A/B/.orca-volume-id", .data = "id" });
    try dir.createDirPath(std.testing.io, "library.db.orca-backups/4");
    try dir.writeFile(std.testing.io, .{ .sub_path = "library.db.orca-backups/4/one.flac", .data = "fLaC" });
    try fixture.expectQuiet(150);
    try std.testing.expectEqual(@as(u64, 3), fixture.watcher.status().directories_watched);
}

test "a deleted directory stops being watched and is itself dirtied" {
    var fixture: TestWatcher = undefined;
    try fixture.start(.{});
    defer fixture.stop();
    var path: [256]u8 = undefined;
    _ = try fixture.nextHint(&path);

    try fixture.temporary.dir.deleteTree(std.testing.io, "A/B");
    const deleted = try fixture.nextHint(&path);
    try std.testing.expectEqual(hints.Reason.subtree, deleted.hint.reason);
    try std.testing.expectEqualStrings("A/B", deleted.path);
    try std.testing.expectEqual(@as(u64, 2), fixture.watcher.status().directories_watched);
}

test "a root that is moved away is reported unavailable and never dirtied" {
    var fixture: TestWatcher = undefined;
    try fixture.start(.{});
    defer fixture.stop();
    var path: [256]u8 = undefined;
    _ = try fixture.nextHint(&path);

    const moved = try std.fmt.allocPrint(std.testing.allocator, "{s}-moved", .{fixture.path});
    defer std.testing.allocator.free(moved);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), fixture.path, std.Io.Dir.cwd(), moved, std.testing.io);
    defer std.Io.Dir.rename(std.Io.Dir.cwd(), moved, std.Io.Dir.cwd(), fixture.path, std.testing.io) catch {};
    const lost = try fixture.nextHint(&path);
    try std.testing.expectEqual(hints.Reason.root_unavailable, lost.hint.reason);
    const moved_dir = try std.Io.Dir.cwd().openDir(std.testing.io, moved, .{});
    defer moved_dir.close(std.testing.io);
    try moved_dir.writeFile(std.testing.io, .{ .sub_path = "A/after.flac", .data = "fLaC" });
    try fixture.expectQuiet(100);
    const status = fixture.watcher.status();
    try std.testing.expectEqual(@as(u32, 0), status.roots_watched);
    try std.testing.expectEqual(@as(u32, 1), status.roots_unavailable);
    try std.testing.expectEqual(@as(u64, 0), status.directories_watched);
}

test "a root that does not exist is reported unavailable when armed" {
    var registration: work.Registration = .{};
    const watcher = try Watcher.create(
        std.testing.allocator,
        &registration,
        null,
        .{ .quiet_ms = 20, .max_delay_ms = 1000, .degraded_rescan_ms = 60_000 },
        .{},
        &.{.{ .id = 3, .path = ".zig-cache/tmp/orca-watch-no-such-root", .volume_key = null }},
    );
    defer watcher.destroy();
    registration.waker = watcher.waker();
    registration.thread = try std.Thread.spawn(.{}, Watcher.run, .{watcher});
    defer {
        registration.requestCancellation();
        registration.awaitCompletion();
    }
    const hint = for (0..5_000) |_| {
        if (watcher.takeHint()) |hint| break hint;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.NoHint;
    try std.testing.expectEqual(hints.Reason.root_unavailable, hint.reason);
    try std.testing.expectEqual(@as(i64, 3), hint.root_id);
}
