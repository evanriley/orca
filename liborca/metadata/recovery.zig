const std = @import("std");
const database = @import("../database/repository.zig");
const executor_module = @import("executor.zig");
const JournalLock = @import("journal_lock.zig").JournalLock;

pub const Summary = struct {
    groups: usize = 0,
    operations: usize = 0,
    rolled_back: usize = 0,
    needs_reconciliation: usize = 0,
};

/// Drive every nonterminal mutation-journal record to a terminal state.
///
/// A group is recovered as a whole and in reverse action order, because a plan
/// is a logical group: leaving an earlier committed action applied while a later
/// one is unwound would publish a half-executed plan. `needs_reconciliation` is
/// a terminal outcome and therefore a successful recovery — it is how Orca says
/// "every file was retained but the original state could not be proven".
///
/// If any record is still nonterminal afterwards, the caller must refuse to make
/// the Library available: its journal describes filesystem work in an unknown
/// state, and migrating or serving it would make that unrecoverable.
pub fn recoverPending(
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *database.MutationJournalRepository,
    backup_directory: ?[]const u8,
    journal_lock: *const JournalLock,
    fault: ?executor_module.Fault,
) !Summary {
    const group_ids = try journal.nonterminalGroupIds(allocator);
    defer allocator.free(group_ids);
    var summary: Summary = .{ .groups = group_ids.len };
    if (group_ids.len == 0) return summary;

    var executor: executor_module.Executor = .{
        .allocator = allocator,
        .io = io,
        .journal = journal,
        .journal_lock = journal_lock,
        .backup_directory = backup_directory,
        .fault = fault,
    };
    for (group_ids) |group_id| try executor.recoverGroup(group_id);

    for (group_ids) |group_id| {
        const operation_ids = try journal.groupOperationIds(allocator, group_id);
        defer allocator.free(operation_ids);
        for (operation_ids) |operation_id| {
            summary.operations += 1;
            switch (try journal.state(operation_id)) {
                .rolled_back => summary.rolled_back += 1,
                .needs_reconciliation => summary.needs_reconciliation += 1,
                .committed => {},
                .planned, .staged, .failed, .undoing => return error.MutationRecoveryIncomplete,
            }
        }
    }
    return summary;
}

const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
const file_mutation = @import("file_mutation.zig");
const id3v1 = @import("id3v1.zig");
const migrations = @import("../database/migrations.zig");
const mutation = @import("mutation.zig");
const sqlite = @import("../database/sqlite.zig");

const test_plan_id = 1000;
const test_group_id = 1000;

/// One temporary library plus one tagged source file, so a crash can be driven
/// through the real executor and the library then reopened as a new process
/// would reopen it.
const Harness = struct {
    temporary: std.testing.TmpDir,
    prefix: []u8,
    source: []u8,
    stage: []u8,
    restore: []u8,
    backup_directory: []u8,
    backup: []u8,
    second: []u8,
    second_stage: []u8,
    second_restore: []u8,
    second_backup: []u8,
    database_path: [:0]u8,
    original: mutation.FileIdentity,
    second_original: mutation.FileIdentity,

    fn init() !Harness {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const allocator = std.testing.allocator;
        const prefix = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/tmp/{s}",
            .{temporary.sub_path},
        );
        errdefer allocator.free(prefix);
        const source = try std.fmt.allocPrint(allocator, "{s}/source.mp3", .{prefix});
        errdefer allocator.free(source);
        const stage = try std.fmt.allocPrint(
            allocator,
            "{s}/.source.mp3.orca-stage-{d}-0",
            .{ prefix, test_plan_id },
        );
        errdefer allocator.free(stage);
        const restore = try std.fmt.allocPrint(
            allocator,
            "{s}/.source.mp3.orca-restore-{d}-0",
            .{ prefix, test_plan_id },
        );
        errdefer allocator.free(restore);
        const database_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/library.db",
            .{prefix},
            0,
        );
        errdefer allocator.free(database_path);
        for ([_][]const u8{ "source.mp3", "second.mp3" }, 1..) |name, track| {
            try temporary.dir.writeFile(std.testing.io, .{
                .sub_path = name,
                .data = "\xff\xfb\x90\x64generated audio payload" ++ (try id3v1.encode(.{
                    .title = "Original",
                    .artist = "Generated",
                    .album = "Generated",
                    .year = "2026",
                    .comment = "Generated",
                    .track_number = @as(u8, @intCast(track)),
                    .genre = 13,
                })),
            });
        }
        const second = try std.fmt.allocPrint(allocator, "{s}/second.mp3", .{prefix});
        errdefer allocator.free(second);
        const second_stage = try std.fmt.allocPrint(
            allocator,
            "{s}/.second.mp3.orca-stage-{d}-1",
            .{ prefix, test_plan_id },
        );
        errdefer allocator.free(second_stage);
        const second_restore = try std.fmt.allocPrint(
            allocator,
            "{s}/.second.mp3.orca-restore-{d}-1",
            .{ prefix, test_plan_id },
        );
        errdefer allocator.free(second_restore);
        const backup_directory = backup_directory: {
            var library = try LibraryDatabase.open(allocator, std.testing.io, database_path);
            defer library.close();
            break :backup_directory try allocator.dupe(u8, library.backup_directory.?);
        };
        errdefer allocator.free(backup_directory);
        const backup = try std.fmt.allocPrint(
            allocator,
            "{s}/{d}/0-source.mp3",
            .{ backup_directory, test_plan_id },
        );
        errdefer allocator.free(backup);
        const second_backup = try std.fmt.allocPrint(
            allocator,
            "{s}/{d}/1-second.mp3",
            .{ backup_directory, test_plan_id },
        );
        errdefer allocator.free(second_backup);
        return .{
            .temporary = temporary,
            .prefix = prefix,
            .source = source,
            .stage = stage,
            .restore = restore,
            .backup_directory = backup_directory,
            .backup = backup,
            .second = second,
            .second_stage = second_stage,
            .second_restore = second_restore,
            .second_backup = second_backup,
            .database_path = database_path,
            .original = try file_mutation.identity(std.testing.io, source),
            .second_original = try file_mutation.identity(std.testing.io, second),
        };
    }

    fn deinit(self: *Harness) void {
        const allocator = std.testing.allocator;
        allocator.free(self.prefix);
        allocator.free(self.source);
        allocator.free(self.stage);
        allocator.free(self.restore);
        allocator.free(self.backup_directory);
        allocator.free(self.backup);
        allocator.free(self.second);
        allocator.free(self.second_stage);
        allocator.free(self.second_restore);
        allocator.free(self.second_backup);
        allocator.free(self.database_path);
        self.temporary.cleanup();
    }

    fn open(self: *Harness) !LibraryDatabase {
        return LibraryDatabase.open(std.testing.allocator, std.testing.io, self.database_path);
    }

    fn crashWrite(self: *Harness, point: executor_module.FaultPoint) !void {
        var library = try self.open();
        defer library.close();
        const actions = [_]mutation.Action{.{ .write_tags = .{
            .path = self.source,
            .expected = self.original,
            .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
        } }};
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, .{ .point = point });
        try std.testing.expectError(
            error.SimulatedPowerLoss,
            executor.executePlan(&plan, test_group_id),
        );
        try std.testing.expect(executor.crashed);
    }

    /// The journal lock as another process holds it: through an open file
    /// description of its own.
    fn holdForeignLock(self: *Harness) !JournalLock {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}.orca-journal.lock", .{self.database_path});
        defer std.testing.allocator.free(path);
        return (try JournalLock.tryAcquire(std.testing.io, path)).?;
    }

    fn releaseForeignLock(lock: *JournalLock) void {
        lock.release(std.testing.io);
    }

    fn groupActions(self: *Harness) [2]mutation.Action {
        return .{
            .{ .write_tags = .{
                .path = self.source,
                .expected = self.original,
                .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
            } },
            .{ .write_tags = .{
                .path = self.second,
                .expected = self.second_original,
                .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
            } },
        };
    }

    fn writeGroup(self: *Harness) !void {
        const actions = self.groupActions();
        return self.writePlan(&actions);
    }

    fn writePlan(self: *Harness, actions: []const mutation.Action) !void {
        var library = try self.open();
        defer library.close();
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, null);
        try executor.executePlan(&plan, test_group_id);
    }

    /// Undo the group and lose power at `fault`. The lock goes with the
    /// process, as it does when a real one dies.
    fn crashUndo(self: *Harness, fault: executor_module.Fault) !void {
        var library = try self.open();
        defer library.close();
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, fault);
        try std.testing.expectError(error.SimulatedPowerLoss, executor.undoGroup(test_group_id));
        try std.testing.expect(executor.crashed);
    }

    fn expectBothOriginal(self: *Harness) !void {
        try self.expectOriginal();
        try std.testing.expect(self.second_original.eql(try file_mutation.identity(std.testing.io, self.second)));
    }

    fn expectNoGroupResidue(self: *Harness) !void {
        try self.expectNoResidue();
        try std.testing.expect(!try exists(self.second_stage));
        try std.testing.expect(!try exists(self.second_restore));
        try std.testing.expect(!try exists(self.second_backup));
    }

    fn lengthenSource(self: *Harness) !void {
        try file_mutation.writeLongMpeg(self.source, "Original");
        self.original = try file_mutation.identity(std.testing.io, self.source);
    }

    fn writeFile(self: *Harness, sub_path: []const u8, data: []const u8) !void {
        try self.temporary.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn childPath(self: *Harness, sub_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.prefix, sub_path });
    }

    fn expectOriginal(self: *Harness) !void {
        try std.testing.expect(self.original.eql(try file_mutation.identity(std.testing.io, self.source)));
    }

    /// Every intermediate file a tag replacement can create must be gone once
    /// recovery has finished.
    fn expectNoResidue(self: *Harness) !void {
        try std.testing.expect(!try exists(self.stage));
        try std.testing.expect(!try exists(self.restore));
        try std.testing.expect(!try exists(self.backup));
        try std.testing.expect(!try exists(self.backup_directory));
    }
};

fn executorFor(
    library: *LibraryDatabase,
    lock: *const JournalLock,
    fault: ?executor_module.Fault,
) executor_module.Executor {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
        .journal_lock = lock,
        .backup_directory = library.backup_directory,
        .fault = fault,
    };
}

fn exists(path: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(std.testing.io);
    return true;
}

fn expectTitle(path: []const u8, expected: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    var bytes: [128]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &bytes, stat.size - bytes.len);
    try std.testing.expectEqualStrings(expected, id3v1.parse(&bytes).?.title);
}

fn expectTerminal(journal: *database.MutationJournalRepository, operation_id: i64) !void {
    switch (try journal.state(operation_id)) {
        .rolled_back, .needs_reconciliation => {},
        else => |state| {
            std.debug.print("operation {d} is still {t}\n", .{ operation_id, state });
            return error.MutationRecoveryIncomplete;
        },
    }
}

/// Crash the executor at `point`, then reopen the Library exactly as a restart
/// would and require the original file back with no residue.
fn expectConvergesFromCrash(point: executor_module.FaultPoint) !void {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.crashWrite(point);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try harness.expectOriginal();
    try harness.expectNoResidue();
}

test "recovery converges from a crash at every tag-write boundary" {
    for ([_]executor_module.FaultPoint{
        .after_journal_prepare,
        .after_stage,
        .after_stage_journaled,
        .after_backup_copy,
        .after_source_rename,
        .before_journal_commit,
    }) |point| try expectConvergesFromCrash(point);
}

test "recovery restores a move interrupted after the rename and before the commit" {
    var harness = try Harness.init();
    defer harness.deinit();
    const destination = try harness.childPath("destination.mp3");
    defer std.testing.allocator.free(destination);

    {
        var library = try harness.open();
        defer library.close();
        const actions = [_]mutation.Action{.{ .move = .{
            .source_path = harness.source,
            .destination_path = destination,
            .expected = harness.original,
        } }};
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, .{ .point = .after_move_rename });
        try std.testing.expectError(
            error.SimulatedPowerLoss,
            executor.executePlan(&plan, test_group_id),
        );
        try std.testing.expect(try exists(destination));
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try std.testing.expect(try exists(harness.source));
    try std.testing.expect(!try exists(destination));
    try expectTitle(harness.source, "Original");
}

/// A group whose second action cannot run, crashed while unwinding the first.
fn expectConvergesFromRollbackCrash(point: executor_module.FaultPoint) !void {
    var harness = try Harness.init();
    defer harness.deinit();
    const move_source = try harness.childPath("move-source.bin");
    defer std.testing.allocator.free(move_source);
    const collision = try harness.childPath("collision.bin");
    defer std.testing.allocator.free(collision);
    try harness.writeFile("move-source.bin", "generated move source");
    try harness.writeFile("collision.bin", "do not replace");

    {
        var library = try harness.open();
        defer library.close();
        const actions = [_]mutation.Action{
            .{ .write_tags = .{
                .path = harness.source,
                .expected = harness.original,
                .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
            } },
            .{ .move = .{
                .source_path = move_source,
                .destination_path = collision,
                .expected = try file_mutation.identity(std.testing.io, move_source),
            } },
        };
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, .{ .point = point });
        try std.testing.expectError(
            error.DestinationExists,
            executor.executePlan(&plan, test_group_id),
        );
        try std.testing.expect(executor.crashed);
    }

    var reopened = try harness.open();
    defer reopened.close();
    try expectTerminal(&reopened.mutation_journal, 1);
    try expectTerminal(&reopened.mutation_journal, 2);
    try harness.expectOriginal();
    try harness.expectNoResidue();
    try std.testing.expect(try exists(move_source));
    try expectFileContents(collision, "do not replace");
}

fn expectFileContents(path: []const u8, expected: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var bytes: [64]u8 = undefined;
    const read = try file.readPositionalAll(std.testing.io, bytes[0..expected.len], 0);
    try std.testing.expectEqualStrings(expected, bytes[0..read]);
}

test "recovery finishes a group rollback that was itself interrupted" {
    try expectConvergesFromRollbackCrash(.rollback_after_restore_copy);
    try expectConvergesFromRollbackCrash(.rollback_after_restore);
}

test "recovery removes a stage torn by a crash before it was journaled" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        _ = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = harness.source,
            .stage_path = harness.stage,
            .backup_path = harness.backup,
            .expected_size = harness.original.size_bytes,
            .expected_modified_ns = harness.original.modified_ns,
            .expected_quick_hash = harness.original.quick_hash,
            .expected_content_hash = harness.original.content_hash,
        });
        // A stage whose bytes never reached the disk in full and whose identity
        // was therefore never journaled.
        try harness.writeFile(".source.mp3.orca-stage-1000-0", "half-written stag");
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try harness.expectOriginal();
    try harness.expectNoResidue();
}

test "recovery keeps every file when the replacement is in place and its backup is gone" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.crashWrite(.after_source_rename);
    // The only copy of the original bytes is destroyed from outside Orca.
    try std.Io.Dir.cwd().deleteFile(std.testing.io, harness.backup);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try reopened.mutation_journal.state(1),
    );
    try expectTitle(harness.source, "Replaced");
}

test "recovery keeps every file when the backup no longer holds the original" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.crashWrite(.after_source_rename);
    const backup = try std.Io.Dir.cwd().openFile(std.testing.io, harness.backup, .{ .mode = .read_write });
    try backup.writePositionalAll(std.testing.io, "damaged", 0);
    backup.close(std.testing.io);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try reopened.mutation_journal.state(1),
    );
    try expectTitle(harness.source, "Replaced");
    try std.testing.expect(try exists(harness.backup));
}

test "recovery keeps every file when the replacement changed in its middle with its size and timestamp kept" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.lengthenSource();
    try harness.crashWrite(.after_source_rename);
    const replaced = try file_mutation.identity(std.testing.io, harness.source);
    try file_mutation.forgeInPlaceEdit(harness.source, replaced.size_bytes / 2, "EDITED");
    const edited = try file_mutation.identity(std.testing.io, harness.source);
    try std.testing.expectEqualSlices(u8, &replaced.quick_hash, &edited.quick_hash);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try reopened.mutation_journal.state(1),
    );
    try std.testing.expect(edited.eql(try file_mutation.identity(std.testing.io, harness.source)));
    try std.testing.expect(harness.original.eql(try file_mutation.identity(std.testing.io, harness.backup)));
}

test "recovery keeps every file when the backup changed in its middle with its size and timestamp kept" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.lengthenSource();
    try harness.crashWrite(.after_source_rename);
    const replaced = try file_mutation.identity(std.testing.io, harness.source);
    try file_mutation.forgeInPlaceEdit(harness.backup, harness.original.size_bytes / 2, "EDITED");
    const damaged = try file_mutation.identity(std.testing.io, harness.backup);
    try std.testing.expectEqualSlices(u8, &harness.original.quick_hash, &damaged.quick_hash);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try reopened.mutation_journal.state(1),
    );
    try std.testing.expect(replaced.eql(try file_mutation.identity(std.testing.io, harness.source)));
    try std.testing.expect(damaged.eql(try file_mutation.identity(std.testing.io, harness.backup)));
}

test "recovery restores a write journaled before content hashes by the other three parts of its identity" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.lengthenSource();
    try harness.crashWrite(.after_source_rename);
    {
        const db = try sqlite.Database.open(harness.database_path);
        defer db.close();
        try rewindToVersion55(db);
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(@as(i64, migrations.current_version), try migrations.userVersion(reopened.database));
    try std.testing.expectEqual(database.MutationState.rolled_back, try reopened.mutation_journal.state(1));
    var operation = try reopened.mutation_journal.get(std.testing.allocator, 1);
    defer operation.deinit();
    try std.testing.expect(operation.expected_content_hash == null);
    try std.testing.expect(operation.committed_content_hash == null);
    try harness.expectOriginal();
    try harness.expectNoResidue();
}

test "recovery reconciles a source that vanished along with its backup" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        const operation = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = harness.source,
            .stage_path = harness.stage,
            .backup_path = harness.backup,
            .expected_size = harness.original.size_bytes,
            .expected_modified_ns = harness.original.modified_ns,
            .expected_quick_hash = harness.original.quick_hash,
            .expected_content_hash = harness.original.content_hash,
        });
        try library.mutation_journal.recordResultIdentity(
            operation,
            .planned,
            harness.original.size_bytes,
            harness.original.modified_ns,
            harness.original.quick_hash,
            harness.original.content_hash.?,
        );
        try library.mutation_journal.transition(operation, .planned, .staged, null);
        try std.Io.Dir.cwd().deleteFile(std.testing.io, harness.source);
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try reopened.mutation_journal.state(1),
    );
}

test "recovery waits for a folder that is gone, as an unmounted drive is, and restores once it is back" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.temporary.dir.createDir(std.testing.io, "drive", .default_dir);
    try harness.temporary.dir.rename("source.mp3", harness.temporary.dir, "drive/source.mp3", std.testing.io);
    const source = try harness.childPath("drive/source.mp3");
    defer std.testing.allocator.free(source);
    {
        var library = try harness.open();
        defer library.close();
        const actions = [_]mutation.Action{.{ .write_tags = .{
            .path = source,
            .expected = harness.original,
            .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
        } }};
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, .{ .point = .after_source_rename });
        try std.testing.expectError(error.SimulatedPowerLoss, executor.executePlan(&plan, test_group_id));
    }
    try harness.temporary.dir.rename("drive", harness.temporary.dir, "unmounted", std.testing.io);

    try std.testing.expectError(error.TagTargetUnavailable, harness.open());

    try harness.temporary.dir.rename("unmounted", harness.temporary.dir, "drive", std.testing.io);
    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try std.testing.expect(harness.original.eql(try file_mutation.identity(std.testing.io, source)));
    try std.testing.expect(!try exists(harness.backup_directory));
}

test "a Library refuses to open when recovery cannot reach a terminal state" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.crashWrite(.after_source_rename);
    try harness.temporary.dir.createDir(std.testing.io, ".source.mp3.orca-restore-1000-0", .default_dir);

    if (harness.open()) |*opened| {
        var library = opened.*;
        library.close();
        return error.LibraryOpenedWithUnrecoverableJournal;
    } else |_| {}
    try expectTitle(harness.source, "Replaced");
    try std.testing.expect(harness.original.eql(try file_mutation.identity(std.testing.io, harness.backup)));

    try harness.temporary.dir.deleteDir(std.testing.io, ".source.mp3.orca-restore-1000-0");
    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try harness.expectOriginal();
    try harness.expectNoResidue();
}

test "recovery restores a write journaled with its backup beside the music" {
    var harness = try Harness.init();
    defer harness.deinit();
    const legacy_stage = try harness.childPath("source.mp3.orca-stage-1000-0");
    defer std.testing.allocator.free(legacy_stage);
    const legacy_backup = try harness.childPath("source.mp3.orca-backup-1000-0");
    defer std.testing.allocator.free(legacy_backup);
    const legacy_displaced = try harness.childPath("source.mp3.orca-stage-1000-0.recovery-displaced");
    defer std.testing.allocator.free(legacy_displaced);
    {
        var library = try harness.open();
        defer library.close();
        const operation = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = harness.source,
            .stage_path = legacy_stage,
            .backup_path = legacy_backup,
            .expected_size = harness.original.size_bytes,
            .expected_modified_ns = harness.original.modified_ns,
            .expected_quick_hash = harness.original.quick_hash,
            .expected_content_hash = harness.original.content_hash,
        });
        try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, harness.source, legacy_stage, harness.original, &.{
            .{ .field = .title, .before = "Original", .after = "Replaced" },
        }, null);
        const staged = try file_mutation.identity(std.testing.io, legacy_stage);
        try library.mutation_journal.recordResultIdentity(
            operation,
            .planned,
            staged.size_bytes,
            staged.modified_ns,
            staged.quick_hash,
            staged.content_hash.?,
        );
        try library.mutation_journal.transition(operation, .planned, .staged, null);
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(harness.source, cwd, legacy_backup, std.testing.io);
        try cwd.rename(legacy_stage, cwd, harness.source, std.testing.io);
        try harness.writeFile("source.mp3.orca-stage-1000-0.recovery-displaced", "left by a recovery");
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try harness.expectOriginal();
    try std.testing.expect(!try exists(legacy_stage));
    try std.testing.expect(!try exists(legacy_backup));
    try std.testing.expect(!try exists(legacy_displaced));
    try harness.expectNoResidue();
}

test "recovery unwinds a whole group when its last action crashed mid-rename" {
    var harness = try Harness.init();
    defer harness.deinit();
    const destination = try harness.childPath("moved.mp3");
    defer std.testing.allocator.free(destination);

    {
        var library = try harness.open();
        defer library.close();
        const actions = [_]mutation.Action{
            .{ .write_tags = .{
                .path = harness.source,
                .expected = harness.original,
                .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
            } },
            .{ .move = .{
                .source_path = harness.source,
                .destination_path = destination,
                .expected = harness.original,
            } },
        };
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, .{ .point = .after_move_rename, .action_index = 1 });
        try std.testing.expectError(
            error.SimulatedPowerLoss,
            executor.executePlan(&plan, test_group_id),
        );
        try std.testing.expect(try exists(destination));
        try std.testing.expect(!try exists(harness.source));
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(2),
    );
    try std.testing.expect(!try exists(destination));
    try harness.expectOriginal();
    try harness.expectNoResidue();
}
fn stateIn(library: *LibraryDatabase, operation_id: i64) !database.MutationState {
    return library.mutation_journal.state(operation_id);
}

test "opening a Library leaves another process's in-flight write alone" {
    var harness = try Harness.init();
    defer harness.deinit();
    var writer = try harness.open();
    defer writer.close();
    var lock = try harness.holdForeignLock();
    const journal = &writer.mutation_journal;
    const operation = try journal.prepare(.{
        .plan_id = test_plan_id,
        .group_id = test_group_id,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = harness.source,
        .stage_path = harness.stage,
        .backup_path = harness.backup,
        .expected_size = harness.original.size_bytes,
        .expected_modified_ns = harness.original.modified_ns,
        .expected_quick_hash = harness.original.quick_hash,
        .expected_content_hash = harness.original.content_hash,
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, harness.source, harness.stage, harness.original, &.{
        .{ .field = .title, .before = "Original", .after = "Replaced" },
    }, null);
    const staged = try file_mutation.identity(std.testing.io, harness.stage);
    try journal.recordResultIdentity(operation, .planned, staged.size_bytes, staged.modified_ns, staged.quick_hash, staged.content_hash.?);
    try journal.transition(operation, .planned, .staged, null);

    {
        var other = try harness.open();
        defer other.close();
        try std.testing.expectEqual(database.MutationState.staged, try stateIn(&other, operation));
        try std.testing.expect(try exists(harness.stage));
        try std.testing.expect(other.recovery_deferred.load(.acquire));
    }

    try file_mutation.createDirectoryDurably(std.testing.io, harness.backup_directory);
    try file_mutation.createDirectoryDurably(std.testing.io, std.Io.Dir.path.dirname(harness.backup).?);
    try file_mutation.commitReplacement(std.testing.io, harness.source, harness.stage, harness.backup, harness.original);
    try journal.commit(operation, staged.size_bytes, staged.modified_ns, staged.quick_hash, staged.content_hash.?);
    Harness.releaseForeignLock(&lock);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expect(!reopened.recovery_deferred.load(.acquire));
    try std.testing.expectEqual(database.MutationState.committed, try stateIn(&reopened, operation));
    try expectTitle(harness.source, "Replaced");
}

fn rewindToVersion55(db: sqlite.Database) !void {
    try db.exec(
        \\DROP INDEX files_content_hash;
        \\ALTER TABLE files DROP COLUMN content_hash_algorithm;
        \\ALTER TABLE mutation_operations DROP COLUMN committed_content_hash;
        \\ALTER TABLE mutation_operations DROP COLUMN expected_content_hash;
        \\PRAGMA user_version=55;
    );
}

fn rewindToVersion25(db: sqlite.Database) !void {
    try rewindToVersion55(db);
    try db.exec(
        \\DROP TABLE metadata_proposals;
        \\DROP TABLE track_positions;
        \\DROP TABLE player_queue_entries;
        \\DROP TABLE player_state;
        \\DROP TABLE dismissed_release_candidates;
        \\DROP INDEX releases_match_order;
        \\DROP INDEX folder_images_unmeasured;
        \\DROP INDEX observed_file_tags_artwork_unmeasured;
        \\ALTER TABLE observed_file_tags DROP COLUMN artwork_hash;
        \\ALTER TABLE observed_file_tags DROP COLUMN artwork_height;
        \\ALTER TABLE observed_file_tags DROP COLUMN artwork_width;
        \\DROP TABLE cover_art_candidates;
        \\CREATE TABLE release_artwork_v20 (
        \\    release_id INTEGER PRIMARY KEY REFERENCES releases(id) ON DELETE CASCADE,
        \\    musicbrainz_release_id TEXT NOT NULL,
        \\    image BLOB,
        \\    mime TEXT,
        \\    fetched_at INTEGER NOT NULL
        \\);
        \\INSERT INTO release_artwork_v20(release_id, musicbrainz_release_id, image, mime, fetched_at)
        \\SELECT release_id, musicbrainz_release_id, image, mime, fetched_at FROM release_artwork
        \\WHERE kind = 0 AND musicbrainz_release_id IS NOT NULL;
        \\DROP TABLE release_artwork;
        \\ALTER TABLE release_artwork_v20 RENAME TO release_artwork;
        \\ALTER TABLE observed_file_tags DROP COLUMN comment;
        \\ALTER TABLE library_health_issues DROP COLUMN similarity;
        \\ALTER TABLE listens DROP COLUMN syncable;
        \\DROP INDEX job_history_finished;
        \\DROP TABLE job_history;
        \\ALTER TABLE releases DROP COLUMN has_folder_cover;
        \\DROP TABLE folder_scans;
        \\DROP INDEX folder_images_sweep;
        \\DROP INDEX folder_images_folder;
        \\DROP TABLE folder_images;
        \\DROP TABLE release_group_covers;
        \\DROP INDEX locations_held;
        \\DROP TABLE artist_release_groups;
        \\DROP INDEX files_without_bitrate;
        \\DROP TRIGGER analysis_results_loudness_ai;
        \\DROP TRIGGER analysis_results_loudness_au;
        \\DROP TRIGGER analysis_results_loudness_ad;
        \\DROP TABLE file_loudness;
        \\DROP INDEX files_by_bitrate;
        \\DROP INDEX tracks_sort_album_artist;
        \\DROP INDEX genres_by_name;
        \\DROP INDEX track_genres_first;
        \\DROP INDEX releases_artist_order;
        \\DROP INDEX releases_title_order;
        \\DROP INDEX analysis_results_created;
        \\DROP TRIGGER tracks_genre_totals_bd;
        \\DROP TRIGGER tracks_genre_duration_au;
        \\DROP TRIGGER tracks_genre_artist_au;
        \\DROP TRIGGER tracks_genre_release_au;
        \\DROP TRIGGER releases_genre_artist_au;
        \\DROP TRIGGER track_genres_totals_ai;
        \\DROP TRIGGER track_genres_totals_ad;
        \\DROP TRIGGER track_genres_totals_au;
        \\DROP TABLE genre_artist_refs;
        \\DROP TABLE genre_release_tracks;
        \\DROP TABLE genre_totals;
        \\DROP TRIGGER tracks_au;
        \\CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
        \\    INSERT INTO track_search(track_search, rowid, title, artist, album, album_artist)
        \\    VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
        \\    INSERT INTO track_search(rowid, title, artist, album, album_artist)
        \\    VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
        \\END;
        \\DROP TABLE related_artist_photos;
        \\DROP TRIGGER artists_search_ai;
        \\DROP TRIGGER artists_search_au;
        \\DROP TRIGGER artists_search_ad;
        \\DROP TRIGGER releases_search_ai;
        \\DROP TRIGGER releases_search_au;
        \\DROP TRIGGER releases_search_ad;
        \\DROP TRIGGER playlists_search_ai;
        \\DROP TRIGGER playlists_search_au;
        \\DROP TRIGGER playlists_search_ad;
        \\DROP TRIGGER genres_search_ai;
        \\DROP TRIGGER genres_search_au;
        \\DROP TRIGGER genres_search_ad;
        \\DROP TABLE search_index;
        \\DROP TABLE library_settings;
        \\DROP TABLE playlist_tags;
        \\DROP TABLE release_info;
        \\DROP TABLE artist_related;
        \\DROP TABLE artist_links;
        \\DROP TABLE artist_loves;
        \\DROP TABLE artist_info;
        \\DROP TABLE track_genres;
        \\DROP TABLE genres;
        \\DROP TRIGGER files_recording_moves_listens;
        \\DROP INDEX listens_by_recording;
        \\DROP INDEX files_by_first_seen;
        \\DROP INDEX releases_by_year;
        \\DROP INDEX ratings_by_rating;
        \\DROP INDEX feedback_loved;
        \\DROP TABLE recording_play_stats;
        \\ALTER TABLE observed_file_tags DROP COLUMN explicit;
        \\ALTER TABLE tracks DROP COLUMN track_total;
        \\ALTER TABLE tracks DROP COLUMN disc_total;
        \\ALTER TABLE tracks DROP COLUMN explicit;
        \\ALTER TABLE releases DROP COLUMN release_type;
        \\DROP TABLE track_lyrics;
        \\DROP TABLE release_loves;
        \\DROP TABLE health_dismissals;
        \\DROP INDEX library_health_by_related;
        \\ALTER TABLE library_health_issues DROP COLUMN related_file_id;
        \\DROP TABLE recording_verifications;
        \\DROP INDEX identification_proposals_album_group;
        \\ALTER TABLE identification_proposals DROP COLUMN album_group;
        \\DROP TABLE playlist_entries;
        \\DROP TABLE playlists;
        \\DROP TABLE ratings;
        \\DROP INDEX tracks_by_recording;
        \\DROP INDEX locations_by_uri;
        \\ALTER TABLE tracks ADD COLUMN rating INTEGER CHECK (rating BETWEEN 0 AND 100);
        \\CREATE INDEX tracks_rating ON tracks(rating);
        \\PRAGMA user_version=25;
    );
}

test "rewinding to version 25 drops the folder tables, and reopening creates them again" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        const db = try sqlite.Database.open(harness.database_path);
        defer db.close();
        try rewindToVersion25(db);
        var statement = try db.prepare(
            "SELECT count(*) FROM sqlite_master WHERE name IN ('folder_images', 'folder_images_sweep', 'folder_images_folder', 'folder_scans');",
        );
        defer statement.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try statement.step());
        try std.testing.expectEqual(@as(i64, 0), statement.columnInt64(0));
    }
    var reopened = try harness.open();
    defer reopened.close();
    var statement = try reopened.database.prepare(
        "SELECT count(*) FROM sqlite_master WHERE name IN ('folder_images', 'folder_images_sweep', 'folder_images_folder', 'folder_scans');",
    );
    defer statement.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    try std.testing.expectEqual(@as(i64, 4), statement.columnInt64(0));
}

test "a Library that still needs a migration refuses to open while another process is mutating it" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        const db = try sqlite.Database.open(harness.database_path);
        defer db.close();
        try rewindToVersion25(db);
    }
    var lock = try harness.holdForeignLock();

    try std.testing.expectError(error.MutationInProgress, harness.open());
    {
        const db = try sqlite.Database.open(harness.database_path);
        defer db.close();
        try std.testing.expectEqual(@as(i64, 25), try migrations.userVersion(db));
    }

    Harness.releaseForeignLock(&lock);
    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(@as(i64, migrations.current_version), try migrations.userVersion(reopened.database));
}

test "the mutation lock is released when a write crashes, so the next open recovers it" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        var lock = try harness.holdForeignLock();
        const actions = [_]mutation.Action{.{ .write_tags = .{
            .path = harness.source,
            .expected = harness.original,
            .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
        } }};
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var executor = executorFor(&library, &lock, .{ .point = .after_source_rename });
        try std.testing.expectError(error.SimulatedPowerLoss, executor.executePlan(&plan, test_group_id));
        {
            var while_held = try harness.open();
            defer while_held.close();
            try std.testing.expect(while_held.recovery_deferred.load(.acquire));
            try std.testing.expectEqual(database.MutationState.staged, try stateIn(&while_held, 1));
        }
        lock.file.close(std.testing.io);
    }
    try expectTitle(harness.source, "Replaced");

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expect(!reopened.recovery_deferred.load(.acquire));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 1));
    try harness.expectOriginal();
    try harness.expectNoResidue();
}

test "an undo records its intent for the whole group before restoring any file" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.writeGroup();
    try harness.crashUndo(.{ .point = .undo_after_intent });

    {
        var lock = try harness.holdForeignLock();
        defer Harness.releaseForeignLock(&lock);
        var deferred = try harness.open();
        defer deferred.close();
        try std.testing.expect(deferred.recovery_deferred.load(.acquire));
        try std.testing.expectEqual(database.MutationState.undoing, try stateIn(&deferred, 1));
        try std.testing.expectEqual(database.MutationState.undoing, try stateIn(&deferred, 2));
        try expectTitle(harness.source, "Replaced");
        try expectTitle(harness.second, "Replaced");
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 2));
    try harness.expectBothOriginal();
    try harness.expectNoGroupResidue();
}

/// Crash a two-file undo at `fault`, reopen as a restart would, and require
/// both originals back with no residue.
fn expectUndoConvergesFromCrash(fault: executor_module.Fault) !void {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.writeGroup();
    try harness.crashUndo(fault);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 2));
    try harness.expectBothOriginal();
    try harness.expectNoGroupResidue();
}

test "recovery finishes an undo interrupted between two files" {
    try expectUndoConvergesFromCrash(.{ .point = .undo_after_operation, .action_index = 1 });
}

test "recovery finishes an undo interrupted after a file was restored but before the journal said so" {
    try expectUndoConvergesFromCrash(.{ .point = .rollback_after_restore, .action_index = 1 });
    try expectUndoConvergesFromCrash(.{ .point = .rollback_after_restore, .action_index = 0 });
}

test "recovery finishes an undo interrupted during a restore copy" {
    try expectUndoConvergesFromCrash(.{ .point = .rollback_after_restore_copy, .action_index = 1 });
    try expectUndoConvergesFromCrash(.{ .point = .rollback_after_restore_copy, .action_index = 0 });
}

test "an undo resumed by recovery reconciles a file that changed meanwhile, and keeps every file" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.writeGroup();
    try harness.crashUndo(.{ .point = .undo_after_intent });
    const changed = try std.Io.Dir.cwd().openFile(std.testing.io, harness.source, .{ .mode = .read_write });
    const stat = try changed.stat(std.testing.io);
    try changed.writePositionalAll(std.testing.io, "external", stat.size);
    changed.close(std.testing.io);
    const edited = try file_mutation.identity(std.testing.io, harness.source);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(database.MutationState.needs_reconciliation, try stateIn(&reopened, 1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 2));
    try std.testing.expect(edited.eql(try file_mutation.identity(std.testing.io, harness.source)));
    try std.testing.expect(harness.original.eql(try file_mutation.identity(std.testing.io, harness.backup)));
    try std.testing.expect(harness.second_original.eql(try file_mutation.identity(std.testing.io, harness.second)));
}

test "recovery marks the committed actions of an interrupted write as undoing before unwinding them" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        const actions = harness.groupActions();
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor = executorFor(&library, &lock, .{ .point = .after_stage_journaled, .action_index = 1 });
        try std.testing.expectError(error.SimulatedPowerLoss, executor.executePlan(&plan, test_group_id));
    }

    var lock = try harness.holdForeignLock();
    {
        var library = try harness.open();
        defer library.close();
        try std.testing.expectEqual(database.MutationState.committed, try stateIn(&library, 1));
        try std.testing.expectEqual(database.MutationState.staged, try stateIn(&library, 2));
        try std.testing.expectError(error.SimulatedPowerLoss, recoverPending(
            std.testing.allocator,
            std.testing.io,
            &library.mutation_journal,
            library.backup_directory,
            &lock,
            .{ .point = .recovery_after_operation, .action_index = 1 },
        ));
        try std.testing.expectEqual(database.MutationState.undoing, try stateIn(&library, 1));
        try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&library, 2));
        try expectTitle(harness.source, "Replaced");
    }
    Harness.releaseForeignLock(&lock);

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 2));
    try harness.expectBothOriginal();
    try harness.expectNoGroupResidue();
}

test "a crashed undo of a moved and re-tagged file restores the path before the bytes" {
    var harness = try Harness.init();
    defer harness.deinit();
    const destination = try harness.childPath("moved.mp3");
    defer std.testing.allocator.free(destination);
    const actions = [_]mutation.Action{
        .{ .write_tags = .{
            .path = harness.source,
            .expected = harness.original,
            .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
        } },
        .{ .move = .{
            .source_path = harness.source,
            .destination_path = destination,
            .expected = harness.original,
        } },
    };
    try harness.writePlan(&actions);
    try expectTitle(destination, "Replaced");
    try harness.crashUndo(.{ .point = .undo_after_intent });
    try std.testing.expect(!try exists(harness.source));

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 2));
    try std.testing.expect(!try exists(destination));
    try harness.expectOriginal();
    try harness.expectNoResidue();
}

test "an undo converted by migration 26 finishes in the same open" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.writeGroup();
    try harness.crashUndo(.{ .point = .undo_after_operation, .action_index = 1 });
    {
        const db = try sqlite.Database.open(harness.database_path);
        defer db.close();
        try db.exec("UPDATE mutation_operations SET state = 2 WHERE state = 6;");
        try rewindToVersion25(db);
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(@as(i64, migrations.current_version), try migrations.userVersion(reopened.database));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try stateIn(&reopened, 2));
    try harness.expectBothOriginal();
    try harness.expectNoGroupResidue();
}
