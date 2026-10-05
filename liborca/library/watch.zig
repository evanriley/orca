//! Filesystem watching: one thread per watched Library that turns native
//! change notifications into advisory `watch_hints.Hint`s. Only Linux has an
//! adapter; elsewhere `supported` is false and `Watcher.create` refuses.

const std = @import("std");
const builtin = @import("builtin");
const control = @import("../core/control.zig");
const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
const mutation_executor = @import("../metadata/executor.zig");
const volume_marker = @import("../platform/volume_linux.zig").marker_name;
const work = @import("../core/work.zig");
const hints = @import("watch_hints.zig");

pub const supported = builtin.os.tag == .linux;

pub const Watcher = if (supported) @import("watch_linux.zig").Watcher else Unsupported;

pub const Options = struct {
    quiet_ms: u32,
    max_delay_ms: u32,
    /// How often a root the watch limit left partly unwatched is walked
    /// again, and a root that is unavailable is tried again.
    degraded_rescan_ms: u32,
    /// Refuses watches past this many, as the kernel's watch limit would.
    watch_limit: ?u32 = null,
};

/// A root to arm. The watcher copies the path and the key.
pub const Root = struct {
    id: i64,
    path: []const u8,
    /// The stable key of the volume the root is bound to, or null when the
    /// Library records none. See `volume_check.onRecordedVolume`.
    volume_key: ?[]const u8,
};

/// Names whose changes never dirty anything, because Orca itself writes them.
pub const Ignore = struct {
    /// The Library database's file name, when it has a file.
    database_name: ?[]const u8 = null,
    /// The name of the directory tag writes keep their backups in.
    backup_name: ?[]const u8 = null,

    pub fn forLibrary(library_database: *const LibraryDatabase) Ignore {
        return .{
            .database_name = if (library_database.database.filename()) |file| std.Io.Dir.path.basename(file) else null,
            .backup_name = if (library_database.backup_directory) |directory| std.Io.Dir.path.basename(directory) else null,
        };
    }

    pub fn matches(self: Ignore, name: []const u8) bool {
        if (mutation_executor.isOrcaTemporaryName(name)) return true;
        if (std.mem.eql(u8, name, volume_marker)) return true;
        if (self.backup_name) |backup| if (std.mem.eql(u8, name, backup)) return true;
        const database = self.database_name orelse return false;
        if (!std.mem.startsWith(u8, name, database)) return false;
        const suffix = name[database.len..];
        return suffix.len == 0 or
            std.mem.eql(u8, suffix, "-wal") or
            std.mem.eql(u8, suffix, "-shm") or
            std.mem.eql(u8, suffix, "-journal") or
            std.mem.eql(u8, suffix, ".orca-journal.lock") or
            std.mem.eql(u8, suffix, ".orca-scan.lock");
    }
};

/// What a watcher publishes about itself, readable from any thread.
pub const Status = struct {
    roots_watched: u32,
    roots_unavailable: u32,
    /// Roots the watch limit left partly unwatched.
    roots_degraded: u32,
    directories_watched: u64,
    watch_limit_reached: bool,
    /// The thread ended on an error it could not recover from.
    stopped: bool,
};

pub const command_capacity = 16;
pub const hint_capacity = 256;

const Unsupported = struct {
    pub fn create(
        allocator: std.mem.Allocator,
        registration: *work.Registration,
        host_signal: ?*control.HostSignal,
        options: Options,
        ignore: Ignore,
        roots: []const Root,
    ) error{WatchingUnsupported}!*Unsupported {
        _ = .{ allocator, registration, host_signal, options, ignore, roots };
        return error.WatchingUnsupported;
    }

    pub fn destroy(self: *Unsupported) void {
        _ = self;
        unreachable;
    }

    pub fn run(self: *Unsupported) void {
        _ = self;
        unreachable;
    }

    pub fn waker(self: *Unsupported) work.Waker {
        _ = self;
        unreachable;
    }

    pub fn send(self: *Unsupported, command: hints.Command) bool {
        _ = .{ self, command };
        unreachable;
    }

    pub fn takeHint(self: *Unsupported) ?hints.Hint {
        _ = self;
        unreachable;
    }

    pub fn hintsQueued(self: *const Unsupported) bool {
        _ = self;
        unreachable;
    }

    pub fn status(self: *const Unsupported) Status {
        _ = self;
        unreachable;
    }
};

test "the database's own files, Orca's temporaries and the backup directory are ignored, and music is not" {
    const ignore: Ignore = .{ .database_name = "library.db", .backup_name = "library.db.orca-backups" };
    for ([_][]const u8{
        "library.db",
        "library.db-wal",
        "library.db-shm",
        "library.db-journal",
        "library.db.orca-journal.lock",
        "library.db.orca-scan.lock",
        "library.db.orca-backups",
        ".orca-volume-id",
        ".one.flac.orca-stage-3-0",
        ".one.flac.orca-restore-3-0",
        "one.flac.orca-backup-3",
        "one.flac.recovery-displaced",
    }) |name| try std.testing.expect(ignore.matches(name));
    for ([_][]const u8{ "one.flac", "library.dbx", "library.db-old", "Album" }) |name| {
        try std.testing.expect(!ignore.matches(name));
    }
    try std.testing.expect(!(Ignore{}).matches("library.db"));
}
