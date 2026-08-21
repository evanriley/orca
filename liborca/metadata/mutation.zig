const std = @import("std");

pub const FileIdentity = struct {
    size_bytes: u64,
    modified_ns: i64,
};

pub const Field = enum {
    title,
    artist,
    album,
    track_number,
};

pub const Change = struct {
    field: Field,
    before: ?[]const u8,
    after: ?[]const u8,
};

pub const Action = union(enum) {
    write_tags: struct {
        path: []const u8,
        expected: FileIdentity,
        changes: []const Change,
    },
    move: struct {
        source_path: []const u8,
        destination_path: []const u8,
        expected: FileIdentity,
    },
};

pub const State = enum {
    draft,
    approved,
    executing,
    completed,
    failed,
};

pub const Preview = struct {
    tag_writes: usize,
    moves: usize,
    field_changes: usize,
};

/// A plan is descriptive only: construction and preview have no file-system
/// side effects. Executors must call beginExecution, which is impossible until
/// the caller explicitly approves this exact plan ID.
pub const Plan = struct {
    id: u64,
    actions: []const Action,
    state: State = .draft,

    pub fn init(id: u64, actions: []const Action) !Plan {
        if (id == 0 or actions.len == 0) return error.InvalidMutationPlan;
        for (actions) |action| switch (action) {
            .write_tags => |write| {
                if (write.path.len == 0 or write.changes.len == 0)
                    return error.InvalidMutationPlan;
            },
            .move => |move| {
                if (move.source_path.len == 0 or move.destination_path.len == 0 or
                    std.mem.eql(u8, move.source_path, move.destination_path))
                    return error.InvalidMutationPlan;
            },
        };
        return .{ .id = id, .actions = actions };
    }

    pub fn preview(self: *const Plan) Preview {
        var result: Preview = .{ .tag_writes = 0, .moves = 0, .field_changes = 0 };
        for (self.actions) |action| switch (action) {
            .write_tags => |write| {
                result.tag_writes += 1;
                result.field_changes += write.changes.len;
            },
            .move => result.moves += 1,
        };
        return result;
    }

    pub fn approve(self: *Plan, confirmed_plan_id: u64) !void {
        if (self.state != .draft) return error.InvalidMutationTransition;
        if (confirmed_plan_id != self.id) return error.MutationApprovalMismatch;
        self.state = .approved;
    }

    pub fn beginExecution(self: *Plan) !void {
        if (self.state != .approved) return error.MutationPlanNotApproved;
        self.state = .executing;
    }

    pub fn finish(self: *Plan, success: bool) !void {
        if (self.state != .executing) return error.InvalidMutationTransition;
        self.state = if (success) .completed else .failed;
    }
};

test "mutation preview is inert and execution requires exact approval" {
    const actions = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200 },
        .changes = &.{.{ .field = .title, .before = "Old", .after = "New" }},
    } }};
    var plan = try Plan.init(42, &actions);
    const preview = plan.preview();
    try std.testing.expectEqual(@as(usize, 1), preview.tag_writes);
    try std.testing.expectEqual(@as(usize, 1), preview.field_changes);
    try std.testing.expectError(error.MutationPlanNotApproved, plan.beginExecution());
    try std.testing.expectError(error.MutationApprovalMismatch, plan.approve(41));
    try plan.approve(42);
    try plan.beginExecution();
    try plan.finish(true);
    try std.testing.expectEqual(State.completed, plan.state);
}
