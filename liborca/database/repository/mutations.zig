const std = @import("std");
const sqlite = @import("../sqlite.zig");
const content_hash = @import("../../storage/content_hash.zig");
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
    undoing,
};

/// Already stored in existing journals, and the history tells a recovered
/// rollback from an undo by it, so changing it misreports every older group.
pub const recovered_message = "recovered";

pub const GroupStateCounts = struct {
    planned: u64 = 0,
    staged: u64 = 0,
    committed: u64 = 0,
    rolled_back: u64 = 0,
    failed: u64 = 0,
    needs_reconciliation: u64 = 0,
    undoing: u64 = 0,

    pub fn add(self: *GroupStateCounts, state_value: MutationState) void {
        switch (state_value) {
            inline else => |tag| @field(self, @tagName(tag)) += 1,
        }
    }

    pub fn total(self: GroupStateCounts) u64 {
        return self.planned + self.staged + self.committed + self.rolled_back +
            self.failed + self.needs_reconciliation + self.undoing;
    }
};

pub const UndoAvailability = enum {
    fresh,
    interrupted,
    backups_pruned,
    already_undone,
    needs_reconciliation,
    not_committed,
};

pub fn undoAvailability(counts: GroupStateCounts, backups_present: bool) UndoAvailability {
    if (counts.planned + counts.staged + counts.failed > 0) return .not_committed;
    const operations = counts.total();
    if (counts.committed == operations) return if (backups_present) .fresh else .backups_pruned;
    if (counts.undoing > 0) return .interrupted;
    if (counts.needs_reconciliation > 0) return .needs_reconciliation;
    if (counts.rolled_back == operations) return .already_undone;
    return .not_committed;
}

pub const MutationGroupState = enum {
    applied,
    undoing,
    undone,
    rolled_back,
    failed,
    needs_reconciliation,
};

pub const MutationGroupSummary = struct {
    group_id: u64,
    written_at: i64,
    operations: u64,
    counts: GroupStateCounts,
    backups_present: bool,
    write_errors: u64,
    recovered: u64,
    title: ?[]u8,

    pub fn state(self: MutationGroupSummary) MutationGroupState {
        const counts = self.counts;
        if (counts.needs_reconciliation > 0) return .needs_reconciliation;
        if (counts.failed > 0) return .failed;
        if (counts.undoing > 0) return .undoing;
        if (counts.committed == self.operations) return .applied;
        if (counts.rolled_back != self.operations or self.write_errors > 0) return .failed;
        if (self.recovered > 0) return .rolled_back;
        return .undone;
    }

    pub fn undo(self: MutationGroupSummary) UndoAvailability {
        return undoAvailability(self.counts, self.backups_present);
    }

    pub fn deinit(self: MutationGroupSummary, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
    }
};

pub const MutationGroupSummaryPage = struct {
    allocator: std.mem.Allocator,
    items: []MutationGroupSummary,

    pub fn deinit(self: MutationGroupSummaryPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

fn stateSum(comptime state_value: MutationState) []const u8 {
    return std.fmt.comptimePrint("sum(operation.state = {d})", .{@intFromEnum(state_value)});
}

const write_tags_kind = std.fmt.comptimePrint("{d}", .{@intFromEnum(MutationKind.write_tags)});

const group_summary_select =
    "SELECT operation.group_id, min(operation.created_at), count(*),\n" ++
    "       " ++ stateSum(.planned) ++ ", " ++ stateSum(.staged) ++ ", " ++ stateSum(.committed) ++ ",\n" ++
    "       " ++ stateSum(.rolled_back) ++ ", " ++ stateSum(.failed) ++ ",\n" ++
    "       " ++ stateSum(.needs_reconciliation) ++ ", " ++ stateSum(.undoing) ++ ",\n" ++
    "       sum(operation.kind = " ++ write_tags_kind ++ " AND operation.backup_path IS NULL),\n" ++
    "       sum(operation.state = " ++ std.fmt.comptimePrint("{d}", .{@intFromEnum(MutationState.rolled_back)}) ++
    " AND operation.error IS NOT NULL AND operation.error <> '" ++ recovered_message ++ "'),\n" ++
    "       sum(operation.error = '" ++ recovered_message ++ "'),\n" ++
    \\       (SELECT CASE WHEN count(DISTINCT track.release_id) = 1 THEN min(release_row.title) END
    \\        FROM mutation_operations AS member
    \\        JOIN locations AS location ON location.uri = member.source_path
    \\        JOIN files AS file ON file.id = location.file_id
    \\        JOIN tracks AS track
    \\          ON track.preferred_file_id = file.id OR track.recording_id = file.recording_id
    \\        JOIN releases AS release_row ON release_row.id = track.release_id
    \\        WHERE member.group_id = operation.group_id)
    \\FROM mutation_operations AS operation
    \\
    ;

const group_summary_having =
    "HAVING sum(operation.kind = " ++ write_tags_kind ++ ") > 0 AND " ++
    stateSum(.planned) ++ " + " ++ stateSum(.staged) ++ " = 0\n";

fn readGroupSummary(allocator: std.mem.Allocator, statement: sqlite.Statement) !MutationGroupSummary {
    var counts: GroupStateCounts = .{};
    inline for (.{ "planned", "staged", "committed", "rolled_back", "failed", "needs_reconciliation", "undoing" }, 3..) |name, column| {
        @field(counts, name) = @intCast(statement.columnInt64(column));
    }
    return .{
        .group_id = @intCast(statement.columnInt64(0)),
        .written_at = statement.columnInt64(1),
        .operations = @intCast(statement.columnInt64(2)),
        .counts = counts,
        .backups_present = statement.columnInt64(10) == 0,
        .write_errors = @intCast(statement.columnInt64(11)),
        .recovered = @intCast(statement.columnInt64(12)),
        .title = try duplicateNullableColumn(allocator, statement, 13),
    };
}

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
    expected_content_hash: ?content_hash.Digest = null,
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
    expected_content_hash: ?content_hash.Digest,
    committed_size: ?u64,
    committed_modified_ns: ?i64,
    committed_quick_hash: ?quick_hash.Digest,
    committed_content_hash: ?content_hash.Digest,
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
            \\    file_id, expected_quick_hash, expected_content_hash
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);
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
        try statement.bindOptionalBlob(14, if (input.expected_content_hash) |*digest| digest else null);
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

    pub fn rollBackFailed(self: *MutationJournalRepository, operation_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, updated_at=unixepoch()
            \\WHERE id=?2 AND state=?3;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.rolled_back));
        try statement.bindInt64(2, operation_id);
        try statement.bindInt64(3, @intFromEnum(MutationState.failed));
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
        committed_content_hash: content_hash.Digest,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, committed_size=?2, committed_modified_ns=?3,
            \\    committed_quick_hash=?6, committed_content_hash=?7, updated_at=unixepoch()
            \\WHERE id=?4 AND state=?5;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.committed));
        try statement.bindInt64(2, @intCast(committed_size));
        try statement.bindInt64(3, committed_modified_ns);
        try statement.bindInt64(4, operation_id);
        try statement.bindInt64(5, @intFromEnum(MutationState.staged));
        try statement.bindBlob(6, &committed_quick_hash);
        try statement.bindBlob(7, &committed_content_hash);
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
        content: content_hash.Digest,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET committed_size=?1, committed_modified_ns=?2, committed_quick_hash=?5,
            \\    committed_content_hash=?6, updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(size));
        try statement.bindInt64(2, modified_ns);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @intFromEnum(expected_state));
        try statement.bindBlob(5, &digest);
        try statement.bindBlob(6, &content);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn get(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        operation_id: i64,
    ) !MutationOperation {
        const columns_before_content_hash =
            \\SELECT kind, source_path, destination_path, stage_path, backup_path,
            \\       expected_size, expected_modified_ns,
            \\       committed_size, committed_modified_ns, state,
            \\       file_id, expected_quick_hash, committed_quick_hash,
            \\       plan_id, action_index,
        ;
        const from = " FROM mutation_operations WHERE id=?1;";
        // Startup recovery reads the journal at `journal_ready_version`,
        // before the migration that adds the content hash columns.
        var statement = try self.db.prepare(if (try self.hasContentHashColumns())
            columns_before_content_hash ++ " expected_content_hash, committed_content_hash" ++ from
        else
            columns_before_content_hash ++ " NULL, NULL" ++ from);
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
        const expected_content_hash = try contentHashColumn(statement, 15);
        const committed_content_hash = try contentHashColumn(statement, 16);
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
            .expected_content_hash = expected_content_hash,
            .committed_size = if (statement.columnIsNull(7)) null else @intCast(statement.columnInt64(7)),
            .committed_modified_ns = if (statement.columnIsNull(8)) null else statement.columnInt64(8),
            .committed_quick_hash = digestColumn(statement, 12),
            .committed_content_hash = committed_content_hash,
            .state = state_value,
        };
    }

    fn hasContentHashColumns(self: *const MutationJournalRepository) !bool {
        var statement = try self.db.prepare(
            \\SELECT count(*) FROM pragma_table_info('mutation_operations')
            \\WHERE name IN ('expected_content_hash', 'committed_content_hash');
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0) == 2;
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
            \\WHERE state IN (?1, ?2, ?3, ?4) ORDER BY group_id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.planned));
        try statement.bindInt64(2, @intFromEnum(MutationState.staged));
        try statement.bindInt64(3, @intFromEnum(MutationState.failed));
        try statement.bindInt64(4, @intFromEnum(MutationState.undoing));
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, @intCast(statement.columnInt64(0)));
        return ids.toOwnedSlice(allocator);
    }

    /// Records the intent to undo a whole group before any of its files is
    /// restored: every operation becomes `undoing` in one transaction, or none
    /// does and the group is refused because one of them is not committed.
    pub fn beginUndo(self: *MutationJournalRepository, group_id: u64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var count = try self.db.prepare("SELECT count(*) FROM mutation_operations WHERE group_id=?1;");
        defer count.deinit();
        try count.bindInt64(1, @intCast(group_id));
        if (try count.step() != .row) return error.SqlFailed;
        const operations: u64 = @intCast(count.columnInt64(0));
        if (operations == 0) return error.MutationGroupNotFound;
        if (try self.undoCommittedLocked(group_id) != operations) return error.MutationGroupNotCommitted;
        try self.db.exec("COMMIT;");
    }

    /// Marks every committed operation of a group `undoing` in one transaction,
    /// so an interrupted unwind of the group is found again and finished rather
    /// than left half applied. Returns how many it marked.
    pub fn undoCommitted(self: *MutationJournalRepository, group_id: u64) !u64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        return self.undoCommittedLocked(group_id);
    }

    fn undoCommittedLocked(self: *MutationJournalRepository, group_id: u64) !u64 {
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, updated_at=unixepoch()
            \\WHERE group_id=?2 AND state=?3;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.undoing));
        try statement.bindInt64(2, @intCast(group_id));
        try statement.bindInt64(3, @intFromEnum(MutationState.committed));
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes();
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

    pub fn groupSummaryPage(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !MutationGroupSummaryPage {
        var statement = try self.db.prepare(group_summary_select ++
            "GROUP BY operation.group_id\n" ++ group_summary_having ++
            "ORDER BY operation.group_id DESC LIMIT ?1 OFFSET ?2;");
        defer statement.deinit();
        try statement.bindInt64(1, @min(limit, max_page));
        try statement.bindInt64(2, offset);
        var items: std.ArrayList(MutationGroupSummary) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const summary = try readGroupSummary(allocator, statement);
            errdefer summary.deinit(allocator);
            try items.append(allocator, summary);
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    pub fn groupSummary(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        group_id: u64,
    ) !?MutationGroupSummary {
        var statement = try self.db.prepare(group_summary_select ++
            "WHERE operation.group_id = ?1\nGROUP BY operation.group_id\n" ++ group_summary_having ++ ";");
        defer statement.deinit();
        try statement.bindInt64(1, std.math.cast(i64, group_id) orelse return null);
        if (try statement.step() != .row) return null;
        return try readGroupSummary(allocator, statement);
    }
};

fn validMutationTransition(from: MutationState, to: MutationState) bool {
    if (to == .needs_reconciliation) return from != .rolled_back and
        from != .needs_reconciliation;
    return switch (from) {
        .planned => to == .staged or to == .failed,
        .staged => to == .committed or to == .rolled_back or to == .failed,
        .failed => to == .rolled_back,
        .committed => to == .undoing,
        .undoing => to == .rolled_back,
        .rolled_back, .needs_reconciliation => false,
    };
}

/// A malformed blob is an error rather than null, because null would weaken
/// the operation's identity check to the quick hash.
fn contentHashColumn(statement: sqlite.Statement, column: c_int) !?content_hash.Digest {
    if (statement.columnIsNull(column)) return null;
    const bytes = statement.columnBlob(column);
    if (bytes.len != @typeInfo(content_hash.Digest).array.len) return error.InvalidStoredContentHash;
    var digest: content_hash.Digest = undefined;
    @memcpy(&digest, bytes);
    return digest;
}

const JournalFixture = struct {
    db: sqlite.Database,
    lane: WriteLane,
    journal: MutationJournalRepository,

    fn init(self: *JournalFixture) !void {
        self.db = try sqlite.Database.open(":memory:");
        errdefer self.db.close();
        try @import("../migrations.zig").apply(self.db);
        self.lane = .{ .io = std.testing.io };
        self.journal = .{ .db = self.db, .write_lane = &self.lane };
    }

    fn deinit(self: *JournalFixture) void {
        self.db.close();
    }

    fn prepare(self: *JournalFixture, group_id: u64, action_index: u32) !i64 {
        return self.journal.prepare(.{
            .plan_id = group_id,
            .group_id = group_id,
            .action_index = action_index,
            .kind = .write_tags,
            .source_path = "/music/a.flac",
            .expected_size = 1,
            .expected_modified_ns = 1,
            .expected_quick_hash = @splat(1),
        });
    }

    fn committed(self: *JournalFixture, group_id: u64, action_index: u32) !i64 {
        const id = try self.prepare(group_id, action_index);
        try self.journal.transition(id, .planned, .staged, null);
        try self.journal.commit(id, 2, 2, @splat(2), @splat(2));
        return id;
    }
};

test "a committed operation reaches rolled_back only through undoing" {
    var fixture: JournalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const id = try fixture.committed(3, 0);

    try std.testing.expectError(error.InvalidMutationTransition, fixture.journal.transition(id, .committed, .rolled_back, null));
    try std.testing.expectError(error.InvalidMutationTransition, fixture.journal.transition(id, .undoing, .committed, null));
    try fixture.journal.transition(id, .committed, .undoing, null);
    try std.testing.expectError(error.InvalidMutationTransition, fixture.journal.transition(id, .undoing, .committed, null));
    try fixture.journal.transition(id, .undoing, .rolled_back, null);
    try std.testing.expectEqual(MutationState.rolled_back, try fixture.journal.state(id));
}

test "a group's undo intent is recorded for every operation or none" {
    var fixture: JournalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const kept = try fixture.committed(4, 0);
    const failed = try fixture.prepare(4, 1);
    try fixture.journal.transition(failed, .planned, .failed, null);
    const first = try fixture.committed(5, 0);
    const second = try fixture.committed(5, 1);

    try std.testing.expectError(error.MutationGroupNotCommitted, fixture.journal.beginUndo(4));
    try std.testing.expectEqual(MutationState.committed, try fixture.journal.state(kept));
    try std.testing.expectEqual(MutationState.failed, try fixture.journal.state(failed));
    try std.testing.expectError(error.MutationGroupNotFound, fixture.journal.beginUndo(6));

    try fixture.journal.beginUndo(5);
    try std.testing.expectEqual(MutationState.undoing, try fixture.journal.state(first));
    try std.testing.expectEqual(MutationState.undoing, try fixture.journal.state(second));
    const groups = try fixture.journal.nonterminalGroupIds(std.testing.allocator);
    defer std.testing.allocator.free(groups);
    try std.testing.expectEqualSlices(u64, &.{ 4, 5 }, groups);
}

fn prepareWrite(fixture: *JournalFixture, group_id: u64, action_index: u32) !i64 {
    return fixture.journal.prepare(.{
        .plan_id = group_id,
        .group_id = group_id,
        .action_index = action_index,
        .kind = .write_tags,
        .source_path = "/music/a.flac",
        .backup_path = "/backups/a.flac",
        .expected_size = 1,
        .expected_modified_ns = 1,
        .expected_quick_hash = @splat(1),
    });
}

fn committedWrite(fixture: *JournalFixture, group_id: u64, action_index: u32) !i64 {
    const id = try prepareWrite(fixture, group_id, action_index);
    try fixture.journal.transition(id, .planned, .staged, null);
    try fixture.journal.commit(id, 2, 2, @splat(2), @splat(2));
    return id;
}

fn countsOf(states: []const MutationState) GroupStateCounts {
    var counts: GroupStateCounts = .{};
    for (states) |state_value| counts.add(state_value);
    return counts;
}

test "a group can be undone when it is fresh with every backup, or when its undo was interrupted" {
    try std.testing.expectEqual(UndoAvailability.fresh, undoAvailability(countsOf(&.{ .committed, .committed }), true));
    try std.testing.expectEqual(UndoAvailability.backups_pruned, undoAvailability(countsOf(&.{ .committed, .committed }), false));
    try std.testing.expectEqual(UndoAvailability.interrupted, undoAvailability(countsOf(&.{ .rolled_back, .undoing, .committed }), false));
    try std.testing.expectEqual(UndoAvailability.needs_reconciliation, undoAvailability(countsOf(&.{ .rolled_back, .needs_reconciliation }), true));
    try std.testing.expectEqual(UndoAvailability.already_undone, undoAvailability(countsOf(&.{ .rolled_back, .rolled_back }), true));
    try std.testing.expectEqual(UndoAvailability.not_committed, undoAvailability(countsOf(&.{ .committed, .staged }), true));
    try std.testing.expectEqual(UndoAvailability.not_committed, undoAvailability(countsOf(&.{ .committed, .failed, .undoing }), true));
    try std.testing.expectEqual(UndoAvailability.not_committed, undoAvailability(countsOf(&.{ .committed, .rolled_back }), true));
}

test "the group history lists finished tag-write groups newest first and leaves out those in flight" {
    var fixture: JournalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (1..6) |group| {
        _ = try committedWrite(&fixture, group, 0);
        _ = try committedWrite(&fixture, group, 1);
    }
    _ = try committedWrite(&fixture, 6, 0);
    _ = try prepareWrite(&fixture, 6, 1);
    const moved = try fixture.journal.prepare(.{
        .plan_id = 7,
        .group_id = 7,
        .action_index = 0,
        .kind = .move,
        .source_path = "/music/a.flac",
        .destination_path = "/music/b.flac",
        .expected_size = 1,
        .expected_modified_ns = 1,
        .expected_quick_hash = @splat(1),
    });
    try fixture.journal.transition(moved, .planned, .staged, null);
    try fixture.journal.commit(moved, 1, 1, @splat(1), @splat(1));

    const first = try fixture.journal.groupSummaryPage(std.testing.allocator, 2, 0);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.items.len);
    try std.testing.expectEqual(@as(u64, 5), first.items[0].group_id);
    try std.testing.expectEqual(@as(u64, 4), first.items[1].group_id);
    try std.testing.expectEqual(@as(u64, 2), first.items[0].operations);
    try std.testing.expectEqual(MutationGroupState.applied, first.items[0].state());
    try std.testing.expectEqual(UndoAvailability.fresh, first.items[0].undo());
    try std.testing.expect(first.items[0].written_at > 0);
    try std.testing.expect(first.items[0].title == null);

    const last = try fixture.journal.groupSummaryPage(std.testing.allocator, 2, 4);
    defer last.deinit();
    try std.testing.expectEqual(@as(usize, 1), last.items.len);
    try std.testing.expectEqual(@as(u64, 1), last.items[0].group_id);
    const past = try fixture.journal.groupSummaryPage(std.testing.allocator, 2, 5);
    defer past.deinit();
    try std.testing.expectEqual(@as(usize, 0), past.items.len);

    try std.testing.expect(try fixture.journal.groupSummary(std.testing.allocator, 6) == null);
    try std.testing.expect(try fixture.journal.groupSummary(std.testing.allocator, 7) == null);
    try std.testing.expect(try fixture.journal.groupSummary(std.testing.allocator, 99) == null);
}

test "a group's history state tells an undo from a failed write and from a recovered one" {
    var fixture: JournalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const undone = try committedWrite(&fixture, 1, 0);
    try fixture.journal.beginUndo(1);
    try fixture.journal.transition(undone, .undoing, .rolled_back, null);

    const written = try committedWrite(&fixture, 2, 0);
    try fixture.journal.transition(written, .committed, .undoing, null);
    try fixture.journal.transition(written, .undoing, .rolled_back, null);
    const broken = try prepareWrite(&fixture, 2, 1);
    try fixture.journal.transition(broken, .planned, .failed, "AccessDenied");
    try fixture.journal.rollBackFailed(broken);

    const interrupted = try prepareWrite(&fixture, 3, 0);
    try fixture.journal.transition(interrupted, .planned, .failed, recovered_message);
    try fixture.journal.transition(interrupted, .failed, .rolled_back, recovered_message);

    const reconciled = try committedWrite(&fixture, 4, 0);
    try fixture.journal.transition(reconciled, .committed, .needs_reconciliation, "group undo target changed externally");

    const pruned = try committedWrite(&fixture, 5, 0);
    _ = try committedWrite(&fixture, 5, 1);
    try fixture.journal.clearBackupPath(pruned);

    const halfway = try committedWrite(&fixture, 6, 0);
    _ = try committedWrite(&fixture, 6, 1);
    try fixture.journal.beginUndo(6);
    try fixture.journal.transition(halfway, .undoing, .rolled_back, null);

    const page = try fixture.journal.groupSummaryPage(std.testing.allocator, max_page, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 6), page.items.len);
    const expected = [_]struct { MutationGroupState, UndoAvailability }{
        .{ .undoing, .interrupted },
        .{ .applied, .backups_pruned },
        .{ .needs_reconciliation, .needs_reconciliation },
        .{ .rolled_back, .already_undone },
        .{ .failed, .already_undone },
        .{ .undone, .already_undone },
    };
    for (page.items, expected) |item, want| {
        try std.testing.expectEqual(want[0], item.state());
        try std.testing.expectEqual(want[1], item.undo());
    }
}

test "the journal keeps content hashes, reads a journal from before them, and refuses a malformed one" {
    var fixture: JournalFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const hashed = try fixture.journal.prepare(.{
        .plan_id = 1,
        .group_id = 1,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = "/music/a.flac",
        .expected_size = 1,
        .expected_modified_ns = 1,
        .expected_quick_hash = @splat(1),
        .expected_content_hash = @splat(3),
    });
    try fixture.journal.recordResultIdentity(hashed, .planned, 2, 2, @splat(2), @splat(5));
    try fixture.journal.transition(hashed, .planned, .staged, null);
    try fixture.journal.commit(hashed, 2, 2, @splat(2), @splat(4));
    const legacy = try fixture.prepare(2, 0);

    var operation = try fixture.journal.get(std.testing.allocator, hashed);
    try std.testing.expectEqualSlices(u8, &@as(content_hash.Digest, @splat(3)), &operation.expected_content_hash.?);
    try std.testing.expectEqualSlices(u8, &@as(content_hash.Digest, @splat(4)), &operation.committed_content_hash.?);
    operation.deinit();
    operation = try fixture.journal.get(std.testing.allocator, legacy);
    try std.testing.expect(operation.expected_content_hash == null);
    try std.testing.expect(operation.committed_content_hash == null);
    operation.deinit();

    try fixture.db.exec("UPDATE mutation_operations SET expected_content_hash = X'0102' WHERE plan_id = 1;");
    try std.testing.expectError(error.InvalidStoredContentHash, fixture.journal.get(std.testing.allocator, hashed));

    try fixture.db.exec(
        \\ALTER TABLE mutation_operations DROP COLUMN expected_content_hash;
        \\ALTER TABLE mutation_operations DROP COLUMN committed_content_hash;
    );
    operation = try fixture.journal.get(std.testing.allocator, hashed);
    defer operation.deinit();
    try std.testing.expect(operation.expected_content_hash == null);
    try std.testing.expect(operation.committed_content_hash == null);
    try std.testing.expectEqualSlices(u8, &@as(quick_hash.Digest, @splat(2)), &operation.committed_quick_hash.?);
}
