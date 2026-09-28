const std = @import("std");
const quick_hash = @import("../storage/quick_hash.zig");
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
) !Summary {
    const group_ids = try journal.nonterminalGroupIds(allocator);
    defer allocator.free(group_ids);
    var summary: Summary = .{ .groups = group_ids.len };
    if (group_ids.len == 0) return summary;

    var executor: executor_module.Executor = .{
        .allocator = allocator,
        .io = io,
        .journal = journal,
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
    backup: []u8,
    displaced: []u8,
    database_path: [:0]u8,

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
            "{s}.orca-stage-{d}-0",
            .{ source, test_plan_id },
        );
        errdefer allocator.free(stage);
        const backup = try std.fmt.allocPrint(
            allocator,
            "{s}.orca-backup-{d}-0",
            .{ source, test_plan_id },
        );
        errdefer allocator.free(backup);
        const displaced = try std.fmt.allocPrint(allocator, "{s}.recovery-displaced", .{stage});
        errdefer allocator.free(displaced);
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
        return .{
            .temporary = temporary,
            .prefix = prefix,
            .source = source,
            .stage = stage,
            .backup = backup,
            .displaced = displaced,
            .database_path = database_path,
        };
    }

    fn deinit(self: *Harness) void {
        const allocator = std.testing.allocator;
        allocator.free(self.prefix);
        allocator.free(self.source);
        allocator.free(self.stage);
        allocator.free(self.backup);
        allocator.free(self.displaced);
        allocator.free(self.database_path);
        self.temporary.cleanup();
    }

    fn open(self: *Harness) !LibraryDatabase {
        return LibraryDatabase.open(std.testing.allocator, std.testing.io, self.database_path);
    }

    fn writeFile(self: *Harness, sub_path: []const u8, data: []const u8) !void {
        try self.temporary.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn childPath(self: *Harness, sub_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.prefix, sub_path });
    }

    /// Every intermediate file a tag replacement can create must be gone once
    /// recovery has finished.
    fn expectNoResidue(self: *Harness) !void {
        try std.testing.expect(!try exists(self.stage));
        try std.testing.expect(!try exists(self.backup));
        try std.testing.expect(!try exists(self.displaced));
    }
};

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

    {
        var library = try harness.open();
        defer library.close();
        const expected = try file_mutation.identity(std.testing.io, harness.source);
        const actions = [_]mutation.Action{.{ .write_tags = .{
            .path = harness.source,
            .expected = expected,
            .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
        } }};
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var executor: executor_module.Executor = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .journal = &library.mutation_journal,
            .fault = .{ .point = point },
        };
        try std.testing.expectError(
            error.SimulatedPowerLoss,
            executor.executePlan(&plan, test_group_id),
        );
        try std.testing.expect(executor.crashed);
    }

    var reopened = try harness.open();
    defer reopened.close();
    try expectTerminal(&reopened.mutation_journal, 1);
    try expectTitle(harness.source, "Original");
    try harness.expectNoResidue();
}

test "recovery converges from a crash at every tag-write boundary" {
    for ([_]executor_module.FaultPoint{
        .after_journal_prepare,
        .after_stage,
        .after_stage_journaled,
        .after_backup_rename,
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
        const expected = try file_mutation.identity(std.testing.io, harness.source);
        const actions = [_]mutation.Action{.{ .move = .{
            .source_path = harness.source,
            .destination_path = destination,
            .expected = expected,
        } }};
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var executor: executor_module.Executor = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .journal = &library.mutation_journal,
            .fault = .{ .point = .after_move_rename },
        };
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
                .expected = try file_mutation.identity(std.testing.io, harness.source),
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
        var executor: executor_module.Executor = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .journal = &library.mutation_journal,
            .fault = .{ .point = point },
        };
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
    try expectTitle(harness.source, "Original");
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
    try expectConvergesFromRollbackCrash(.rollback_after_displace);
    try expectConvergesFromRollbackCrash(.rollback_after_restore);
}

test "recovery removes a stage torn by a crash before it was journaled" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        const expected = try file_mutation.identity(std.testing.io, harness.source);
        _ = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = harness.source,
            .stage_path = harness.stage,
            .backup_path = harness.backup,
            .expected_size = expected.size_bytes,
            .expected_modified_ns = expected.modified_ns,
            .expected_quick_hash = expected.quick_hash,
        });
        // A stage whose bytes never reached the disk in full and whose identity
        // was therefore never journaled.
        try harness.writeFile("source.mp3.orca-stage-1000-0", "half-written stag");
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try reopened.mutation_journal.state(1),
    );
    try expectTitle(harness.source, "Original");
    try harness.expectNoResidue();
}

test "recovery reconciles rather than claiming a rollback it cannot prove" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        const expected = try file_mutation.identity(std.testing.io, harness.source);
        const operation = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = harness.source,
            .stage_path = harness.stage,
            .backup_path = harness.backup,
            .expected_size = expected.size_bytes,
            .expected_modified_ns = expected.modified_ns,
            .expected_quick_hash = expected.quick_hash,
        });
        try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, harness.source, harness.stage, expected, &.{
            .{ .field = .title, .before = "Original", .after = "Replaced" },
        });
        const staged = try file_mutation.identity(std.testing.io, harness.stage);
        try library.mutation_journal.recordResultIdentity(
            operation,
            .planned,
            staged.size_bytes,
            staged.modified_ns,
            staged.quick_hash,
        );
        try library.mutation_journal.transition(operation, .planned, .staged, null);
        try file_mutation.commitReplacement(
            std.testing.io,
            harness.source,
            harness.stage,
            harness.backup,
            expected,
        );
        // The replacement is committed to the filesystem and the only copy of
        // the original bytes has been destroyed from outside Orca.
        try std.Io.Dir.cwd().deleteFile(std.testing.io, harness.backup);
    }

    var reopened = try harness.open();
    defer reopened.close();
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try reopened.mutation_journal.state(1),
    );
    // Every file is retained; nothing claims the original was restored.
    try expectTitle(harness.source, "Replaced");
}

test "recovery reconciles a source that vanished along with its backup" {
    var harness = try Harness.init();
    defer harness.deinit();
    {
        var library = try harness.open();
        defer library.close();
        const expected = try file_mutation.identity(std.testing.io, harness.source);
        const operation = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = harness.source,
            .stage_path = harness.stage,
            .backup_path = harness.backup,
            .expected_size = expected.size_bytes,
            .expected_modified_ns = expected.modified_ns,
            .expected_quick_hash = expected.quick_hash,
        });
        try library.mutation_journal.recordResultIdentity(
            operation,
            .planned,
            expected.size_bytes,
            expected.modified_ns,
            expected.quick_hash,
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

test "a Library refuses to open when recovery cannot reach a terminal state" {
    var harness = try Harness.init();
    defer harness.deinit();
    const unreachable_source = try harness.childPath("absent-directory/source.mp3");
    defer std.testing.allocator.free(unreachable_source);
    {
        var library = try harness.open();
        defer library.close();
        const operation = try library.mutation_journal.prepare(.{
            .plan_id = test_plan_id,
            .group_id = test_group_id,
            .action_index = 0,
            .kind = .write_tags,
            .source_path = unreachable_source,
            .stage_path = harness.stage,
            .backup_path = harness.backup,
            .expected_size = 1,
            .expected_modified_ns = 1,
            .expected_quick_hash = quick_hash.zero,
        });
        try library.mutation_journal.transition(operation, .planned, .staged, null);
        try harness.writeFile("source.mp3.orca-backup-1000-0", "the only original copy");
    }

    if (harness.open()) |*opened| {
        var library = opened.*;
        library.close();
        return error.LibraryOpenedWithUnrecoverableJournal;
    } else |_| {}
}

test "recovery unwinds a whole group when its last action crashed mid-rename" {
    var harness = try Harness.init();
    defer harness.deinit();
    const destination = try harness.childPath("moved.mp3");
    defer std.testing.allocator.free(destination);

    {
        var library = try harness.open();
        defer library.close();
        const expected = try file_mutation.identity(std.testing.io, harness.source);
        const actions = [_]mutation.Action{
            .{ .write_tags = .{
                .path = harness.source,
                .expected = expected,
                .changes = &.{.{ .field = .title, .before = "Original", .after = "Replaced" }},
            } },
            .{ .move = .{
                .source_path = harness.source,
                .destination_path = destination,
                .expected = expected,
            } },
        };
        var plan = try mutation.Plan.init(std.testing.allocator, test_plan_id, &actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var executor: executor_module.Executor = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .journal = &library.mutation_journal,
            .fault = .{ .point = .after_move_rename, .action_index = 1 },
        };
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
    try expectTitle(harness.source, "Original");
    try harness.expectNoResidue();
}
