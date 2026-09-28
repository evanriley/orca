const std = @import("std");
const storage = @import("../storage/root.zig");
const database = @import("../database/repository.zig");
const file_mutation = @import("file_mutation.zig");
const mutation = @import("mutation.zig");

/// Boundaries at which an execution can lose power. Production callers leave
/// `Executor.fault` null; recovery tests set it so the real executor stops at a
/// real boundary and performs no compensation, exactly as a crash would.
pub const FaultPoint = enum {
    after_journal_prepare,
    after_stage,
    after_stage_journaled,
    after_backup_rename,
    after_source_rename,
    after_move_rename,
    before_journal_commit,
    rollback_after_displace,
    rollback_after_restore,
};

pub const Fault = struct {
    point: FaultPoint,
    action_index: u32 = 0,
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
    /// Test-only interruption request; see `FaultPoint`.
    fault: ?Fault = null,
    /// Set once an injected fault has fired, so no compensation runs.
    crashed: bool = false,

    /// Execute every tag action as one logical group. Each path is staged
    /// before replacement and each original remains as a journaled backup.
    ///
    /// Every action in the group is journaled in `planned` state before any
    /// filesystem work begins. That is what makes the group discoverable after
    /// a crash: as long as one action has not committed, startup recovery can
    /// find the group and unwind the ones that did.
    pub fn executePlan(self: *Executor, plan: *mutation.Plan, group_id: u64) !void {
        if (group_id == 0) return error.InvalidMutationGroup;
        for (plan.actions) |action| switch (action) {
            .write_tags => |write| _ = try tagFormat(self.io, write.path) orelse
                return error.UnsupportedTagWriter,
            .move => {},
        };
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
                const stage_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}.orca-stage-{d}-{d}",
                    .{ write.path, plan.id, action_index },
                );
                errdefer self.allocator.free(stage_path);
                const backup_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}.orca-backup-{d}-{d}",
                    .{ write.path, plan.id, action_index },
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
                });
                prepared.appendAssumeCapacity(.{ .id = operation });
            },
        };
        try self.interrupt(.after_journal_prepare, 0);

        for (plan.actions, 0..) |action, action_index| switch (action) {
            .write_tags => |write| {
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
                try self.interrupt(.after_stage, action_index);
                const staged_identity = try file_mutation.identity(self.io, stage_path);
                try self.journal.recordResultIdentity(
                    operation,
                    .planned,
                    staged_identity.size_bytes,
                    staged_identity.modified_ns,
                    staged_identity.quick_hash,
                );
                try self.journal.transition(operation, .planned, .staged, null);
                try self.interrupt(.after_stage_journaled, action_index);
                const commit_interrupt = self.commitInterrupt(action_index);
                if (commit_interrupt != null) self.crashed = true;
                file_mutation.commitReplacementInterrupted(
                    self.io,
                    write.path,
                    stage_path,
                    backup_path,
                    write.expected,
                    commit_interrupt,
                ) catch |err| {
                    if (self.crashed) return err;
                    std.Io.Dir.cwd().deleteFile(self.io, stage_path) catch {};
                    self.journal.transition(operation, .staged, .failed, @errorName(err)) catch {};
                    return err;
                };
                completed.appendAssumeCapacity(.{
                    .id = operation,
                    .action_index = @intCast(action_index),
                });
                try self.interrupt(.before_journal_commit, action_index);
                const committed = try file_mutation.identity(self.io, write.path);
                try self.journal.commit(
                    operation,
                    committed.size_bytes,
                    committed.modified_ns,
                    committed.quick_hash,
                );
            },
            .move => |move| {
                const operation = prepared.items[action_index].id;
                const current = try file_mutation.identity(self.io, move.source_path);
                if (!current.eql(move.expected) and
                    !try self.groupProducedIdentity(completed.items, move.source_path, current))
                    return error.FileIdentityChanged;
                if (try pathExists(self.io, move.destination_path)) return error.DestinationExists;
                try self.journal.recordResultIdentity(
                    operation,
                    .planned,
                    current.size_bytes,
                    current.modified_ns,
                    current.quick_hash,
                );
                try self.journal.transition(operation, .planned, .staged, null);
                try self.interrupt(.after_stage_journaled, action_index);
                file_mutation.commitMove(
                    self.io,
                    move.source_path,
                    move.destination_path,
                ) catch |err| {
                    self.journal.transition(operation, .staged, .failed, @errorName(err)) catch {};
                    return err;
                };
                completed.appendAssumeCapacity(.{
                    .id = operation,
                    .action_index = @intCast(action_index),
                });
                try self.interrupt(.after_move_rename, action_index);
                const committed = try file_mutation.identity(self.io, move.destination_path);
                try self.journal.commit(
                    operation,
                    committed.size_bytes,
                    committed.modified_ns,
                    committed.quick_hash,
                );
            },
        };
        try plan.finish(true);
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
        if (self.faultMatches(.after_backup_rename, action_index)) return .after_backup_rename;
        if (self.faultMatches(.after_source_rename, action_index)) return .after_source_rename;
        return null;
    }

    fn rollbackInterrupt(self: *const Executor, action_index: u32) ?file_mutation.Interrupt {
        if (self.faultMatches(.rollback_after_displace, action_index))
            return .after_rollback_displace;
        if (self.faultMatches(.rollback_after_restore, action_index))
            return .after_rollback_restore;
        return null;
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
        const expected = try resultIdentity(operation);
        const current_path = switch (operation.kind) {
            .write_tags => operation.source_path,
            .move => operation.destination_path orelse return error.MissingMutationDestination,
        };
        const current = try file_mutation.identity(self.io, current_path);
        if (!expected.eql(current)) {
            try self.journal.transition(
                operation_id,
                .committed,
                .needs_reconciliation,
                "undo target changed externally",
            );
            return error.MutationNeedsReconciliation;
        }
        try self.rollbackOperation(operation_id, null);
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
            if (!(try resultIdentity(operation)).eql(current)) {
                try self.reconcile(operation.id, operation.state, "group undo target changed externally");
                return error.MutationNeedsReconciliation;
            }
            if (operation.kind == .move and try pathExists(self.io, operation.source_path)) {
                try self.reconcile(operation.id, operation.state, "group undo destination exists");
                return error.MutationNeedsReconciliation;
            }
        }
        for (ids) |id| try self.rollbackOperation(id, null);
    }

    /// Resolve a nonterminal journal entry after interruption. Recovery always
    /// prefers the original bytes and never assumes a staged replacement won,
    /// and never reports `rolled_back` unless the original file is provably
    /// back in place.
    pub fn recoverOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state == .rolled_back or operation.state == .needs_reconciliation) return;
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
            const current = try file_mutation.identity(self.io, destination);
            if (!journaled.eql(current)) {
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

    fn recoverWriteTags(self: *Executor, operation: database.MutationOperation) !void {
        const stage_path = operation.stage_path orelse return error.MissingMutationStagePath;
        const backup_path = operation.backup_path orelse return error.MissingMutationBackupPath;
        const staged = resultIdentity(operation) catch null;
        // A recovery that was itself interrupted can leave this behind, so it is
        // cleaned up on every pass and not only on the pass that creates it.
        const displaced_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.recovery-displaced",
            .{stage_path},
        );
        defer self.allocator.free(displaced_path);
        const has_backup = try pathExists(self.io, backup_path);
        // Neither a completed stage nor a backup exists, so no Orca replacement
        // can be in effect. Remove a torn stage and stop: claiming anything
        // about the source itself would be a claim about somebody else's edit.
        if (staged == null and !has_backup) {
            try deleteIfPresent(self.io, stage_path);
            try deleteIfPresent(self.io, displaced_path);
            return self.finishRecoveryState(operation.id, operation.state);
        }
        if (has_backup) {
            if (try pathExists(self.io, operation.source_path)) {
                const current = try file_mutation.identity(self.io, operation.source_path);
                const is_replacement = staged != null and staged.?.eql(current);
                const is_original = if (expectedIdentity(operation)) |expected|
                    expected.eql(current)
                else |_|
                    false;
                if (!is_replacement and !is_original) {
                    try self.reconcile(
                        operation.id,
                        operation.state,
                        "tag target changed externally",
                    );
                    return error.MutationNeedsReconciliation;
                }
            }
            try file_mutation.rollbackReplacement(
                self.io,
                operation.source_path,
                backup_path,
                displaced_path,
            );
        }
        try deleteIfPresent(self.io, stage_path);
        try deleteIfPresent(self.io, displaced_path);

        if (!try pathExists(self.io, operation.source_path)) {
            try self.reconcile(
                operation.id,
                operation.state,
                "the original source is missing and no backup could restore it",
            );
            return error.MutationNeedsReconciliation;
        }
        const current = try file_mutation.identity(self.io, operation.source_path);
        if (expectedIdentity(operation)) |expected| {
            if (expected.eql(current))
                return self.finishRecoveryState(operation.id, operation.state);
        } else |_| {}
        // Nothing was ever staged, so no Orca write can be in effect regardless
        // of what else changed this file.
        if (staged == null) return self.finishRecoveryState(operation.id, operation.state);
        if (staged.?.eql(current)) {
            try self.reconcile(
                operation.id,
                operation.state,
                "the staged replacement is in place and its backup is gone",
            );
            return error.MutationNeedsReconciliation;
        }
        try self.reconcile(
            operation.id,
            operation.state,
            "source does not match the journaled original identity",
        );
        return error.MutationNeedsReconciliation;
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
            .committed => try self.journal.transition(
                operation_id,
                .committed,
                .rolled_back,
                "recovered",
            ),
            .rolled_back, .needs_reconciliation => unreachable,
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

    fn rollbackOperation(
        self: *Executor,
        operation_id: i64,
        rollback_interrupt: ?file_mutation.Interrupt,
    ) !void {
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
            try file_mutation.commitMove(self.io, destination, operation.source_path);
            try self.journal.transition(operation_id, operation.state, .rolled_back, null);
            return;
        }
        const stage_path = operation.stage_path orelse return error.MissingMutationStagePath;
        const backup_path = operation.backup_path orelse return error.MissingMutationBackupPath;
        if (rollback_interrupt != null) self.crashed = true;
        try file_mutation.rollbackReplacementInterrupted(
            self.io,
            operation.source_path,
            backup_path,
            stage_path,
            rollback_interrupt,
        );
        try self.journal.transition(operation_id, operation.state, .rolled_back, null);
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
    };
}

fn expectedIdentity(operation: database.MutationOperation) !mutation.FileIdentity {
    return .{
        .size_bytes = operation.expected_size,
        .modified_ns = operation.expected_modified_ns,
        .quick_hash = operation.expected_quick_hash orelse return error.MissingExpectedIdentity,
    };
}

/// Whether Orca can write tags into the file at `path`.
pub fn canWriteTags(io: std.Io, path: []const u8) !bool {
    return try tagFormat(io, path) != null;
}

const TagFormat = enum { mpeg, flac };

/// Which writer a file takes, decided by its bytes as every reader decides,
/// never by its name. Null for a format Orca cannot write tags into yet.
fn tagFormat(io: std.Io, path: []const u8) !?TagFormat {
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

fn deleteIfPresent(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try file_mutation.syncContainingDirectory(io, path);
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
    var executor: Executor = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .journal = &library.mutation_journal,
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
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, source, stage, expected, &.{.{
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
        staged_identity.quick_hash,
    );
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    try file_mutation.commitReplacement(std.testing.io, source, stage, backup, expected);

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
        .expected_quick_hash = expected_again.quick_hash,
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, source, stage, expected_again, &.{.{
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
        staged_only_identity.quick_hash,
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
    });
    try file_mutation.stageMpeg(std.testing.allocator, std.testing.io, source, stage, expected_again, &.{.{
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
        changed_stage_identity.quick_hash,
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
    });
    try library.mutation_journal.recordResultIdentity(
        operation,
        .planned,
        expected.size_bytes,
        expected.modified_ns,
        expected.quick_hash,
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
