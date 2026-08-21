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
    pub fn executeId3v1Plan(self: *Executor, plan: *mutation.Plan, group_id: u64) !void {
        if (group_id == 0) return error.InvalidMutationGroup;
        for (plan.actions) |action| switch (action) {
            .write_tags => |write| if (!hasMp3Extension(write.path))
                return error.UnsupportedTagWriter,
            .move => return error.UnsupportedMutationAction,
        };
        try plan.beginExecution();
        var completed: std.ArrayList(i64) = .empty;
        defer completed.deinit(self.allocator);
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
                file_mutation.stageId3v1(
                    self.io,
                    write.path,
                    stage_path,
                    write.expected,
                    write.changes,
                ) catch |err| {
                    self.journal.transition(operation, .planned, .failed, @errorName(err)) catch {};
                    return err;
                };
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
                try completed.append(self.allocator, operation);
                const committed = try file_mutation.identity(self.io, write.path);
                try self.journal.commit(
                    operation,
                    committed.size_bytes,
                    committed.modified_ns,
                );
            },
            .move => unreachable,
        };
        try plan.finish(true);
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
        const current = try file_mutation.identity(self.io, operation.source_path);
        if (!std.meta.eql(expected, current)) return error.FileIdentityChanged;
        try self.rollbackOperation(operation_id);
    }

    /// Resolve a nonterminal journal entry after interruption. Recovery always
    /// prefers the original bytes and never assumes a staged replacement won.
    pub fn recoverOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state == .committed or operation.state == .rolled_back) return;
        const stage_path = operation.stage_path orelse return error.MissingMutationStagePath;
        const backup_path = operation.backup_path orelse return error.MissingMutationBackupPath;
        if (try pathExists(self.io, backup_path)) {
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
        switch (operation.state) {
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
            .committed, .rolled_back => unreachable,
        }
    }

    fn rollbackOperation(self: *Executor, operation_id: i64) !void {
        var operation = try self.journal.get(self.allocator, operation_id);
        defer operation.deinit();
        if (operation.state != .committed and operation.state != .staged)
            return error.MutationOperationNotRecoverable;
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

fn hasMp3Extension(path: []const u8) bool {
    return path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".mp3");
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
    try std.testing.expectError(error.MutationPlanNotApproved, executor.executeId3v1Plan(&plan, 8));
    try plan.approve(44);
    try executor.executeId3v1Plan(&plan, 8);
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
    try executor.executeId3v1Plan(&second_plan, 9);

    const changed = try std.Io.Dir.cwd().openFile(std.testing.io, source_path, .{ .mode = .read_write });
    defer changed.close(std.testing.io);
    const stat = try changed.stat(std.testing.io);
    try changed.writePositionalAll(std.testing.io, "external", stat.size);
    try std.testing.expectError(error.FileIdentityChanged, executor.undoOperation(2));
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
}
