const std = @import("std");
const sqlite = @import("../sqlite.zig");
const quick_hash = @import("../../storage/quick_hash.zig");
const columns = @import("../columns.zig");

const digestColumn = columns.digestColumn;
const duplicateNullableColumn = columns.duplicateNullableColumn;
const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const MutationKind = enum { write_tags, move };

pub const MutationState = enum {
    planned,
    staged,
    committed,
    rolled_back,
    failed,
    needs_reconciliation,
};

/// A journal record keeps its paths — a filesystem operation's subject
/// genuinely is a path, which is not an identity violation — and carries
/// `file_id` so the journal can restore musical identity after a move.
pub const MutationOperationInput = struct {
    plan_id: u64,
    group_id: u64,
    action_index: u32,
    kind: MutationKind,
    file_id: ?i64 = null,
    source_path: []const u8,
    destination_path: ?[]const u8 = null,
    stage_path: ?[]const u8 = null,
    backup_path: ?[]const u8 = null,
    expected_size: u64,
    expected_modified_ns: i64,
    expected_quick_hash: quick_hash.Digest,
};

pub const MutationOperation = struct {
    allocator: std.mem.Allocator,
    id: i64,
    plan_id: u64,
    action_index: u32,
    kind: MutationKind,
    file_id: ?i64,
    source_path: []u8,
    destination_path: ?[]u8,
    stage_path: ?[]u8,
    backup_path: ?[]u8,
    expected_size: u64,
    expected_modified_ns: i64,
    expected_quick_hash: ?quick_hash.Digest,
    committed_size: ?u64,
    committed_modified_ns: ?i64,
    committed_quick_hash: ?quick_hash.Digest,
    state: MutationState,

    pub fn deinit(self: MutationOperation) void {
        self.allocator.free(self.source_path);
        if (self.destination_path) |value| self.allocator.free(value);
        if (self.stage_path) |value| self.allocator.free(value);
        if (self.backup_path) |value| self.allocator.free(value);
    }
};

pub const PrunableBackup = struct {
    operation_id: i64,
    backup_path: []u8,
};

pub const PrunableBackupPage = struct {
    allocator: std.mem.Allocator,
    items: []PrunableBackup,

    pub fn deinit(self: PrunableBackupPage) void {
        for (self.items) |item| self.allocator.free(item.backup_path);
        self.allocator.free(self.items);
    }
};

pub const MutationJournalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// The journal is the only record that a file mutation is in flight, so its
    /// writes must reach stable storage before the filesystem changes they
    /// describe. `synchronous=NORMAL` does not fsync a WAL commit, so journal
    /// writes raise durability for their own transaction and restore the
    /// library-wide setting afterwards.
    fn beginDurable(self: *MutationJournalRepository) !void {
        try self.db.exec("PRAGMA synchronous=FULL;");
    }

    fn endDurable(self: *MutationJournalRepository) void {
        self.db.exec("PRAGMA synchronous=NORMAL;") catch {};
    }

    pub fn prepare(self: *MutationJournalRepository, input: MutationOperationInput) !i64 {
        if (input.plan_id == 0 or input.group_id == 0 or input.source_path.len == 0)
            return error.InvalidMutationOperation;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\INSERT INTO mutation_operations(
            \\    plan_id, group_id, action_index, kind, source_path, destination_path,
            \\    stage_path, backup_path, expected_size, expected_modified_ns, state,
            \\    file_id, expected_quick_hash
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(input.plan_id));
        try statement.bindInt64(2, @intCast(input.group_id));
        try statement.bindInt64(3, input.action_index);
        try statement.bindInt64(4, @intFromEnum(input.kind));
        try statement.bindText(5, input.source_path);
        try statement.bindOptionalText(6, input.destination_path);
        try statement.bindOptionalText(7, input.stage_path);
        try statement.bindOptionalText(8, input.backup_path);
        try statement.bindInt64(9, @intCast(input.expected_size));
        try statement.bindInt64(10, input.expected_modified_ns);
        try statement.bindInt64(11, @intFromEnum(MutationState.planned));
        try statement.bindOptionalInt64(12, input.file_id);
        try statement.bindBlob(13, &input.expected_quick_hash);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.lastInsertRowId();
    }

    pub fn transition(
        self: *MutationJournalRepository,
        operation_id: i64,
        expected: MutationState,
        next: MutationState,
        message: ?[]const u8,
    ) !void {
        if (!validMutationTransition(expected, next)) return error.InvalidMutationTransition;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, error=?2, updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(next));
        try statement.bindOptionalText(2, message);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @intFromEnum(expected));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn state(self: *const MutationJournalRepository, operation_id: i64) !MutationState {
        var statement = try self.db.prepare(
            "SELECT state FROM mutation_operations WHERE id=?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        return std.enums.fromInt(MutationState, statement.columnInt64(0)) orelse
            error.InvalidStoredMutationState;
    }

    pub fn commit(
        self: *MutationJournalRepository,
        operation_id: i64,
        committed_size: u64,
        committed_modified_ns: i64,
        committed_quick_hash: quick_hash.Digest,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, committed_size=?2, committed_modified_ns=?3,
            \\    committed_quick_hash=?6, updated_at=unixepoch()
            \\WHERE id=?4 AND state=?5;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.committed));
        try statement.bindInt64(2, @intCast(committed_size));
        try statement.bindInt64(3, committed_modified_ns);
        try statement.bindInt64(4, operation_id);
        try statement.bindInt64(5, @intFromEnum(MutationState.staged));
        try statement.bindBlob(6, &committed_quick_hash);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn recordResultIdentity(
        self: *MutationJournalRepository,
        operation_id: i64,
        expected_state: MutationState,
        size: u64,
        modified_ns: i64,
        digest: quick_hash.Digest,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET committed_size=?1, committed_modified_ns=?2, committed_quick_hash=?5,
            \\    updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(size));
        try statement.bindInt64(2, modified_ns);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @intFromEnum(expected_state));
        try statement.bindBlob(5, &digest);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn get(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        operation_id: i64,
    ) !MutationOperation {
        var statement = try self.db.prepare(
            \\SELECT kind, source_path, destination_path, stage_path, backup_path,
            \\       expected_size, expected_modified_ns,
            \\       committed_size, committed_modified_ns, state,
            \\       file_id, expected_quick_hash, committed_quick_hash,
            \\       plan_id, action_index
            \\FROM mutation_operations WHERE id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        const kind = std.enums.fromInt(MutationKind, statement.columnInt64(0)) orelse
            return error.InvalidStoredMutationKind;
        const source_path = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(source_path);
        const destination_path = try duplicateNullableColumn(allocator, statement, 2);
        errdefer if (destination_path) |value| allocator.free(value);
        const stage_path = try duplicateNullableColumn(allocator, statement, 3);
        errdefer if (stage_path) |value| allocator.free(value);
        const backup_path = try duplicateNullableColumn(allocator, statement, 4);
        errdefer if (backup_path) |value| allocator.free(value);
        const state_value = std.enums.fromInt(MutationState, statement.columnInt64(9)) orelse
            return error.InvalidStoredMutationState;
        return .{
            .allocator = allocator,
            .id = operation_id,
            .plan_id = @intCast(statement.columnInt64(13)),
            .action_index = @intCast(statement.columnInt64(14)),
            .kind = kind,
            .file_id = optionalInt64(statement, 10),
            .source_path = source_path,
            .destination_path = destination_path,
            .stage_path = stage_path,
            .backup_path = backup_path,
            .expected_size = @intCast(statement.columnInt64(5)),
            .expected_modified_ns = statement.columnInt64(6),
            .expected_quick_hash = digestColumn(statement, 11),
            .committed_size = if (statement.columnIsNull(7)) null else @intCast(statement.columnInt64(7)),
            .committed_modified_ns = if (statement.columnIsNull(8)) null else statement.columnInt64(8),
            .committed_quick_hash = digestColumn(statement, 12),
            .state = state_value,
        };
    }

    /// Groups holding at least one operation that has not reached a terminal
    /// state. Startup recovery drives exactly these to a terminal state before a
    /// Library becomes available.
    pub fn nonterminalGroupIds(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
    ) ![]u64 {
        var statement = try self.db.prepare(
            \\SELECT DISTINCT group_id FROM mutation_operations
            \\WHERE state IN (?1, ?2, ?3) ORDER BY group_id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.planned));
        try statement.bindInt64(2, @intFromEnum(MutationState.staged));
        try statement.bindInt64(3, @intFromEnum(MutationState.failed));
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, @intCast(statement.columnInt64(0)));
        return ids.toOwnedSlice(allocator);
    }

    /// A group and plan id no journaled operation uses yet. Stage and backup
    /// paths are named after the plan id, so it must not repeat.
    pub fn nextGroupId(self: *const MutationJournalRepository) !u64 {
        var statement = try self.db.prepare(
            "SELECT COALESCE(MAX(MAX(group_id), MAX(plan_id)), 0) + 1 FROM mutation_operations;",
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn groupOperationIds(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        group_id: u64,
    ) ![]i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM mutation_operations
            \\WHERE group_id=?1 ORDER BY action_index DESC;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(group_id));
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }

    /// Backups of groups whose every operation is committed and was last
    /// updated at least `older_than_s` seconds ago, at most one page of them.
    pub fn prunableBackups(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        older_than_s: u64,
    ) !PrunableBackupPage {
        var statement = try self.db.prepare(
            \\SELECT operation.id, operation.backup_path FROM mutation_operations AS operation
            \\WHERE operation.backup_path IS NOT NULL AND operation.state = ?1
            \\  AND NOT EXISTS (
            \\      SELECT 1 FROM mutation_operations AS member
            \\      WHERE member.group_id = operation.group_id
            \\        AND (member.state <> ?1 OR member.updated_at > unixepoch() - ?2))
            \\ORDER BY operation.id LIMIT ?3;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.committed));
        try statement.bindInt64(2, std.math.cast(i64, older_than_s) orelse std.math.maxInt(i64));
        try statement.bindInt64(3, max_page);
        var items: std.ArrayList(PrunableBackup) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.backup_path);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const backup_path = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(backup_path);
            try items.append(allocator, .{
                .operation_id = statement.columnInt64(0),
                .backup_path = backup_path,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// Records that a committed operation's backup is gone. `updated_at` is
    /// left alone, because it is the age the rest of its group is pruned by.
    pub fn clearBackupPath(self: *MutationJournalRepository, operation_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations SET backup_path = NULL
            \\WHERE id = ?1 AND state = ?2 AND backup_path IS NOT NULL;
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        try statement.bindInt64(2, @intFromEnum(MutationState.committed));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }
};

fn validMutationTransition(from: MutationState, to: MutationState) bool {
    if (to == .needs_reconciliation) return from != .rolled_back and
        from != .needs_reconciliation;
    return switch (from) {
        .planned => to == .staged or to == .failed,
        .staged => to == .committed or to == .rolled_back or to == .failed,
        .failed => to == .rolled_back,
        .committed => to == .rolled_back,
        .rolled_back, .needs_reconciliation => false,
    };
}
