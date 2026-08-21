const std = @import("std");
const database = @import("../database/repository.zig");
const file_mutation = @import("file_mutation.zig");
const mutation = @import("mutation.zig");

pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *database.MutationJournalRepository,

    /// Execute every tag action as one logical group. Each path is staged
    /// before replacement and each original remains as a journaled backup.
    pub fn executePlan(self: *Executor, plan: *mutation.Plan, group_id: u64) !void {
        if (group_id == 0) return error.InvalidMutationGroup;
        for (plan.actions) |action| switch (action) {
            .write_tags => |write| _ = tagFormat(write.path) orelse
                return error.UnsupportedTagWriter,
            .move => {},
        };
        var completed: std.ArrayList(i64) = .empty;
        defer completed.deinit(self.allocator);
        try completed.ensureTotalCapacity(self.allocator, plan.actions.len);
        try plan.beginExecution();
        errdefer {
            var index = completed.items.len;
            while (index > 0) {
                index -= 1;
                self.rollbackOperation(completed.items[index]) catch {};
            }
            plan.finish(false) catch {};
        }

        for (plan.actions, 0..) |action, action_index| switch (action) {
            .write_tags => |write| {
                const stage_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}.orca-stage-{d}-{d}",
                    .{ write.path, plan.id, action_index },
                );
                defer self.allocator.free(stage_path);
                const backup_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}.orca-backup-{d}-{d}",
                    .{ write.path, plan.id, action_index },
                );
                defer self.allocator.free(backup_path);
                const operation = try self.journal.prepare(.{
                    .plan_id = plan.id,
                    .group_id = group_id,
                    .action_index = @intCast(action_index),
                    .kind = .write_tags,
                    .source_path = write.path,
                    .stage_path = stage_path,
                    .backup_path = backup_path,
                    .expected_size = write.expected.size_bytes,
                    .expected_modified_ns = write.expected.modified_ns,
                });
                const format = tagFormat(write.path).?;
                (switch (format) {
                    .id3v1 => file_mutation.stageId3v1(
                        self.io,
                        write.path,
                        stage_path,
                        write.expected,
                        write.changes,
                    ),
                    .flac => file_mutation.stageFlac(
                        self.allocator,
                        self.io,
                        write.path,
                        stage_path,
                        write.expected,
                        write.changes,
                    ),
                }) catch |err| {
                    self.journal.transition(operation, .planned, .failed, @errorName(err)) catch {};
                    return err;
                };
                const staged_identity = try file_mutation.identity(self.io, stage_path);
                try self.journal.recordResultIdentity(
                    operation,
                    .planned,
                    staged_identity.size_bytes,
                    staged_identity.modified_ns,
                );
                try self.journal.transition(operation, .planned, .staged, null);
                file_mutation.commitReplacement(
                    self.io,
                    write.path,
                    stage_path,
                    backup_path,
                ) catch |err| {
                    std.Io.Dir.cwd().deleteFile(self.io, stage_path) catch {};
                    self.journal.transition(operation, .staged, .failed, @errorName(err)) catch {};
                    return err;
                };
                completed.appendAssumeCapacity(operation);
                const committed = try file_mutation.identity(self.io, write.path);
                try self.journal.commit(
                    operation,
                    committed.size_bytes,
                    committed.modified_ns,
                );
            },
            .move => |move| {
                const current = try file_mutation.identity(self.io, move.source_path);
                if (!std.meta.eql(current, move.expected) and
                    !try self.groupProducedIdentity(completed.items, move.source_path, current))
                    return error.FileIdentityChanged;
                if (try pathExists(self.io, move.destination_path)) return error.DestinationExists;
                const operation = try self.journal.prepare(.{
                    .plan_id = plan.id,
                    .group_id = group_id,
                    .action_index = @intCast(action_index),
                    .kind = .move,
                    .source_path = move.source_path,
                    .destination_path = move.destination_path,
                    .expected_size = move.expected.size_bytes,
                    .expected_modified_ns = move.expected.modified_ns,
                });
                try self.journal.recordResultIdentity(
                    operation,
                    .planned,
                    current.size_bytes,
                    current.modified_ns,
                );
                try self.journal.transition(operation, .planned, .staged, null);
                std.Io.Dir.cwd().renamePreserve(
                    move.source_path,
                    std.Io.Dir.cwd(),
                    move.destination_path,
                    self.io,
                ) catch |err| {
                    self.journal.transition(operation, .staged, .failed, @errorName(err)) catch {};
                    return err;
                };
                completed.appendAssumeCapacity(operation);
                const committed = try file_mutation.identity(self.io, move.destination_path);
                try self.journal.commit(
                    operation,
                    committed.size_bytes,
                    committed.modified_ns,
                );
            },
        };
        try plan.finish(true);
    }

    fn groupProducedIdentity(
        self: *Executor,
        operation_ids: []const i64,
        path: []const u8,
        current: mutation.FileIdentity,
    ) !bool {
        var index = operation_ids.len;
        while (index > 0) {
            index -= 1;
            var operation = try self.journal.get(self.allocator, operation_ids[index]);
            defer operation.deinit();
            if (operation.kind == .write_tags and
                std.mem.eql(u8, operation.source_path, path) and
                operation.committed_size == current.size_bytes and
                operation.committed_modified_ns == current.modified_ns)
                return true;
        }
        return false;
    }

    /// Undo refuses to replace a file that changed after the journaled commit.
    pub fn undoOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state != .committed) return error.MutationOperationNotCommitted;
        const expected: mutation.FileIdentity = .{
            .size_bytes = operation.committed_size orelse return error.MissingCommittedIdentity,
            .modified_ns = operation.committed_modified_ns orelse
                return error.MissingCommittedIdentity,
        };
        const current_path = switch (operation.kind) {
            .write_tags => operation.source_path,
            .move => operation.destination_path orelse return error.MissingMutationDestination,
        };
        const current = try file_mutation.identity(self.io, current_path);
        if (!std.meta.eql(expected, current)) {
            try self.journal.transition(
                operation_id,
                .committed,
                .needs_reconciliation,
                "undo target changed externally",
            );
            return error.MutationNeedsReconciliation;
        }
        try self.rollbackOperation(operation_id);
    }

    /// Undo a logical group only after every current after-state has been
    /// validated. Operations then reverse in action order so write-then-move
    /// plans restore the path before restoring the original tagged bytes.
    pub fn undoGroup(self: *Executor, group_id: u64) !void {
        if (group_id == 0) return error.InvalidMutationGroup;
        const ids = try self.journal.groupOperationIds(self.allocator, group_id);
        defer self.allocator.free(ids);
        if (ids.len == 0) return error.MutationGroupNotFound;
        var operations: std.ArrayList(database.MutationOperation) = .empty;
        defer {
            for (operations.items) |operation| operation.deinit();
            operations.deinit(self.allocator);
        }
        try operations.ensureTotalCapacity(self.allocator, ids.len);
        for (ids) |id| operations.appendAssumeCapacity(
            try self.journal.get(self.allocator, id),
        );

        for (operations.items, 0..) |operation, index| {
            if (operation.state != .committed)
                return error.MutationGroupNotCommitted;
            var current_path = switch (operation.kind) {
                .write_tags => operation.source_path,
                .move => operation.destination_path orelse
                    return error.MissingMutationDestination,
            };
            var later_index = index;
            while (later_index > 0) {
                later_index -= 1;
                const later = operations.items[later_index];
                if (later.kind == .move and std.mem.eql(u8, later.source_path, current_path))
                    current_path = later.destination_path orelse
                        return error.MissingMutationDestination;
            }
            if (!try pathExists(self.io, current_path)) {
                try self.reconcile(operation.id, operation.state, "group undo target is missing");
                return error.MutationNeedsReconciliation;
            }
            const current = try file_mutation.identity(self.io, current_path);
            if (!std.meta.eql(try resultIdentity(operation), current)) {
                try self.reconcile(operation.id, operation.state, "group undo target changed externally");
                return error.MutationNeedsReconciliation;
            }
            if (operation.kind == .move and try pathExists(self.io, operation.source_path)) {
                try self.reconcile(operation.id, operation.state, "group undo destination exists");
                return error.MutationNeedsReconciliation;
            }
        }
        for (ids) |id| try self.rollbackOperation(id);
    }

    /// Resolve a nonterminal journal entry after interruption. Recovery always
    /// prefers the original bytes and never assumes a staged replacement won.
    pub fn recoverOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state == .committed or operation.state == .rolled_back or
            operation.state == .needs_reconciliation) return;
        if (operation.kind == .move) {
            const destination = operation.destination_path orelse
                return error.MissingMutationDestination;
            if (try pathExists(self.io, destination)) {
                if (try pathExists(self.io, operation.source_path)) {
                    try self.reconcile(operation_id, operation.state, "move source and destination both exist");
                    return error.MutationNeedsReconciliation;
                }
                const current = try file_mutation.identity(self.io, destination);
                if (!std.meta.eql(try resultIdentity(operation), current)) {
                    try self.reconcile(operation_id, operation.state, "move destination changed externally");
                    return error.MutationNeedsReconciliation;
                }
                try std.Io.Dir.cwd().renamePreserve(
                    destination,
                    std.Io.Dir.cwd(),
                    operation.source_path,
                    self.io,
                );
            }
            return self.finishRecoveryState(operation_id, operation.state);
        }
        const stage_path = operation.stage_path orelse return error.MissingMutationStagePath;
        const backup_path = operation.backup_path orelse return error.MissingMutationBackupPath;
        if (try pathExists(self.io, backup_path)) {
            if (try pathExists(self.io, operation.source_path)) {
                const current = try file_mutation.identity(self.io, operation.source_path);
                if (!std.meta.eql(try resultIdentity(operation), current)) {
                    try self.reconcile(operation_id, operation.state, "tag target changed externally");
                    return error.MutationNeedsReconciliation;
                }
            }
            const displaced_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}.recovery-displaced",
                .{stage_path},
            );
            defer self.allocator.free(displaced_path);
            try file_mutation.rollbackReplacement(
                self.io,
                operation.source_path,
                backup_path,
                displaced_path,
            );
        }
        std.Io.Dir.cwd().deleteFile(self.io, stage_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try self.finishRecoveryState(operation_id, operation.state);
    }

    fn finishRecoveryState(
        self: *Executor,
        operation_id: i64,
        state: database.MutationState,
    ) !void {
        switch (state) {
            .planned => {
                try self.journal.transition(operation_id, .planned, .failed, "recovered");
                try self.journal.transition(operation_id, .failed, .rolled_back, "recovered");
            },
            .staged => try self.journal.transition(
                operation_id,
                .staged,
                .rolled_back,
                "recovered",
            ),
            .failed => try self.journal.transition(
                operation_id,
                .failed,
                .rolled_back,
                "recovered",
            ),
            .committed, .rolled_back, .needs_reconciliation => unreachable,
        }
    }

    fn reconcile(
        self: *Executor,
        operation_id: i64,
        state: database.MutationState,
        message: []const u8,
    ) !void {
        try self.journal.transition(operation_id, state, .needs_reconciliation, message);
    }

    fn rollbackOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state != .committed and operation.state != .staged)
            return error.MutationOperationNotRecoverable;
        if (operation.kind == .move) {
            const destination = operation.destination_path orelse
                return error.MissingMutationDestination;
            if (try pathExists(self.io, operation.source_path)) {
                try self.reconcile(operation_id, operation.state, "move source already exists");
                return error.MutationNeedsReconciliation;
            }
            try std.Io.Dir.cwd().renamePreserve(
                destination,
                std.Io.Dir.cwd(),
                operation.source_path,
                self.io,
            );
            try self.journal.transition(operation_id, operation.state, .rolled_back, null);
            return;
        }
        const stage_path = operation.stage_path orelse return error.MissingMutationStagePath;
        const backup_path = operation.backup_path orelse return error.MissingMutationBackupPath;
        try file_mutation.rollbackReplacement(
            self.io,
            operation.source_path,
            backup_path,
            stage_path,
        );
        try self.journal.transition(operation_id, operation.state, .rolled_back, null);
    }
};

fn resultIdentity(operation: database.MutationOperation) !mutation.FileIdentity {
    return .{
        .size_bytes = operation.committed_size orelse return error.MissingCommittedIdentity,
        .modified_ns = operation.committed_modified_ns orelse
            return error.MissingCommittedIdentity,
    };
}

const TagFormat = enum { id3v1, flac };

fn tagFormat(path: []const u8) ?TagFormat {
    if (hasExtension(path, ".mp3")) return .id3v1;
    if (hasExtension(path, ".flac")) return .flac;
    return null;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    return path.len >= extension.len and
        std.ascii.eqlIgnoreCase(path[path.len - extension.len ..], extension);
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

test "approved plan commits through journal and undo detects external edits" {
    const id3v1 = @import("id3v1.zig");
    const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.mp3", .{prefix});
    defer std.testing.allocator.free(source_path);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/library.db",
        .{prefix},
        0,
    );
    defer std.testing.allocator.free(database_path);
    const tag = try id3v1.encode(.{
        .title = "Old title",
        .artist = "Generated",
        .album = "Generated",
        .year = "2026",
        .comment = "Generated",
        .track_number = 1,
        .genre = 13,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.mp3",
        .data = "generated payload" ++ tag,
    });
    const expected = try file_mutation.identity(std.testing.io, source_path);
    const actions = [_]mutation.Action{.{ .write_tags = .{
        .path = source_path,
        .expected = expected,
        .changes = &.{.{ .field = .title, .before = "Old title", .after = "New title" }},
    } }};
    var plan = try mutation.Plan.init(44, &actions);
    var library = try LibraryDatabase.open(std.testing.allocator, database_path);
    defer library.close();
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
    };
    try std.testing.expectError(error.MutationPlanNotApproved, executor.executePlan(&plan, 8));
    try plan.approve(44);
    try executor.executePlan(&plan, 8);
    try std.testing.expectEqual(mutation.State.completed, plan.state);
    try std.testing.expectEqual(database.MutationState.committed, try library.mutation_journal.state(1));
    try executor.undoOperation(1);
    try std.testing.expectEqual(database.MutationState.rolled_back, try library.mutation_journal.state(1));
    try expectTitle(source_path, "Old title");

    const second_expected = try file_mutation.identity(std.testing.io, source_path);
    const second_actions = [_]mutation.Action{.{ .write_tags = .{
        .path = source_path,
        .expected = second_expected,
        .changes = &.{.{ .field = .title, .before = "Old title", .after = "New title" }},
    } }};
    var second_plan = try mutation.Plan.init(45, &second_actions);
    try second_plan.approve(45);
    try executor.executePlan(&second_plan, 9);

    const changed = try std.Io.Dir.cwd().openFile(std.testing.io, source_path, .{ .mode = .read_write });
    defer changed.close(std.testing.io);
    const stat = try changed.stat(std.testing.io);
    try changed.writePositionalAll(std.testing.io, "external", stat.size);
    try std.testing.expectError(error.MutationNeedsReconciliation, executor.undoOperation(2));
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try library.mutation_journal.state(2),
    );
}

fn expectTitle(path: []const u8, expected: []const u8) !void {
    const id3v1 = @import("id3v1.zig");
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    var bytes: [128]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &bytes, stat.size - bytes.len);
    try std.testing.expectEqualStrings(expected, id3v1.parse(&bytes).?.title);
}

test "recovery restores original after replacement before journal commit" {
    const id3v1 = @import("id3v1.zig");
    const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/crash.mp3", .{prefix});
    defer std.testing.allocator.free(source);
    const stage = try std.fmt.allocPrint(std.testing.allocator, "{s}/crash.stage", .{prefix});
    defer std.testing.allocator.free(stage);
    const backup = try std.fmt.allocPrint(std.testing.allocator, "{s}/crash.backup", .{prefix});
    defer std.testing.allocator.free(backup);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/crash.db",
        .{prefix},
        0,
    );
    defer std.testing.allocator.free(database_path);
    const tag = try id3v1.encode(.{
        .title = "Before crash",
        .artist = "Generated",
        .album = "Generated",
        .year = "2026",
        .comment = "Generated",
        .track_number = 1,
        .genre = 13,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "crash.mp3",
        .data = "generated payload" ++ tag,
    });
    const expected = try file_mutation.identity(std.testing.io, source);
    var library = try LibraryDatabase.open(std.testing.allocator, database_path);
    defer library.close();
    const operation = try library.mutation_journal.prepare(.{
        .plan_id = 90,
        .group_id = 90,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = source,
        .stage_path = stage,
        .backup_path = backup,
        .expected_size = expected.size_bytes,
        .expected_modified_ns = expected.modified_ns,
    });
    try file_mutation.stageId3v1(std.testing.io, source, stage, expected, &.{.{
        .field = .title,
        .before = "Before crash",
        .after = "Interrupted",
    }});
    const staged_identity = try file_mutation.identity(std.testing.io, stage);
    try library.mutation_journal.recordResultIdentity(
        operation,
        .planned,
        staged_identity.size_bytes,
        staged_identity.modified_ns,
    );
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    try file_mutation.commitReplacement(std.testing.io, source, stage, backup);

    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
    };
    try executor.recoverOperation(operation);
    try expectTitle(source, "Before crash");
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try library.mutation_journal.state(operation),
    );

    const expected_again = try file_mutation.identity(std.testing.io, source);
    const staged_only = try library.mutation_journal.prepare(.{
        .plan_id = 91,
        .group_id = 91,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = source,
        .stage_path = stage,
        .backup_path = backup,
        .expected_size = expected_again.size_bytes,
        .expected_modified_ns = expected_again.modified_ns,
    });
    try file_mutation.stageId3v1(std.testing.io, source, stage, expected_again, &.{.{
        .field = .title,
        .before = "Before crash",
        .after = "Staged only",
    }});
    const staged_only_identity = try file_mutation.identity(std.testing.io, stage);
    try library.mutation_journal.recordResultIdentity(
        staged_only,
        .planned,
        staged_only_identity.size_bytes,
        staged_only_identity.modified_ns,
    );
    try library.mutation_journal.transition(staged_only, .planned, .staged, null);
    try executor.recoverOperation(staged_only);
    try expectTitle(source, "Before crash");
    try std.testing.expect(!(try pathExists(std.testing.io, stage)));

    const planned_only = try library.mutation_journal.prepare(.{
        .plan_id = 92,
        .group_id = 92,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = source,
        .stage_path = stage,
        .backup_path = backup,
        .expected_size = expected_again.size_bytes,
        .expected_modified_ns = expected_again.modified_ns,
    });
    try executor.recoverOperation(planned_only);
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try library.mutation_journal.state(planned_only),
    );

    const changed_during_recovery = try library.mutation_journal.prepare(.{
        .plan_id = 93,
        .group_id = 93,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = source,
        .stage_path = stage,
        .backup_path = backup,
        .expected_size = expected_again.size_bytes,
        .expected_modified_ns = expected_again.modified_ns,
    });
    try file_mutation.stageId3v1(std.testing.io, source, stage, expected_again, &.{.{
        .field = .title,
        .before = "Before crash",
        .after = "Interrupted again",
    }});
    const changed_stage_identity = try file_mutation.identity(std.testing.io, stage);
    try library.mutation_journal.recordResultIdentity(
        changed_during_recovery,
        .planned,
        changed_stage_identity.size_bytes,
        changed_stage_identity.modified_ns,
    );
    try library.mutation_journal.transition(changed_during_recovery, .planned, .staged, null);
    try file_mutation.commitReplacement(std.testing.io, source, stage, backup);
    const externally_changed = try std.Io.Dir.cwd().openFile(
        std.testing.io,
        source,
        .{ .mode = .read_write },
    );
    defer externally_changed.close(std.testing.io);
    const changed_stat = try externally_changed.stat(std.testing.io);
    try externally_changed.writePositionalAll(std.testing.io, "external", changed_stat.size);
    try std.testing.expectError(
        error.MutationNeedsReconciliation,
        executor.recoverOperation(changed_during_recovery),
    );
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try library.mutation_journal.state(changed_during_recovery),
    );
}

test "approved move supports undo and rejects an externally edited destination" {
    const id3v1 = @import("id3v1.zig");
    const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.mp3", .{prefix});
    defer std.testing.allocator.free(source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, "{s}/destination.mp3", .{prefix});
    defer std.testing.allocator.free(destination);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/moves.db",
        .{prefix},
        0,
    );
    defer std.testing.allocator.free(database_path);
    const tag = try id3v1.encode(.{
        .title = "Before move",
        .artist = "Generated",
        .album = "Generated",
        .year = "2026",
        .comment = "Generated",
        .track_number = 1,
        .genre = 13,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.mp3",
        .data = "generated payload" ++ tag,
    });
    var library = try LibraryDatabase.open(std.testing.allocator, database_path);
    defer library.close();
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
    };

    const expected = try file_mutation.identity(std.testing.io, source);
    const actions = [_]mutation.Action{
        .{ .write_tags = .{
            .path = source,
            .expected = expected,
            .changes = &.{.{
                .field = .title,
                .before = "Before move",
                .after = "After move",
            }},
        } },
        .{ .move = .{
            .source_path = source,
            .destination_path = destination,
            .expected = expected,
        } },
    };
    var plan = try mutation.Plan.init(100, &actions);
    try plan.approve(100);
    try executor.executePlan(&plan, 100);
    try std.testing.expect(!(try pathExists(std.testing.io, source)));
    try std.testing.expect(try pathExists(std.testing.io, destination));
    try expectTitle(destination, "After move");
    try executor.undoGroup(100);
    try std.testing.expect(try pathExists(std.testing.io, source));
    try std.testing.expect(!(try pathExists(std.testing.io, destination)));
    try expectTitle(source, "Before move");

    const second_expected = try file_mutation.identity(std.testing.io, source);
    const second_actions = [_]mutation.Action{.{ .move = .{
        .source_path = source,
        .destination_path = destination,
        .expected = second_expected,
    } }};
    var second_plan = try mutation.Plan.init(101, &second_actions);
    try second_plan.approve(101);
    try executor.executePlan(&second_plan, 101);
    const changed = try std.Io.Dir.cwd().openFile(
        std.testing.io,
        destination,
        .{ .mode = .read_write },
    );
    defer changed.close(std.testing.io);
    const stat = try changed.stat(std.testing.io);
    try changed.writePositionalAll(std.testing.io, "external", stat.size);
    try std.testing.expectError(error.MutationNeedsReconciliation, executor.undoOperation(3));
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try library.mutation_journal.state(3),
    );
}

test "move recovery restores a rename interrupted before journal commit" {
    const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.bin", .{prefix});
    defer std.testing.allocator.free(source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, "{s}/destination.bin", .{prefix});
    defer std.testing.allocator.free(destination);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/recovery.db",
        .{prefix},
        0,
    );
    defer std.testing.allocator.free(database_path);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.bin",
        .data = "generated source",
    });
    const expected = try file_mutation.identity(std.testing.io, source);
    var library = try LibraryDatabase.open(std.testing.allocator, database_path);
    defer library.close();
    const operation = try library.mutation_journal.prepare(.{
        .plan_id = 102,
        .group_id = 102,
        .action_index = 0,
        .kind = .move,
        .source_path = source,
        .destination_path = destination,
        .expected_size = expected.size_bytes,
        .expected_modified_ns = expected.modified_ns,
    });
    try library.mutation_journal.recordResultIdentity(
        operation,
        .planned,
        expected.size_bytes,
        expected.modified_ns,
    );
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    try std.Io.Dir.cwd().renamePreserve(source, std.Io.Dir.cwd(), destination, std.testing.io);
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
    };
    try executor.recoverOperation(operation);
    try std.testing.expect(try pathExists(std.testing.io, source));
    try std.testing.expect(!(try pathExists(std.testing.io, destination)));
    try std.testing.expectEqual(
        database.MutationState.rolled_back,
        try library.mutation_journal.state(operation),
    );
}

test "failed move rolls back an earlier tag write in the same group" {
    const id3v1 = @import("id3v1.zig");
    const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(prefix);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.mp3", .{prefix});
    defer std.testing.allocator.free(source);
    const move_source = try std.fmt.allocPrint(std.testing.allocator, "{s}/move-source.bin", .{prefix});
    defer std.testing.allocator.free(move_source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, "{s}/collision.mp3", .{prefix});
    defer std.testing.allocator.free(destination);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/group.db",
        .{prefix},
        0,
    );
    defer std.testing.allocator.free(database_path);
    const tag = try id3v1.encode(.{
        .title = "Before group",
        .artist = "Generated",
        .album = "Generated",
        .year = "2026",
        .comment = "Generated",
        .track_number = 1,
        .genre = 13,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.mp3",
        .data = "generated payload" ++ tag,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "collision.mp3",
        .data = "do not replace",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "move-source.bin",
        .data = "generated move source",
    });
    const expected = try file_mutation.identity(std.testing.io, source);
    const move_expected = try file_mutation.identity(std.testing.io, move_source);
    const actions = [_]mutation.Action{
        .{ .write_tags = .{
            .path = source,
            .expected = expected,
            .changes = &.{.{
                .field = .title,
                .before = "Before group",
                .after = "During group",
            }},
        } },
        .{ .move = .{
            .source_path = move_source,
            .destination_path = destination,
            .expected = move_expected,
        } },
    };
    var plan = try mutation.Plan.init(103, &actions);
    try plan.approve(103);
    var library = try LibraryDatabase.open(std.testing.allocator, database_path);
    defer library.close();
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
    };
    try std.testing.expectError(error.DestinationExists, executor.executePlan(&plan, 103));
    try std.testing.expectEqual(mutation.State.failed, plan.state);
    try std.testing.expectEqual(database.MutationState.rolled_back, try library.mutation_journal.state(1));
    try expectTitle(source, "Before group");
}
