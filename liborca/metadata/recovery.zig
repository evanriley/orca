const std = @import("std");
const database = @import("../database/repository.zig");
const executor_module = @import("executor.zig");

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
) !Summary {
    const group_ids = try journal.nonterminalGroupIds(allocator);
    defer allocator.free(group_ids);
    var summary: Summary = .{ .groups = group_ids.len };
    if (group_ids.len == 0) return summary;

    var executor: executor_module.Executor = .{
        .allocator = allocator,
        .io = io,
        .journal = journal,
        .backup_directory = backup_directory,
    };
    for (group_ids) |group_id| {
        const operation_ids = try journal.groupOperationIds(allocator, group_id);
        defer allocator.free(operation_ids);
        for (operation_ids) |operation_id| {
            executor.recoverOperation(operation_id) catch |err| switch (err) {
                error.MutationNeedsReconciliation => {},
                else => return err,
            };
        }
    }

    for (group_ids) |group_id| {
        const operation_ids = try journal.groupOperationIds(allocator, group_id);
        defer allocator.free(operation_ids);
        for (operation_ids) |operation_id| {
            summary.operations += 1;
            switch (try journal.state(operation_id)) {
                .rolled_back => summary.rolled_back += 1,
                .needs_reconciliation => summary.needs_reconciliation += 1,
                .committed => {},
                .planned, .staged, .failed => return error.MutationRecoveryIncomplete,
            }
        }
    }
    return summary;
}

const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
const file_mutation = @import("file_mutation.zig");
const id3v1 = @import("id3v1.zig");
const mutation = @import("mutation.zig");

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
    database_path: [:0]u8,
    original: mutation.FileIdentity,

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
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "source.mp3",
            .data = "\xff\xfb\x90\x64generated audio payload" ++ (try id3v1.encode(.{
                .title = "Original",
                .artist = "Generated",
                .album = "Generated",
                .year = "2026",
                .comment = "Generated",
                .track_number = 1,
                .genre = 13,
            })),
        });
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
        return .{
            .temporary = temporary,
            .prefix = prefix,
            .source = source,
            .stage = stage,
            .restore = restore,
            .backup_directory = backup_directory,
            .backup = backup,
            .database_path = database_path,
            .original = try file_mutation.identity(std.testing.io, source),
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
        var executor = executorFor(&library, .{ .point = point });
        try std.testing.expectError(
            error.SimulatedPowerLoss,
            executor.executePlan(&plan, test_group_id),
        );
        try std.testing.expect(executor.crashed);
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

fn executorFor(library: *LibraryDatabase, fault: ?executor_module.Fault) executor_module.Executor {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
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
        var executor = executorFor(&library, .{ .point = .after_move_rename });
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
        var executor = executorFor(&library, .{ .point = point });
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
        });
        try library.mutation_journal.recordResultIdentity(
            operation,
            .planned,
            harness.original.size_bytes,
            harness.original.modified_ns,
            harness.original.quick_hash,
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
        var executor = executorFor(&library, .{ .point = .after_source_rename });
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
        });
        try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, harness.source, legacy_stage, harness.original, &.{
            .{ .field = .title, .before = "Original", .after = "Replaced" },
        });
        const staged = try file_mutation.identity(std.testing.io, legacy_stage);
        try library.mutation_journal.recordResultIdentity(
            operation,
            .planned,
            staged.size_bytes,
            staged.modified_ns,
            staged.quick_hash,
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
        var executor = executorFor(&library, .{ .point = .after_move_rename, .action_index = 1 });
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
