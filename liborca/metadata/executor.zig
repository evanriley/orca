const std = @import("std");
const storage = @import("../storage/root.zig");
const database = @import("../database/repository.zig");
const file_mutation = @import("file_mutation.zig");
const JournalLock = @import("journal_lock.zig").JournalLock;
const mutation = @import("mutation.zig");
const vorbis_comment = @import("vorbis_comment.zig");

/// Boundaries at which an execution can lose power. Production callers leave
/// `Executor.fault` null; recovery tests set it so the real executor stops at a
/// real boundary and performs no compensation, exactly as a crash would.
pub const FaultPoint = enum {
    after_journal_prepare,
    after_stage,
    after_stage_journaled,
    after_backup_copy,
    after_source_rename,
    after_move_rename,
    before_journal_commit,
    rollback_after_restore_copy,
    rollback_after_restore,
    undo_after_intent,
    undo_after_operation,
    recovery_after_operation,
};

pub const Fault = struct {
    point: FaultPoint,
    action_index: u32 = 0,
};

pub const PruneSummary = struct {
    backups: u64 = 0,
    bytes: u64 = 0,
};

const CompletedAction = struct {
    id: i64,
    action_index: u32,
};

const PreparedAction = struct {
    id: i64,
    stage_path: ?[]u8 = null,
    backup_path: ?[]u8 = null,

    fn deinit(self: PreparedAction, allocator: std.mem.Allocator) void {
        if (self.stage_path) |value| allocator.free(value);
        if (self.backup_path) |value| allocator.free(value);
    }
};

fn containsOperation(actions: []const CompletedAction, id: i64) bool {
    for (actions) |action| if (action.id == id) return true;
    return false;
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *database.MutationJournalRepository,
    /// Held for as long as this executor exists, so no other holder can recover
    /// or change the journal rows it is working on.
    journal_lock: *const JournalLock,
    /// Where tag writes keep each original, as
    /// `<backup_directory>/<plan>/<action>-<name>`. Null for a Library that has
    /// no database file, which cannot write tags.
    backup_directory: ?[]const u8 = null,
    /// Test-only interruption request; see `FaultPoint`.
    fault: ?Fault = null,
    /// Set once an injected fault has fired, or once a journal row this
    /// executor owns was changed by someone else, so no compensation runs.
    crashed: bool = false,
    failed_action_index: ?u32 = null,

    /// Execute every action as one logical group. A tag write builds a hidden
    /// stage beside the file, keeps a verified copy of the original in the
    /// backup directory, and only then renames the stage onto the file.
    ///
    /// Every action in the group is journaled in `planned` state before any
    /// filesystem work begins. That is what makes the group discoverable after
    /// a crash: as long as one action has not committed, startup recovery can
    /// find the group and unwind the ones that did.
    pub fn executePlan(self: *Executor, plan: *mutation.Plan, group_id: u64) !void {
        self.failed_action_index = null;
        if (group_id == 0) return error.InvalidMutationGroup;
        var writes_tags = false;
        for (plan.actions, 0..) |action, action_index| switch (action) {
            .write_tags => |write| {
                writes_tags = true;
                self.failed_action_index = @intCast(action_index);
                _ = try tagFormat(self.io, write.path) orelse return error.UnsupportedTagWriter;
            },
            .move => {},
        };
        self.failed_action_index = null;
        const plan_backup_directory: ?[]u8 = if (writes_tags) try self.planBackupDirectory(plan.id) else null;
        defer if (plan_backup_directory) |path| self.allocator.free(path);
        if (plan_backup_directory) |path| {
            if (try pathExists(self.io, path)) return error.TagWriteBackupExists;
        }
        var prepared: std.ArrayList(PreparedAction) = .empty;
        defer {
            for (prepared.items) |item| item.deinit(self.allocator);
            prepared.deinit(self.allocator);
        }
        try prepared.ensureTotalCapacity(self.allocator, plan.actions.len);
        var completed: std.ArrayList(CompletedAction) = .empty;
        defer completed.deinit(self.allocator);
        try completed.ensureTotalCapacity(self.allocator, plan.actions.len);
        try plan.beginExecution();
        errdefer if (!self.crashed) {
            var index = completed.items.len;
            while (index > 0) {
                index -= 1;
                const done = completed.items[index];
                self.rollbackOperation(done.id, self.rollbackInterrupt(done.action_index)) catch {};
                if (self.crashed) break;
            }
            if (!self.crashed) {
                var pending = prepared.items.len;
                while (pending > 0) {
                    pending -= 1;
                    const id = prepared.items[pending].id;
                    if (containsOperation(completed.items, id)) continue;
                    self.recoverOperation(id) catch {};
                }
                plan.finish(false) catch {};
            }
        };

        for (plan.actions, 0..) |action, action_index| switch (action) {
            .write_tags => |write| {
                const stage_path = try siblingPath(self.allocator, write.path, "stage", plan.id, action_index);
                errdefer self.allocator.free(stage_path);
                const backup_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{d}-{s}",
                    .{ plan_backup_directory.?, action_index, std.Io.Dir.path.basename(write.path) },
                );
                errdefer self.allocator.free(backup_path);
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
                    .expected_quick_hash = write.expected.quick_hash,
                    .expected_content_hash = write.expected.content_hash,
                });
                prepared.appendAssumeCapacity(.{
                    .id = operation,
                    .stage_path = stage_path,
                    .backup_path = backup_path,
                });
            },
            .move => |move| {
                const operation = try self.journal.prepare(.{
                    .plan_id = plan.id,
                    .group_id = group_id,
                    .action_index = @intCast(action_index),
                    .kind = .move,
                    .source_path = move.source_path,
                    .destination_path = move.destination_path,
                    .expected_size = move.expected.size_bytes,
                    .expected_modified_ns = move.expected.modified_ns,
                    .expected_quick_hash = move.expected.quick_hash,
                    .expected_content_hash = move.expected.content_hash,
                });
                prepared.appendAssumeCapacity(.{ .id = operation });
            },
        };
        try self.interrupt(.after_journal_prepare, 0);

        for (plan.actions, 0..) |action, action_index| switch (action) {
            .write_tags => |write| requireWritableFile(self.io, write.path) catch |err| {
                self.failed_action_index = @intCast(action_index);
                self.transition(prepared.items[action_index].id, .planned, .failed, @errorName(err)) catch {};
                return err;
            },
            .move => {},
        };

        for (plan.actions, 0..) |action, action_index| switch (action) {
            .write_tags => |write| {
                self.failed_action_index = @intCast(action_index);
                const operation = prepared.items[action_index].id;
                const stage_path = prepared.items[action_index].stage_path.?;
                const backup_path = prepared.items[action_index].backup_path.?;
                const format = (try tagFormat(self.io, write.path)).?;
                (switch (format) {
                    .mpeg => file_mutation.stageMpeg(
                        self.allocator,
                        self.io,
                        write.path,
                        stage_path,
                        write.expected,
                        write.changes,
                        write.genres,
                    ),
                    .flac => file_mutation.stageFlac(
                        self.allocator,
                        self.io,
                        write.path,
                        stage_path,
                        write.expected,
                        write.changes,
                        write.genres,
                    ),
                }) catch |err| {
                    self.transition(operation, .planned, .failed, @errorName(err)) catch {};
                    return err;
                };
                try self.interrupt(.after_stage, action_index);
                const staged_identity = try file_mutation.identity(self.io, stage_path);
                try self.recordResultIdentity(operation, .planned, staged_identity);
                try self.transition(operation, .planned, .staged, null);
                try self.interrupt(.after_stage_journaled, action_index);
                const commit_interrupt = self.commitInterrupt(action_index);
                if (commit_interrupt != null) self.crashed = true;
                self.commitWrite(
                    write.path,
                    stage_path,
                    backup_path,
                    write.expected,
                    commit_interrupt,
                ) catch |err| {
                    if (self.crashed) return err;
                    std.Io.Dir.cwd().deleteFile(self.io, stage_path) catch {};
                    self.transition(operation, .staged, .failed, @errorName(err)) catch {};
                    return err;
                };
                completed.appendAssumeCapacity(.{
                    .id = operation,
                    .action_index = @intCast(action_index),
                });
                try self.interrupt(.before_journal_commit, action_index);
                try self.commit(operation, try file_mutation.identity(self.io, write.path));
            },
            .move => |move| {
                self.failed_action_index = @intCast(action_index);
                const operation = prepared.items[action_index].id;
                const current = try file_mutation.identity(self.io, move.source_path);
                if (!current.eql(move.expected) and
                    !try self.groupProducedIdentity(completed.items, move.source_path, current))
                    return error.FileIdentityChanged;
                if (try pathExists(self.io, move.destination_path)) return error.DestinationExists;
                try self.recordResultIdentity(operation, .planned, current);
                try self.transition(operation, .planned, .staged, null);
                try self.interrupt(.after_stage_journaled, action_index);
                file_mutation.commitMove(
                    self.io,
                    move.source_path,
                    move.destination_path,
                ) catch |err| {
                    self.transition(operation, .staged, .failed, @errorName(err)) catch {};
                    return err;
                };
                completed.appendAssumeCapacity(.{
                    .id = operation,
                    .action_index = @intCast(action_index),
                });
                try self.interrupt(.after_move_rename, action_index);
                try self.commit(operation, try file_mutation.identity(self.io, move.destination_path));
            },
        };
        self.failed_action_index = null;
        try plan.finish(true);
    }

    fn planBackupDirectory(self: *const Executor, plan_id: u64) ![]u8 {
        const backup_directory = self.backup_directory orelse return error.NoBackupDirectory;
        return std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ backup_directory, plan_id });
    }

    fn commitWrite(
        self: *Executor,
        source_path: []const u8,
        stage_path: []const u8,
        backup_path: []const u8,
        expected: mutation.FileIdentity,
        commit_interrupt: ?file_mutation.Interrupt,
    ) !void {
        try requireWritableFile(self.io, source_path);
        try file_mutation.createDirectoryDurably(self.io, self.backup_directory.?);
        try file_mutation.createDirectoryDurably(self.io, std.Io.Dir.path.dirname(backup_path).?);
        try file_mutation.commitReplacementInterrupted(
            self.io,
            source_path,
            stage_path,
            backup_path,
            expected,
            commit_interrupt,
        );
    }

    fn faultMatches(self: *const Executor, point: FaultPoint, action_index: usize) bool {
        const fault = self.fault orelse return false;
        return fault.point == point and fault.action_index == action_index;
    }

    /// Stop the executor dead, without compensating, as power loss would.
    fn interrupt(self: *Executor, point: FaultPoint, action_index: usize) !void {
        if (!self.faultMatches(point, action_index)) return;
        self.crashed = true;
        return error.SimulatedPowerLoss;
    }

    fn commitInterrupt(self: *const Executor, action_index: usize) ?file_mutation.Interrupt {
        if (self.faultMatches(.after_backup_copy, action_index)) return .after_backup_copy;
        if (self.faultMatches(.after_source_rename, action_index)) return .after_source_rename;
        return null;
    }

    fn rollbackInterrupt(self: *const Executor, action_index: u32) ?file_mutation.Interrupt {
        if (self.faultMatches(.rollback_after_restore_copy, action_index))
            return .after_restore_copy;
        if (self.faultMatches(.rollback_after_restore, action_index))
            return .after_restore_rename;
        return null;
    }

    fn stopIfStale(self: *Executor, err: anyerror) void {
        if (err == error.StaleMutationOperation) self.crashed = true;
    }

    fn transition(
        self: *Executor,
        operation_id: i64,
        expected: database.MutationState,
        next: database.MutationState,
        message: ?[]const u8,
    ) !void {
        self.journal.transition(operation_id, expected, next, message) catch |err| {
            self.stopIfStale(err);
            return err;
        };
    }

    fn recordResultIdentity(
        self: *Executor,
        operation_id: i64,
        expected: database.MutationState,
        result: mutation.FileIdentity,
    ) !void {
        self.journal.recordResultIdentity(
            operation_id,
            expected,
            result.size_bytes,
            result.modified_ns,
            result.quick_hash,
            result.content_hash orelse return error.MissingContentHash,
        ) catch |err| {
            self.stopIfStale(err);
            return err;
        };
    }

    fn commit(self: *Executor, operation_id: i64, committed: mutation.FileIdentity) !void {
        self.journal.commit(
            operation_id,
            committed.size_bytes,
            committed.modified_ns,
            committed.quick_hash,
            committed.content_hash orelse return error.MissingContentHash,
        ) catch |err| {
            self.stopIfStale(err);
            return err;
        };
    }

    fn groupProducedIdentity(
        self: *Executor,
        actions: []const CompletedAction,
        path: []const u8,
        current: mutation.FileIdentity,
    ) !bool {
        var index = actions.len;
        while (index > 0) {
            index -= 1;
            var operation = try self.journal.get(self.allocator, actions[index].id);
            defer operation.deinit();
            if (operation.kind == .write_tags and
                std.mem.eql(u8, operation.source_path, path) and
                (try resultIdentity(operation)).eql(current))
                return true;
        }
        return false;
    }

    /// Undo refuses to replace a file that changed after the journaled commit,
    /// and refuses to start without the verified original to restore.
    pub fn undoOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state != .committed) return error.MutationOperationNotCommitted;
        if (operation.kind == .write_tags and operation.backup_path == null)
            return error.TagWriteBackupPruned;
        const expected = try resultIdentity(operation);
        const current_path = switch (operation.kind) {
            .write_tags => operation.source_path,
            .move => operation.destination_path orelse return error.MissingMutationDestination,
        };
        if (!try file_mutation.matches(self.io, current_path, expected)) {
            try self.reconcile(operation_id, .committed, "undo target changed externally");
            return error.MutationNeedsReconciliation;
        }
        if (operation.kind == .write_tags and !try backupHoldsOriginal(self.io, operation)) {
            try self.reconcile(operation_id, .committed, "tag write backup is missing or damaged");
            return error.MutationNeedsReconciliation;
        }
        if (operation.kind == .write_tags) try requireWritableFile(self.io, current_path);
        try self.rollbackOperation(operation_id, null);
    }

    /// Undo a logical group in reverse action order, so write-then-move plans
    /// restore the path before restoring the original tagged bytes. A group
    /// whose every operation is committed is validated whole before any file
    /// changes, then its intent to undo is journaled for every operation at
    /// once. A group whose undo was interrupted finishes as recovery would.
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

        var counts: database.GroupStateCounts = .{};
        var backups_present = true;
        for (operations.items) |operation| {
            counts.add(operation.state);
            if (operation.kind == .write_tags and operation.backup_path == null) backups_present = false;
        }
        switch (database.undoAvailability(counts, backups_present)) {
            .fresh => {},
            .interrupted => return self.finishInterruptedUndo(group_id),
            .backups_pruned => return error.TagWriteBackupPruned,
            .already_undone => return error.MutationGroupAlreadyUndone,
            .needs_reconciliation => return error.MutationNeedsReconciliation,
            .not_committed => return error.MutationGroupNotCommitted,
        }
        for (operations.items, 0..) |operation, index| {
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
            if (!try file_mutation.matches(self.io, current_path, try resultIdentity(operation))) {
                try self.reconcile(operation.id, operation.state, "group undo target changed externally");
                return error.MutationNeedsReconciliation;
            }
            if (operation.kind == .move and try pathExists(self.io, operation.source_path)) {
                try self.reconcile(operation.id, operation.state, "group undo destination exists");
                return error.MutationNeedsReconciliation;
            }
            if (operation.kind == .write_tags and !try backupHoldsOriginal(self.io, operation)) {
                try self.reconcile(operation.id, operation.state, "tag write backup is missing or damaged");
                return error.MutationNeedsReconciliation;
            }
            if (operation.kind == .write_tags) try requireWritableFile(self.io, current_path);
        }
        try self.journal.beginUndo(group_id);
        try self.interrupt(.undo_after_intent, 0);
        var reconciled = false;
        for (operations.items) |operation| {
            self.rollbackOperation(operation.id, self.rollbackInterrupt(operation.action_index)) catch |err| switch (err) {
                error.MutationNeedsReconciliation => reconciled = true,
                else => return err,
            };
            try self.interrupt(.undo_after_operation, operation.action_index);
        }
        if (reconciled) return error.MutationNeedsReconciliation;
    }

    fn finishInterruptedUndo(self: *Executor, group_id: u64) !void {
        try self.recoverGroup(group_id);
        const ids = try self.journal.groupOperationIds(self.allocator, group_id);
        defer self.allocator.free(ids);
        for (ids) |id| {
            if (try self.journal.state(id) == .needs_reconciliation) return error.MutationNeedsReconciliation;
        }
    }

    /// Delete the backups of tag-write groups whose every operation committed
    /// at least `older_than_s` seconds ago. A pruned group can no longer be
    /// undone. The file is deleted before its journal path is cleared, so an
    /// interrupted prune finishes on the next run.
    pub fn pruneBackups(self: *Executor, older_than_s: u64) !PruneSummary {
        var summary: PruneSummary = .{};
        while (true) {
            const page = try self.journal.prunableBackups(self.allocator, older_than_s);
            defer page.deinit();
            if (page.items.len == 0) return summary;
            for (page.items) |backup| {
                summary.bytes += try deleteCountingBytes(self.io, backup.backup_path);
                try self.journal.clearBackupPath(backup.operation_id);
                try self.removeEmptyBackupDirectories(backup.backup_path);
                summary.backups += 1;
            }
        }
    }

    /// Drive a group whose execution or undo was interrupted to a terminal
    /// state, in reverse action order. Its committed operations become
    /// `undoing` in one transaction first, so a crash part-way through leaves
    /// the group discoverable rather than half unwound.
    pub fn recoverGroup(self: *Executor, group_id: u64) !void {
        _ = try self.journal.undoCommitted(group_id);
        const ids = try self.journal.groupOperationIds(self.allocator, group_id);
        defer self.allocator.free(ids);
        for (ids) |id| {
            var operation = try self.journal.get(self.allocator, id);
            defer operation.deinit();
            self.recoverLoaded(operation) catch |err| switch (err) {
                error.MutationNeedsReconciliation => {},
                else => return err,
            };
            try self.interrupt(.recovery_after_operation, operation.action_index);
        }
    }

    /// Resolve a nonterminal journal entry after interruption. Recovery always
    /// prefers the original bytes and never assumes a staged replacement won,
    /// and never reports `rolled_back` unless the original file is provably
    /// back in place. A committed operation is refused: only an undo of its
    /// whole group may unwind it.
    pub fn recoverOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        return self.recoverLoaded(operation);
    }

    fn recoverLoaded(self: *Executor, operation: database.MutationOperation) !void {
        switch (operation.state) {
            .rolled_back, .needs_reconciliation => return,
            .committed => return error.MutationOperationNotRecoverable,
            .planned, .staged, .failed, .undoing => {},
        }
        // A record that does not name the paths its own recovery needs can
        // never converge on its own, but it must not keep the Library shut
        // forever either: reconciliation is the terminal state for it.
        if (operation.kind == .move) {
            if (operation.destination_path == null) {
                try self.reconcile(
                    operation.id,
                    operation.state,
                    "move record has no journaled destination path",
                );
                return error.MutationNeedsReconciliation;
            }
            return self.recoverMove(operation);
        }
        if (operation.stage_path == null or operation.backup_path == null) {
            try self.reconcile(
                operation.id,
                operation.state,
                "tag write record has no journaled stage or backup path",
            );
            return error.MutationNeedsReconciliation;
        }
        return self.recoverWriteTags(operation);
    }

    fn recoverMove(self: *Executor, operation: database.MutationOperation) !void {
        const destination = operation.destination_path orelse
            return error.MissingMutationDestination;
        if (try pathExists(self.io, destination)) {
            if (try pathExists(self.io, operation.source_path)) {
                try self.reconcile(
                    operation.id,
                    operation.state,
                    "move source and destination both exist",
                );
                return error.MutationNeedsReconciliation;
            }
            const journaled = resultIdentity(operation) catch {
                try self.reconcile(
                    operation.id,
                    operation.state,
                    "move destination exists without a journaled identity",
                );
                return error.MutationNeedsReconciliation;
            };
            if (!try file_mutation.matches(self.io, destination, journaled)) {
                try self.reconcile(
                    operation.id,
                    operation.state,
                    "move destination changed externally",
                );
                return error.MutationNeedsReconciliation;
            }
            try file_mutation.commitMove(self.io, destination, operation.source_path);
        }
        // A move only ever relocated a path, so restoring the path is the whole
        // undo. Whether the bytes still match what the plan expected is the
        // business of whichever action changed them — possibly an earlier action
        // of this same group, recovered after this one.
        if (!try pathExists(self.io, operation.source_path)) {
            try self.reconcile(
                operation.id,
                operation.state,
                "neither the move source nor its destination is present",
            );
            return error.MutationNeedsReconciliation;
        }
        return self.finishRecoveryState(operation.id, operation.state);
    }

    /// Decided by identity alone, so a record written with the backup beside
    /// the music converges the same way as one with it in the backup directory.
    fn recoverWriteTags(self: *Executor, operation: database.MutationOperation) !void {
        const stage_path = operation.stage_path orelse return error.MissingMutationStagePath;
        const backup_path = operation.backup_path orelse return error.MissingMutationBackupPath;
        const original = expectedIdentity(operation) catch null;
        const staged = resultIdentity(operation) catch null;
        const restore_path = try siblingPath(
            self.allocator,
            operation.source_path,
            "restore",
            operation.plan_id,
            operation.action_index,
        );
        defer self.allocator.free(restore_path);
        const legacy_displaced_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.recovery-displaced",
            .{stage_path},
        );
        defer self.allocator.free(legacy_displaced_path);
        const temporaries = [_][]const u8{ stage_path, restore_path, legacy_displaced_path };

        if (original) |identity| {
            if (try matchesIfPresent(self.io, operation.source_path, identity) orelse false) {
                for (temporaries) |path| try file_mutation.deleteIfPresent(self.io, path);
                try self.discardBackup(backup_path);
                return self.finishRecoveryState(operation.id, operation.state);
            }
        }
        // Nothing was ever staged, so no Orca write can be in effect: removing
        // a torn stage is the whole recovery, and claiming anything about the
        // source would be a claim about somebody else's edit.
        const replacement = staged orelse {
            for (temporaries) |path| try file_mutation.deleteIfPresent(self.io, path);
            return self.finishRecoveryState(operation.id, operation.state);
        };
        const in_place = try matchesIfPresent(self.io, operation.source_path, replacement) orelse {
            // A missing folder is most likely an unmounted drive: a terminal
            // state now would stop recovery for good once it is back.
            if (!try directoryExists(self.io, std.Io.Dir.path.dirname(operation.source_path) orelse "."))
                return error.TagTargetUnavailable;
            try self.reconcile(operation.id, operation.state, "the tag target is missing");
            return error.MutationNeedsReconciliation;
        };
        if (!in_place) {
            try self.reconcile(operation.id, operation.state, "tag target changed externally");
            return error.MutationNeedsReconciliation;
        }
        if (!try backupHoldsOriginal(self.io, operation)) {
            try self.reconcile(
                operation.id,
                operation.state,
                "the staged replacement is in place and its backup is missing or damaged",
            );
            return error.MutationNeedsReconciliation;
        }
        try file_mutation.restoreFromBackup(
            self.io,
            operation.source_path,
            backup_path,
            restore_path,
            original.?,
            replacement,
        );
        for (temporaries) |path| try file_mutation.deleteIfPresent(self.io, path);
        try self.discardBackup(backup_path);
        return self.finishRecoveryState(operation.id, operation.state);
    }

    fn finishRecoveryState(
        self: *Executor,
        operation_id: i64,
        state: database.MutationState,
    ) !void {
        switch (state) {
            .planned => {
                try self.transition(operation_id, .planned, .failed, database.recovered_message);
                try self.transition(operation_id, .failed, .rolled_back, database.recovered_message);
            },
            .staged => try self.transition(
                operation_id,
                .staged,
                .rolled_back,
                database.recovered_message,
            ),
            .failed => self.journal.rollBackFailed(operation_id) catch |err| {
                self.stopIfStale(err);
                return err;
            },
            .undoing => try self.transition(
                operation_id,
                .undoing,
                .rolled_back,
                database.recovered_message,
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
        try self.transition(operation_id, state, .needs_reconciliation, message);
    }

    /// Restore one operation's before-state. A committed operation becomes
    /// `undoing` first; a staged one is a write the same execution is
    /// compensating. The backup goes before the journal says `rolled_back`,
    /// so a crash between the two leaves an operation recovery still finishes.
    fn rollbackOperation(
        self: *Executor,
        operation_id: i64,
        rollback_interrupt: ?file_mutation.Interrupt,
    ) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        const state: database.MutationState = switch (operation.state) {
            .committed => undoing: {
                try self.transition(operation_id, .committed, .undoing, null);
                break :undoing .undoing;
            },
            .staged, .undoing => operation.state,
            .planned, .failed, .rolled_back, .needs_reconciliation => return error.MutationOperationNotRecoverable,
        };
        if (operation.kind == .move) {
            const destination = operation.destination_path orelse
                return error.MissingMutationDestination;
            if (try pathExists(self.io, operation.source_path)) {
                try self.reconcile(operation_id, state, "move source already exists");
                return error.MutationNeedsReconciliation;
            }
            try file_mutation.commitMove(self.io, destination, operation.source_path);
            try self.transition(operation_id, state, .rolled_back, null);
            return;
        }
        const backup_path = operation.backup_path orelse return error.TagWriteBackupPruned;
        const restore_path = try siblingPath(
            self.allocator,
            operation.source_path,
            "restore",
            operation.plan_id,
            operation.action_index,
        );
        defer self.allocator.free(restore_path);
        if (rollback_interrupt != null) self.crashed = true;
        try file_mutation.restoreFromBackupInterrupted(
            self.io,
            operation.source_path,
            backup_path,
            restore_path,
            try expectedIdentity(operation),
            try resultIdentity(operation),
            rollback_interrupt,
        );
        try self.discardBackup(backup_path);
        try self.transition(operation_id, state, .rolled_back, null);
    }

    fn discardBackup(self: *Executor, backup_path: []const u8) !void {
        try file_mutation.deleteIfPresent(self.io, backup_path);
        try self.removeEmptyBackupDirectories(backup_path);
    }

    /// Only directories inside `backup_directory` are removed: a backup from
    /// before it existed sits beside the music, whose folder is not Orca's.
    fn removeEmptyBackupDirectories(self: *Executor, backup_path: []const u8) !void {
        const backup_directory = self.backup_directory orelse return;
        const plan_directory = std.Io.Dir.path.dirname(backup_path) orelse return;
        const parent = std.Io.Dir.path.dirname(plan_directory) orelse return;
        if (!std.mem.eql(u8, parent, backup_directory)) return;
        try deleteDirectoryIfEmpty(self.io, plan_directory);
        try deleteDirectoryIfEmpty(self.io, backup_directory);
    }
};

/// The identity a completed operation left behind, as the journal recorded it.
///
/// Full identity, not size and mtime: an editor that rewrites a file in place
/// and restores its timestamp would otherwise pass an undo validity check
/// against bytes nobody agreed to.
fn resultIdentity(operation: database.MutationOperation) !mutation.FileIdentity {
    return .{
        .size_bytes = operation.committed_size orelse return error.MissingCommittedIdentity,
        .modified_ns = operation.committed_modified_ns orelse
            return error.MissingCommittedIdentity,
        .quick_hash = operation.committed_quick_hash orelse
            return error.MissingCommittedIdentity,
        .content_hash = operation.committed_content_hash,
    };
}

fn expectedIdentity(operation: database.MutationOperation) !mutation.FileIdentity {
    return .{
        .size_bytes = operation.expected_size,
        .modified_ns = operation.expected_modified_ns,
        .quick_hash = operation.expected_quick_hash orelse return error.MissingExpectedIdentity,
        .content_hash = operation.expected_content_hash,
    };
}

fn backupHoldsOriginal(io: std.Io, operation: database.MutationOperation) !bool {
    const backup_path = operation.backup_path orelse return false;
    const original = expectedIdentity(operation) catch return false;
    return try matchesIfPresent(io, backup_path, original) orelse false;
}

fn siblingPath(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    purpose: []const u8,
    plan_id: u64,
    action_index: usize,
) ![]u8 {
    const name = std.Io.Dir.path.basename(source_path);
    return std.fmt.allocPrint(allocator, "{s}.{s}.orca-{s}-{d}-{d}", .{
        source_path[0 .. source_path.len - name.len],
        name,
        purpose,
        plan_id,
        action_index,
    });
}

/// Whether a file name is one of the temporaries or backups a tag write puts
/// beside the music, in this layout or the one before it, which a scan must
/// never ingest as music.
pub fn isOrcaTemporaryName(name: []const u8) bool {
    if (std.mem.indexOf(u8, name, ".orca-stage-") != null) return true;
    if (std.mem.indexOf(u8, name, ".orca-backup-") != null) return true;
    if (std.mem.endsWith(u8, name, ".recovery-displaced")) return true;
    return std.mem.startsWith(u8, name, ".") and std.mem.indexOf(u8, name, ".orca-restore-") != null;
}

/// Fails with `error.FileReadOnly` when the file at `path` has no write
/// permission bit, or the process may not write it. Orca never replaces such a
/// file, even though its folder would allow the rename.
pub fn requireWritableFile(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.permissions.readOnly()) return error.FileReadOnly;
    std.Io.Dir.cwd().access(io, path, .{ .write = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.FileReadOnly,
        else => return err,
    };
}

/// Whether Orca can write tags into the file at `path`.
pub fn canWriteTags(io: std.Io, path: []const u8) !bool {
    return try tagFormat(io, path) != null;
}

pub const TagFormat = enum { mpeg, flac };

/// The tag block a write replaces in a file.
pub const TagBlock = enum {
    /// FLAC's Vorbis comment block.
    vorbis_comment,
    /// An ID3v2 tag at the start of an MP3 or ADTS AAC file.
    id3v2,

    pub fn of(format: TagFormat) TagBlock {
        return switch (format) {
            .flac => .vorbis_comment,
            .mpeg => .id3v2,
        };
    }

    /// The Vorbis comment key a field is written under, `GENRE` for null,
    /// or null for ID3v2, whose frames depend on the tag's version.
    pub fn key(self: TagBlock, field: ?mutation.Field) ?[]const u8 {
        return switch (self) {
            .vorbis_comment => if (field) |value| vorbis_comment.fieldKey(value) else "GENRE",
            .id3v2 => null,
        };
    }
};

/// Which writer a file takes, decided by its bytes as every reader decides,
/// never by its name. Null for a format Orca cannot write tags into yet.
pub fn tagFormat(io: std.Io, path: []const u8) !?TagFormat {
    var local = try storage.LocalFileSource.open(io, path);
    defer local.close();
    const detected = try storage.format.detect(local.readable()) orelse return null;
    if (detected.payload_offset != 0) return null;
    return switch (detected.format) {
        .flac => .flac,
        .mp3, .aac => .mpeg,
        else => null,
    };
}

fn deleteCountingBytes(io: std.Io, path: []const u8) !u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    const stat = file.stat(io);
    file.close(io);
    const size = (try stat).size;
    try file_mutation.deleteIfPresent(io, path);
    return size;
}

fn deleteDirectoryIfEmpty(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteDir(io, path) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound => {},
        else => return err,
    };
}

fn matchesIfPresent(io: std.Io, path: []const u8, expected: mutation.FileIdentity) !?bool {
    return file_mutation.matches(io, path, expected) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn directoryExists(io: std.Io, path: []const u8) !bool {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    directory.close(io);
    return true;
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
        .data = "\xff\xfb\x90\x64generated payload" ++ tag,
    });
    const expected = try file_mutation.identity(std.testing.io, source_path);
    const actions = [_]mutation.Action{.{ .write_tags = .{
        .path = source_path,
        .expected = expected,
        .changes = &.{.{ .field = .title, .before = "Old title", .after = "New title" }},
    } }};
    var plan = try mutation.Plan.init(std.testing.allocator, 44, &actions);
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, database_path);
    defer library.close();
    var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
    defer lock.release(std.testing.io);
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
        .journal_lock = &lock,
        .backup_directory = library.backup_directory,
    };
    try std.testing.expectError(error.MutationPlanNotApproved, executor.executePlan(&plan, 8));
    defer plan.deinit();
    try plan.approve(plan.approval());
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
    var second_plan = try mutation.Plan.init(std.testing.allocator, 45, &second_actions);
    defer second_plan.deinit();
    try second_plan.approve(second_plan.approval());
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
        .data = "\xff\xfb\x90\x64generated payload" ++ tag,
    });
    const expected = try file_mutation.identity(std.testing.io, source);
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, database_path);
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
        .expected_quick_hash = expected.quick_hash,
        .expected_content_hash = expected.content_hash,
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, source, stage, expected, &.{.{
        .field = .title,
        .before = "Before crash",
        .after = "Interrupted",
    }}, null);
    const staged_identity = try file_mutation.identity(std.testing.io, stage);
    try library.mutation_journal.recordResultIdentity(
        operation,
        .planned,
        staged_identity.size_bytes,
        staged_identity.modified_ns,
        staged_identity.quick_hash,
        staged_identity.content_hash.?,
    );
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    try file_mutation.commitReplacement(std.testing.io, source, stage, backup, expected);

    var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
    defer lock.release(std.testing.io);
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
        .journal_lock = &lock,
        .backup_directory = library.backup_directory,
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
        .expected_quick_hash = expected_again.quick_hash,
        .expected_content_hash = expected_again.content_hash,
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, source, stage, expected_again, &.{.{
        .field = .title,
        .before = "Before crash",
        .after = "Staged only",
    }}, null);
    const staged_only_identity = try file_mutation.identity(std.testing.io, stage);
    try library.mutation_journal.recordResultIdentity(
        staged_only,
        .planned,
        staged_only_identity.size_bytes,
        staged_only_identity.modified_ns,
        staged_only_identity.quick_hash,
        staged_only_identity.content_hash.?,
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
        .expected_quick_hash = expected_again.quick_hash,
        .expected_content_hash = expected_again.content_hash,
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
        .expected_quick_hash = expected_again.quick_hash,
        .expected_content_hash = expected_again.content_hash,
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, source, stage, expected_again, &.{.{
        .field = .title,
        .before = "Before crash",
        .after = "Interrupted again",
    }}, null);
    const changed_stage_identity = try file_mutation.identity(std.testing.io, stage);
    try library.mutation_journal.recordResultIdentity(
        changed_during_recovery,
        .planned,
        changed_stage_identity.size_bytes,
        changed_stage_identity.modified_ns,
        changed_stage_identity.quick_hash,
        changed_stage_identity.content_hash.?,
    );
    try library.mutation_journal.transition(changed_during_recovery, .planned, .staged, null);
    try file_mutation.commitReplacement(std.testing.io, source, stage, backup, expected_again);
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
        .data = "\xff\xfb\x90\x64generated payload" ++ tag,
    });
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, database_path);
    defer library.close();
    var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
    defer lock.release(std.testing.io);
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
        .journal_lock = &lock,
        .backup_directory = library.backup_directory,
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
    var plan = try mutation.Plan.init(std.testing.allocator, 100, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());
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
    var second_plan = try mutation.Plan.init(std.testing.allocator, 101, &second_actions);
    defer second_plan.deinit();
    try second_plan.approve(second_plan.approval());
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
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, database_path);
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
        .expected_quick_hash = expected.quick_hash,
        .expected_content_hash = expected.content_hash,
    });
    try library.mutation_journal.recordResultIdentity(
        operation,
        .planned,
        expected.size_bytes,
        expected.modified_ns,
        expected.quick_hash,
        expected.content_hash.?,
    );
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    try std.Io.Dir.cwd().renamePreserve(source, std.Io.Dir.cwd(), destination, std.testing.io);
    var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
    defer lock.release(std.testing.io);
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
        .journal_lock = &lock,
        .backup_directory = library.backup_directory,
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
        .data = "\xff\xfb\x90\x64generated payload" ++ tag,
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
    var plan = try mutation.Plan.init(std.testing.allocator, 103, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, database_path);
    defer library.close();
    var lock = try JournalLock.acquireForMutation(std.testing.io, library.journal_lock_path);
    defer lock.release(std.testing.io);
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
        .journal_lock = &lock,
        .backup_directory = library.backup_directory,
    };
    try std.testing.expectError(error.DestinationExists, executor.executePlan(&plan, 103));
    try std.testing.expectEqual(mutation.State.failed, plan.state);
    try std.testing.expectEqual(database.MutationState.rolled_back, try library.mutation_journal.state(1));
    try expectTitle(source, "Before group");
}

const WriteFixture = struct {
    music: std.testing.TmpDir,
    data: std.testing.TmpDir,
    source: []u8,
    second: []u8,
    library: @import("../database/library.zig").LibraryDatabase,
    original: mutation.FileIdentity,
    second_original: mutation.FileIdentity,

    fn init(database_name: ?[:0]const u8) !WriteFixture {
        const id3v1 = @import("id3v1.zig");
        const LibraryDatabase = @import("../database/library.zig").LibraryDatabase;
        const allocator = std.testing.allocator;
        var music = std.testing.tmpDir(.{ .iterate = true });
        errdefer music.cleanup();
        var data = std.testing.tmpDir(.{});
        errdefer data.cleanup();
        for ([_][]const u8{ "source.mp3", "second.mp3" }, 1..) |name, track| {
            try music.dir.writeFile(std.testing.io, .{
                .sub_path = name,
                .data = "\xff\xfb\x90\x64generated payload" ++ try id3v1.encode(.{
                    .title = "Before write",
                    .artist = "Generated",
                    .album = "Generated",
                    .year = "2026",
                    .comment = "Generated",
                    .track_number = @as(u8, @intCast(track)),
                    .genre = 13,
                }),
            });
        }
        const source = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.mp3", .{music.sub_path});
        errdefer allocator.free(source);
        const second = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/second.mp3", .{music.sub_path});
        errdefer allocator.free(second);
        const database_path = if (database_name) |name|
            try allocator.dupeSentinel(u8, name, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/library.db", .{data.sub_path}, 0);
        defer allocator.free(database_path);
        return .{
            .music = music,
            .data = data,
            .source = source,
            .second = second,
            .original = try file_mutation.identity(std.testing.io, source),
            .second_original = try file_mutation.identity(std.testing.io, second),
            .library = try LibraryDatabase.open(allocator, std.testing.io, database_path),
        };
    }

    fn deinit(self: *WriteFixture) void {
        self.library.close();
        std.testing.allocator.free(self.source);
        std.testing.allocator.free(self.second);
        self.data.cleanup();
        self.music.cleanup();
    }

    fn acquireLock(self: *WriteFixture) !JournalLock {
        return JournalLock.acquireForMutation(std.testing.io, self.library.journal_lock_path);
    }

    /// The lock as another process would hold it: through its own open file
    /// description.
    fn holdForeignLock(self: *WriteFixture) !JournalLock {
        return (try JournalLock.tryAcquire(std.testing.io, self.library.journal_lock_path.?)).?;
    }

    fn executorWith(self: *WriteFixture, lock: *const JournalLock) Executor {
        return .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .journal = &self.library.mutation_journal,
            .journal_lock = lock,
            .backup_directory = self.library.backup_directory,
        };
    }

    fn write(self: *WriteFixture, plan_id: u64) !void {
        const actions = [_]mutation.Action{.{ .write_tags = .{
            .path = self.source,
            .expected = self.original,
            .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
        } }};
        return self.execute(plan_id, &actions);
    }

    fn writeBoth(self: *WriteFixture, plan_id: u64) !void {
        const actions = [_]mutation.Action{
            .{ .write_tags = .{
                .path = self.source,
                .expected = self.original,
                .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
            } },
            .{ .write_tags = .{
                .path = self.second,
                .expected = self.second_original,
                .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
            } },
        };
        return self.execute(plan_id, &actions);
    }

    fn execute(self: *WriteFixture, plan_id: u64, actions: []const mutation.Action) !void {
        var plan = try mutation.Plan.init(std.testing.allocator, plan_id, actions);
        defer plan.deinit();
        try plan.approve(plan.approval());
        var lock = try self.acquireLock();
        defer lock.release(std.testing.io);
        var executor = self.executorWith(&lock);
        try executor.executePlan(&plan, plan_id);
    }

    fn undo(self: *WriteFixture, group_id: u64) !void {
        var lock = try self.acquireLock();
        defer lock.release(std.testing.io);
        var executor = self.executorWith(&lock);
        try executor.undoGroup(group_id);
    }

    fn prune(self: *WriteFixture, older_than_s: u64) !PruneSummary {
        var lock = try self.acquireLock();
        defer lock.release(std.testing.io);
        var executor = self.executorWith(&lock);
        return executor.pruneBackups(older_than_s);
    }

    fn backupPath(self: *WriteFixture, plan_id: u64) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "{s}/{d}/0-source.mp3", .{ self.library.backup_directory.?, plan_id });
    }

    fn current(self: *WriteFixture) !mutation.FileIdentity {
        return file_mutation.identity(std.testing.io, self.source);
    }

    fn currentSecond(self: *WriteFixture) !mutation.FileIdentity {
        return file_mutation.identity(std.testing.io, self.second);
    }

    fn lengthenSource(self: *WriteFixture) !void {
        try file_mutation.writeLongMpeg(self.source, "Before write");
        self.original = try self.current();
    }

    fn forgeMiddleEdit(self: *WriteFixture) !mutation.FileIdentity {
        const before = try self.current();
        try file_mutation.forgeInPlaceEdit(self.source, before.size_bytes / 2, "EDITED");
        const edited = try self.current();
        try std.testing.expectEqualSlices(u8, &before.quick_hash, &edited.quick_hash);
        return edited;
    }

    fn journaledError(self: *WriteFixture, operation_id: i64) ![]u8 {
        var statement = try self.library.database.prepare("SELECT error FROM mutation_operations WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        return std.testing.allocator.dupe(u8, statement.columnText(0));
    }

    fn expectJournaledError(self: *WriteFixture, operation_id: i64, expected: []const u8) !void {
        const recorded = try self.journaledError(operation_id);
        defer std.testing.allocator.free(recorded);
        try std.testing.expectEqualStrings(expected, recorded);
    }

    fn setMode(self: *WriteFixture, name: []const u8, mode: std.posix.mode_t) !void {
        try self.music.dir.setFilePermissions(std.testing.io, name, .fromMode(mode), .{});
    }

    fn expectMode(path: []const u8, expected: std.posix.mode_t) !void {
        const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
        try std.testing.expectEqual(expected, stat.permissions.toMode() & 0o7777);
    }

    fn expectMusicFolderUntouched(self: *WriteFixture) !void {
        var iterator = self.music.dir.iterate();
        var count: usize = 0;
        while (try iterator.next(std.testing.io)) |entry| {
            count += 1;
            try std.testing.expect(std.mem.eql(u8, entry.name, "source.mp3") or std.mem.eql(u8, entry.name, "second.mp3"));
        }
        try std.testing.expectEqual(@as(usize, 2), count);
    }
};

test "a tag write keeps the original in the backup directory and nothing beside the file" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);

    try expectTitle(fixture.source, "After write");
    try fixture.expectMusicFolderUntouched();
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    try std.testing.expect(std.Io.Dir.path.isAbsolute(backup));
    try std.testing.expect(fixture.original.eql(try file_mutation.identity(std.testing.io, backup)));
    var operation = try fixture.library.mutation_journal.get(std.testing.allocator, 1);
    defer operation.deinit();
    try std.testing.expectEqualStrings(backup, operation.backup_path.?);
}

test "undo restores the original identity and removes the emptied backup directory" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);
    try fixture.undo(7);

    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try fixture.expectMusicFolderUntouched();
    try std.testing.expect(!try pathExists(std.testing.io, fixture.library.backup_directory.?));
}

test "undo refuses a pruned write and changes nothing" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);
    const written = try fixture.current();

    const pruned = try fixture.prune(0);
    try std.testing.expectEqual(@as(u64, 1), pruned.backups);
    try std.testing.expectEqual(fixture.original.size_bytes, pruned.bytes);
    try std.testing.expect(!try pathExists(std.testing.io, fixture.library.backup_directory.?));
    try std.testing.expectEqual(@as(u64, 0), (try fixture.prune(0)).backups);

    try std.testing.expectError(error.TagWriteBackupPruned, fixture.undo(7));
    try std.testing.expect(written.eql(try fixture.current()));
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(1));
}

test "undo reconciles a write whose backup is missing, changes nothing, and is never pruned" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);
    const written = try fixture.current();
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, backup);

    try std.testing.expectError(error.MutationNeedsReconciliation, fixture.undo(7));
    try std.testing.expect(written.eql(try fixture.current()));
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try fixture.library.mutation_journal.state(1),
    );
    try std.testing.expectEqual(@as(u64, 0), (try fixture.prune(0)).backups);
    var operation = try fixture.library.mutation_journal.get(std.testing.allocator, 1);
    defer operation.deinit();
    try std.testing.expect(operation.backup_path != null);
}

test "pruning keeps the backups of writes younger than the cutoff" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);

    try std.testing.expectEqual(@as(u64, 0), (try fixture.prune(3600)).backups);
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    try std.testing.expect(try pathExists(std.testing.io, backup));
}

test "a Library with no database file refuses a tag write before touching the file" {
    var fixture = try WriteFixture.init("file:orca-executor-no-backups?mode=memory&cache=shared");
    defer fixture.deinit();
    try std.testing.expect(fixture.library.backup_directory == null);
    try std.testing.expect(fixture.library.journal_lock_path == null);

    try std.testing.expectError(error.NoBackupDirectory, fixture.write(7));
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try fixture.expectMusicFolderUntouched();
    try std.testing.expectEqual(@as(u64, 1), try fixture.library.mutation_journal.nextGroupId());
}

test "a tag write refuses a plan whose backup directory already exists" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    const plan_directory = try std.fmt.allocPrint(std.testing.allocator, "{s}/7", .{fixture.library.backup_directory.?});
    defer std.testing.allocator.free(plan_directory);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, plan_directory);

    try std.testing.expectError(error.TagWriteBackupExists, fixture.write(7));
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try std.testing.expectEqual(@as(u64, 1), try fixture.library.mutation_journal.nextGroupId());
}

fn commitLegacyWrite(fixture: *WriteFixture, plan_id: u64) ![]u8 {
    const allocator = std.testing.allocator;
    const stage = try std.fmt.allocPrint(allocator, "{s}.orca-stage-{d}-0", .{ fixture.source, plan_id });
    defer allocator.free(stage);
    const backup = try std.fmt.allocPrint(allocator, "{s}.orca-backup-{d}-0", .{ fixture.source, plan_id });
    errdefer allocator.free(backup);
    const journal = &fixture.library.mutation_journal;
    const operation = try journal.prepare(.{
        .plan_id = plan_id,
        .group_id = plan_id,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = fixture.source,
        .stage_path = stage,
        .backup_path = backup,
        .expected_size = fixture.original.size_bytes,
        .expected_modified_ns = fixture.original.modified_ns,
        .expected_quick_hash = fixture.original.quick_hash,
        .expected_content_hash = fixture.original.content_hash,
    });
    try file_mutation.stageMpeg(allocator, std.testing.io, fixture.source, stage, fixture.original, &.{
        .{ .field = .title, .before = "Before write", .after = "After write" },
    }, null);
    const staged = try file_mutation.identity(std.testing.io, stage);
    try journal.recordResultIdentity(operation, .planned, staged.size_bytes, staged.modified_ns, staged.quick_hash, staged.content_hash.?);
    try journal.transition(operation, .planned, .staged, null);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(fixture.source, cwd, backup, std.testing.io);
    try cwd.rename(stage, cwd, fixture.source, std.testing.io);
    try journal.commit(operation, staged.size_bytes, staged.modified_ns, staged.quick_hash, staged.content_hash.?);
    return backup;
}

test "undo restores a write whose backup sits beside the music and deletes that backup" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    const backup = try commitLegacyWrite(&fixture, 5);
    defer std.testing.allocator.free(backup);

    try fixture.undo(5);
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try std.testing.expect(!try pathExists(std.testing.io, backup));
    try fixture.expectMusicFolderUntouched();
}

test "pruning deletes a backup beside the music from before the backup directory" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    const backup = try commitLegacyWrite(&fixture, 5);
    defer std.testing.allocator.free(backup);

    const pruned = try fixture.prune(0);
    try std.testing.expectEqual(@as(u64, 1), pruned.backups);
    try std.testing.expectEqual(fixture.original.size_bytes, pruned.bytes);
    try fixture.expectMusicFolderUntouched();
    try std.testing.expectError(error.TagWriteBackupPruned, fixture.undo(5));
}

test "a tag write refuses to start while another process holds the mutation lock and journals nothing" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    var foreign = try fixture.holdForeignLock();

    try std.testing.expectError(error.MutationInProgress, fixture.write(7));
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try fixture.expectMusicFolderUntouched();
    try std.testing.expectEqual(@as(u64, 1), try fixture.library.mutation_journal.nextGroupId());

    foreign.release(std.testing.io);
    try fixture.write(7);
    try expectTitle(fixture.source, "After write");
}

test "undoing a group refuses while another process holds the mutation lock and changes nothing" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);
    const written = try fixture.current();
    var foreign = try fixture.holdForeignLock();

    try std.testing.expectError(error.MutationInProgress, fixture.undo(7));
    try std.testing.expect(written.eql(try fixture.current()));
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(1));

    foreign.release(std.testing.io);
    try fixture.undo(7);
    try std.testing.expect(fixture.original.eql(try fixture.current()));
}

test "pruning backups refuses while another process holds the mutation lock" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.write(7);
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    var foreign = try fixture.holdForeignLock();
    defer foreign.release(std.testing.io);

    try std.testing.expectError(error.MutationInProgress, fixture.prune(0));
    try std.testing.expect(fixture.original.eql(try file_mutation.identity(std.testing.io, backup)));
}

test "an undo that fails on one file keeps its intent and finishes on the next attempt" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.writeBoth(7);
    try fixture.music.dir.createDir(std.testing.io, ".source.mp3.orca-restore-7-0", .default_dir);

    if (fixture.undo(7)) |_| return error.UndoIgnoredItsObstacle else |_| {}
    try std.testing.expectEqual(database.MutationState.undoing, try fixture.library.mutation_journal.state(1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(2));
    try expectTitle(fixture.source, "After write");
    try std.testing.expect(fixture.second_original.eql(try fixture.currentSecond()));

    try fixture.music.dir.deleteDir(std.testing.io, ".source.mp3.orca-restore-7-0");
    try fixture.undo(7);
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try std.testing.expect(fixture.second_original.eql(try fixture.currentSecond()));
    try fixture.expectMusicFolderUntouched();
    try std.testing.expect(!try pathExists(std.testing.io, fixture.library.backup_directory.?));
}

test "undoing a group that was already undone reports it rather than refusing it as not committed" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.writeBoth(7);
    try fixture.undo(7);

    try std.testing.expectError(error.MutationGroupAlreadyUndone, fixture.undo(7));
    try std.testing.expect(fixture.original.eql(try fixture.current()));
}

test "undoing a group with a reconciled operation reports reconciliation, not an uncommitted group" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.writeBoth(7);
    const changed = try std.Io.Dir.cwd().openFile(std.testing.io, fixture.second, .{ .mode = .read_write });
    const stat = try changed.stat(std.testing.io);
    try changed.writePositionalAll(std.testing.io, "external", stat.size);
    changed.close(std.testing.io);

    try std.testing.expectError(error.MutationNeedsReconciliation, fixture.undo(7));
    try std.testing.expectError(error.MutationNeedsReconciliation, fixture.undo(7));
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(1));
    try std.testing.expectEqual(database.MutationState.needs_reconciliation, try fixture.library.mutation_journal.state(2));
    try expectTitle(fixture.source, "After write");
}

test "backups of a group being undone are never pruned" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.writeBoth(7);
    {
        var lock = try fixture.acquireLock();
        defer lock.release(std.testing.io);
        var executor = fixture.executorWith(&lock);
        executor.fault = .{ .point = .undo_after_operation, .action_index = 1 };
        try std.testing.expectError(error.SimulatedPowerLoss, executor.undoGroup(7));
    }
    try std.testing.expectEqual(database.MutationState.undoing, try fixture.library.mutation_journal.state(1));
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(2));

    try std.testing.expectEqual(@as(u64, 0), (try fixture.prune(0)).backups);
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    try std.testing.expect(fixture.original.eql(try file_mutation.identity(std.testing.io, backup)));

    try fixture.undo(7);
    try std.testing.expect(fixture.original.eql(try fixture.current()));
}

test "an executor stops without compensating when its journal row was changed by someone else" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.library.database.exec(
        \\CREATE TEMP TRIGGER recovered_elsewhere AFTER UPDATE OF state ON mutation_operations
        \\WHEN NEW.state = 2 AND NEW.action_index = 0
        \\BEGIN
        \\    UPDATE mutation_operations SET state = 3, error = 'recovered'
        \\    WHERE group_id = NEW.group_id AND action_index = 1;
        \\END;
    );
    const actions = [_]mutation.Action{
        .{ .write_tags = .{
            .path = fixture.source,
            .expected = fixture.original,
            .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
        } },
        .{ .write_tags = .{
            .path = fixture.second,
            .expected = fixture.second_original,
            .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
        } },
    };
    var plan = try mutation.Plan.init(std.testing.allocator, 7, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());
    var lock = try fixture.acquireLock();
    defer lock.release(std.testing.io);
    var executor = fixture.executorWith(&lock);

    try std.testing.expectError(error.StaleMutationOperation, executor.executePlan(&plan, 7));
    try std.testing.expect(executor.crashed);
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(1));
    try expectTitle(fixture.source, "After write");
    try std.testing.expect(fixture.second_original.eql(try fixture.currentSecond()));
}

test "recovery keeps the error a failed write recorded" {
    if (@import("builtin").os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.music.parent_dir.setFilePermissions(std.testing.io, &fixture.music.sub_path, .fromMode(0o555), .{});
    defer fixture.music.parent_dir.setFilePermissions(std.testing.io, &fixture.music.sub_path, .default_dir, .{}) catch {};
    const actions = [_]mutation.Action{.{ .write_tags = .{
        .path = fixture.source,
        .expected = fixture.original,
        .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
    } }};
    var plan = try mutation.Plan.init(std.testing.allocator, 7, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());
    var lock = try fixture.acquireLock();
    defer lock.release(std.testing.io);
    var executor = fixture.executorWith(&lock);

    try std.testing.expectError(error.AccessDenied, executor.executePlan(&plan, 7));
    try std.testing.expectEqual(@as(?u32, 0), executor.failed_action_index);
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try fixture.expectJournaledError(1, "AccessDenied");
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try fixture.expectMusicFolderUntouched();

    try fixture.library.database.exec("UPDATE mutation_operations SET state = 4 WHERE id = 1;");
    try std.testing.expectEqual(database.MutationState.failed, try fixture.library.mutation_journal.state(1));
    try fixture.library.recoverPendingMutations(std.testing.io, &lock);
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try fixture.expectJournaledError(1, "AccessDenied");
}

test "a tag write refuses a file whose middle changed after approval with its size and timestamp kept" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.lengthenSource();
    const actions = [_]mutation.Action{.{ .write_tags = .{
        .path = fixture.source,
        .expected = fixture.original,
        .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
    } }};
    var plan = try mutation.Plan.init(std.testing.allocator, 7, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());
    const edited = try fixture.forgeMiddleEdit();
    var lock = try fixture.acquireLock();
    defer lock.release(std.testing.io);
    var executor = fixture.executorWith(&lock);

    try std.testing.expectError(error.FileIdentityChanged, executor.executePlan(&plan, 7));
    try std.testing.expect(edited.eql(try fixture.current()));
    try expectTitle(fixture.source, "Before write");
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try fixture.expectJournaledError(1, "FileIdentityChanged");
    try fixture.expectMusicFolderUntouched();
    try std.testing.expect(!try pathExists(std.testing.io, fixture.library.backup_directory.?));
}

test "undo refuses a written file whose middle changed with its size and timestamp kept, and keeps its backup" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.lengthenSource();
    try fixture.write(7);
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    const edited = try fixture.forgeMiddleEdit();
    var lock = try fixture.acquireLock();
    defer lock.release(std.testing.io);
    var executor = fixture.executorWith(&lock);

    try std.testing.expectError(error.MutationNeedsReconciliation, executor.undoOperation(1));
    try std.testing.expect(edited.eql(try fixture.current()));
    try std.testing.expect(fixture.original.eql(try file_mutation.identity(std.testing.io, backup)));
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try fixture.library.mutation_journal.state(1),
    );
    try fixture.expectJournaledError(1, "undo target changed externally");
}

test "undoing a group refuses a file whose middle changed with its size and timestamp kept, and changes nothing" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.lengthenSource();
    try fixture.writeBoth(7);
    const second_written = try fixture.currentSecond();
    const edited = try fixture.forgeMiddleEdit();

    try std.testing.expectError(error.MutationNeedsReconciliation, fixture.undo(7));
    try std.testing.expect(edited.eql(try fixture.current()));
    try std.testing.expect(second_written.eql(try fixture.currentSecond()));
    try std.testing.expectEqual(
        database.MutationState.needs_reconciliation,
        try fixture.library.mutation_journal.state(1),
    );
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(2));
    try fixture.expectMusicFolderUntouched();
}

test "undo of a write journaled without content hashes compares the other three parts of its identity" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.lengthenSource();
    try fixture.write(7);
    try fixture.library.database.exec(
        "UPDATE mutation_operations SET expected_content_hash = NULL, committed_content_hash = NULL;",
    );
    {
        var operation = try fixture.library.mutation_journal.get(std.testing.allocator, 1);
        defer operation.deinit();
        try std.testing.expectEqual(@as(?storage.content_hash.Digest, null), operation.expected_content_hash);
        try std.testing.expectEqual(@as(?storage.content_hash.Digest, null), operation.committed_content_hash);
    }

    try fixture.undo(7);
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try fixture.expectMusicFolderUntouched();
}

test "a tag write refuses a read-only file before writing any file of its plan" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.setMode("second.mp3", 0o444);
    var lock = try fixture.acquireLock();
    defer lock.release(std.testing.io);
    var executor = fixture.executorWith(&lock);
    const actions = [_]mutation.Action{
        .{ .write_tags = .{
            .path = fixture.source,
            .expected = fixture.original,
            .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
        } },
        .{ .write_tags = .{
            .path = fixture.second,
            .expected = fixture.second_original,
            .changes = &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
        } },
    };
    var plan = try mutation.Plan.init(std.testing.allocator, 7, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());

    try std.testing.expectError(error.FileReadOnly, executor.executePlan(&plan, 7));
    try std.testing.expectEqual(@as(?u32, 1), executor.failed_action_index);
    try std.testing.expect(fixture.second_original.eql(try fixture.currentSecond()));
    try WriteFixture.expectMode(fixture.second, 0o444);
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(2));
    try fixture.expectJournaledError(2, "FileReadOnly");
    try std.testing.expectEqual(database.MutationState.rolled_back, try fixture.library.mutation_journal.state(1));
    try fixture.expectMusicFolderUntouched();
    try std.testing.expect(!try pathExists(std.testing.io, fixture.library.backup_directory.?));
}

test "a tag write refuses a file made read-only after its stage was built, and makes no backup" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    var lock = try fixture.acquireLock();
    defer lock.release(std.testing.io);
    var executor = fixture.executorWith(&lock);
    const stage_path = try siblingPath(std.testing.allocator, fixture.source, "stage", 7, 0);
    defer std.testing.allocator.free(stage_path);
    try file_mutation.stageMpeg(
        std.testing.allocator,
        std.testing.io,
        fixture.source,
        stage_path,
        fixture.original,
        &.{.{ .field = .title, .before = "Before write", .after = "After write" }},
        null,
    );
    try fixture.setMode("source.mp3", 0o444);
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);

    try std.testing.expectError(
        error.FileReadOnly,
        executor.commitWrite(fixture.source, stage_path, backup, fixture.original, null),
    );
    try std.testing.expect(fixture.original.eql(try fixture.current()));
    try WriteFixture.expectMode(fixture.source, 0o444);
    try std.testing.expect(!try pathExists(std.testing.io, fixture.library.backup_directory.?));
}

test "a tag write keeps the exact permission bits of the file it rewrites" {
    for ([_]std.posix.mode_t{ 0o644, 0o640, 0o664, 0o600 }) |mode| {
        var fixture = try WriteFixture.init(null);
        defer fixture.deinit();
        try fixture.setMode("source.mp3", mode);
        try fixture.setMode("second.mp3", 0o640);
        try fixture.writeBoth(7);
        try expectTitle(fixture.source, "After write");
        try expectTitle(fixture.second, "After write");
        try WriteFixture.expectMode(fixture.source, mode);
        try WriteFixture.expectMode(fixture.second, 0o640);

        try fixture.undo(7);
        try std.testing.expect(fixture.original.eql(try fixture.current()));
        try WriteFixture.expectMode(fixture.source, mode);
        try WriteFixture.expectMode(fixture.second, 0o640);
    }
}

test "undo refuses a written file made read-only since and changes nothing" {
    var fixture = try WriteFixture.init(null);
    defer fixture.deinit();
    try fixture.writeBoth(7);
    const written = try fixture.current();
    const second_written = try fixture.currentSecond();
    try fixture.setMode("source.mp3", 0o444);

    try std.testing.expectError(error.FileReadOnly, fixture.undo(7));
    try std.testing.expect(written.eql(try fixture.current()));
    try std.testing.expect(second_written.eql(try fixture.currentSecond()));
    try WriteFixture.expectMode(fixture.source, 0o444);
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(1));
    try std.testing.expectEqual(database.MutationState.committed, try fixture.library.mutation_journal.state(2));
    const backup = try fixture.backupPath(7);
    defer std.testing.allocator.free(backup);
    try std.testing.expect(fixture.original.eql(try file_mutation.identity(std.testing.io, backup)));
    try fixture.expectMusicFolderUntouched();

    try fixture.setMode("source.mp3", 0o644);
    try fixture.undo(7);
    try std.testing.expect(fixture.original.eql(try fixture.current()));
}
