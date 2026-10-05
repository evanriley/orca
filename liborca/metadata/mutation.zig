const std = @import("std");
const model = @import("model.zig");
const content_hash = @import("../storage/content_hash.zig");
const quick_hash = @import("../storage/quick_hash.zig");

/// What a file must currently be for a planned mutation to remain valid.
///
/// Size and modification time alone are forgeable by any editor that rewrites
/// a file in place and restores its timestamp, and the storage-wide
/// `quick_hash` (BLAKE3 over first 64 KiB ‖ last 64 KiB ‖ size) misses an edit
/// confined to the middle of a larger file. Identity therefore ends in
/// `content_hash`, BLAKE3-256 over every byte; the cheaper parts are compared
/// first so a changed file is rejected without reading all of it.
///
/// The journal persists all four parts, so recovery compares the same identity
/// an in-process check does. `content_hash` is null only for an operation
/// journaled before the column existed; such an identity is compared by the
/// other three parts.
pub const FileIdentity = struct {
    size_bytes: u64,
    modified_ns: i64,
    quick_hash: quick_hash.Digest,
    content_hash: ?content_hash.Digest,

    pub fn eql(self: FileIdentity, other: FileIdentity) bool {
        if (self.size_bytes != other.size_bytes or
            self.modified_ns != other.modified_ns or
            !std.mem.eql(u8, &self.quick_hash, &other.quick_hash)) return false;
        const own = self.content_hash orelse return true;
        const theirs = other.content_hash orelse return true;
        return std.mem.eql(u8, &own, &theirs);
    }
};

pub const Field = model.Field;

pub const Change = struct {
    field: Field,
    before: ?[]const u8,
    after: ?[]const u8,
};

/// A file's whole genre list replaced. `before` is the list as the file's
/// reader returns it now, a precondition like `Change.before`; `after` is the
/// list the file will state, one genre per value.
pub const GenreChange = struct {
    before: []const []const u8,
    after: []const []const u8,
};

pub const Action = union(enum) {
    write_tags: struct {
        path: []const u8,
        expected: FileIdentity,
        changes: []const Change,
        genres: ?GenreChange = null,
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

pub const Digest = quick_hash.Digest;

/// What a caller must present to approve a plan: the plan identity *and* the
/// content digest of the exact actions that were previewed.
pub const Approval = struct {
    plan_id: u64,
    digest: Digest,
};

/// A plan is descriptive only: construction and preview have no file-system
/// side effects.
///
/// Construction deep-copies every action, path, change and value into
/// plan-owned storage and seals the copy with a content digest. Callers keep no
/// alias that can reach the executed bytes, and approval names the digest as
/// well as the ID, so a plan that was previewed under one content can never be
/// executed under another. `beginExecution` reverifies the seal.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    id: u64,
    actions: []const Action,
    sealed_digest: Digest,
    state: State = .draft,

    pub fn init(allocator: std.mem.Allocator, id: u64, actions: []const Action) !Plan {
        if (id == 0 or actions.len == 0) return error.InvalidMutationPlan;
        for (actions) |action| switch (action) {
            .write_tags => |write| {
                if (write.path.len == 0 or write.expected.content_hash == null or
                    (write.changes.len == 0 and write.genres == null))
                    return error.InvalidMutationPlan;
                if (write.genres) |genres| {
                    if (genres.after.len == 0) return error.InvalidMutationPlan;
                    for (genres.after) |genre| {
                        if (genre.len == 0 or std.mem.indexOfScalar(u8, genre, 0) != null or
                            !std.unicode.utf8ValidateSlice(genre))
                            return error.InvalidMutationPlan;
                    }
                }
                for (write.changes) |change| switch (change.field) {
                    .musicbrainz_recording_id,
                    .musicbrainz_release_id,
                    .musicbrainz_release_group_id,
                    .musicbrainz_release_track_id,
                    .musicbrainz_album_artist_id,
                    => {
                        const value = change.after orelse continue;
                        if (!model.isMusicBrainzId(value)) return error.InvalidMutationPlan;
                    },
                    .explicit => {
                        const value = change.after orelse continue;
                        if (model.Explicit.fromAdvisoryText(value) == null) return error.InvalidMutationPlan;
                    },
                    .title, .artist, .album, .track_number, .album_artist, .disc_number, .date, .compilation, .composer, .comment => {},
                };
            },
            .move => |move| {
                if (move.source_path.len == 0 or move.destination_path.len == 0 or
                    move.expected.content_hash == null or
                    std.mem.eql(u8, move.source_path, move.destination_path))
                    return error.InvalidMutationPlan;
            },
        };
        const owned = try copyActions(allocator, actions);
        errdefer freeActions(allocator, owned);
        return .{
            .allocator = allocator,
            .id = id,
            .actions = owned,
            .sealed_digest = digestOf(id, owned),
        };
    }

    pub fn deinit(self: *Plan) void {
        freeActions(self.allocator, self.actions);
        self.* = undefined;
    }

    pub fn preview(self: *const Plan) Preview {
        var result: Preview = .{ .tag_writes = 0, .moves = 0, .field_changes = 0 };
        for (self.actions) |action| switch (action) {
            .write_tags => |write| {
                result.tag_writes += 1;
                result.field_changes += write.changes.len + @intFromBool(write.genres != null);
            },
            .move => result.moves += 1,
        };
        return result;
    }

    /// The approval token for the sealed content a caller just previewed.
    pub fn approval(self: *const Plan) Approval {
        return .{ .plan_id = self.id, .digest = self.sealed_digest };
    }

    pub fn approve(self: *Plan, confirmed: Approval) !void {
        if (self.state != .draft) return error.InvalidMutationTransition;
        try self.verifySeal();
        if (confirmed.plan_id != self.id or
            !std.mem.eql(u8, &confirmed.digest, &self.sealed_digest))
            return error.MutationApprovalMismatch;
        self.state = .approved;
    }

    pub fn beginExecution(self: *Plan) !void {
        if (self.state != .approved) return error.MutationPlanNotApproved;
        try self.verifySeal();
        self.state = .executing;
    }

    pub fn finish(self: *Plan, success: bool) !void {
        if (self.state != .executing) return error.InvalidMutationTransition;
        self.state = if (success) .completed else .failed;
    }

    fn verifySeal(self: *const Plan) !void {
        if (!std.mem.eql(u8, &digestOf(self.id, self.actions), &self.sealed_digest))
            return error.MutationPlanSealBroken;
    }
};

fn copyActions(allocator: std.mem.Allocator, actions: []const Action) ![]const Action {
    const owned = try allocator.alloc(Action, actions.len);
    var copied: usize = 0;
    errdefer {
        freeActionElements(allocator, owned[0..copied]);
        allocator.free(owned);
    }
    for (actions, owned) |source, *destination| {
        switch (source) {
            .write_tags => |write| {
                const path = try allocator.dupe(u8, write.path);
                errdefer allocator.free(path);
                const changes = try copyChanges(allocator, write.changes);
                errdefer freeChanges(allocator, changes);
                const genres: ?GenreChange = if (write.genres) |genres| try copyGenreChange(allocator, genres) else null;
                destination.* = .{ .write_tags = .{
                    .path = path,
                    .expected = write.expected,
                    .changes = changes,
                    .genres = genres,
                } };
            },
            .move => |move| {
                const source_path = try allocator.dupe(u8, move.source_path);
                errdefer allocator.free(source_path);
                const destination_path = try allocator.dupe(u8, move.destination_path);
                destination.* = .{ .move = .{
                    .source_path = source_path,
                    .destination_path = destination_path,
                    .expected = move.expected,
                } };
            },
        }
        copied += 1;
    }
    return owned;
}

fn copyChanges(allocator: std.mem.Allocator, changes: []const Change) ![]const Change {
    const owned = try allocator.alloc(Change, changes.len);
    var copied: usize = 0;
    errdefer {
        freeChangeElements(allocator, owned[0..copied]);
        allocator.free(owned);
    }
    for (changes, owned) |source, *destination| {
        const before = if (source.before) |value| try allocator.dupe(u8, value) else null;
        errdefer if (before) |value| allocator.free(value);
        const after = if (source.after) |value| try allocator.dupe(u8, value) else null;
        destination.* = .{ .field = source.field, .before = before, .after = after };
        copied += 1;
    }
    return owned;
}

fn copyGenreChange(allocator: std.mem.Allocator, genres: GenreChange) !GenreChange {
    const before = try copyValues(allocator, genres.before);
    errdefer freeValues(allocator, before);
    return .{ .before = before, .after = try copyValues(allocator, genres.after) };
}

fn copyValues(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, values.len);
    var copied: usize = 0;
    errdefer {
        for (owned[0..copied]) |value| allocator.free(value);
        allocator.free(owned);
    }
    for (values, owned) |source, *destination| {
        destination.* = try allocator.dupe(u8, source);
        copied += 1;
    }
    return owned;
}

fn freeValues(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeChangeElements(allocator: std.mem.Allocator, changes: []const Change) void {
    for (changes) |change| {
        if (change.before) |value| allocator.free(value);
        if (change.after) |value| allocator.free(value);
    }
}

fn freeChanges(allocator: std.mem.Allocator, changes: []const Change) void {
    freeChangeElements(allocator, changes);
    allocator.free(changes);
}

fn freeActionElements(allocator: std.mem.Allocator, actions: []const Action) void {
    for (actions) |action| switch (action) {
        .write_tags => |write| {
            allocator.free(write.path);
            freeChanges(allocator, write.changes);
            if (write.genres) |genres| {
                freeValues(allocator, genres.before);
                freeValues(allocator, genres.after);
            }
        },
        .move => |move| {
            allocator.free(move.source_path);
            allocator.free(move.destination_path);
        },
    };
}

fn freeActions(allocator: std.mem.Allocator, actions: []const Action) void {
    freeActionElements(allocator, actions);
    allocator.free(actions);
}

fn digestOf(id: u64, actions: []const Action) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("orca.mutation.plan.v1");
    updateInt(&hasher, id);
    updateInt(&hasher, actions.len);
    for (actions) |action| switch (action) {
        .write_tags => |write| {
            hasher.update(&.{0});
            updateBytes(&hasher, write.path);
            updateIdentity(&hasher, write.expected);
            updateInt(&hasher, write.changes.len);
            for (write.changes) |change| {
                updateInt(&hasher, @backingInt(change.field));
                updateOptionalBytes(&hasher, change.before);
                updateOptionalBytes(&hasher, change.after);
            }
            if (write.genres) |genres| {
                hasher.update("genres");
                updateValues(&hasher, genres.before);
                updateValues(&hasher, genres.after);
            }
        },
        .move => |move| {
            hasher.update(&.{1});
            updateBytes(&hasher, move.source_path);
            updateBytes(&hasher, move.destination_path);
            updateIdentity(&hasher, move.expected);
        },
    };
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn updateInt(hasher: *std.crypto.hash.Blake3, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hasher.update(&bytes);
}

fn updateBytes(hasher: *std.crypto.hash.Blake3, value: []const u8) void {
    updateInt(hasher, value.len);
    hasher.update(value);
}

fn updateOptionalBytes(hasher: *std.crypto.hash.Blake3, value: ?[]const u8) void {
    hasher.update(&.{if (value == null) 0 else 1});
    updateBytes(hasher, value orelse "");
}

fn updateValues(hasher: *std.crypto.hash.Blake3, values: []const []const u8) void {
    updateInt(hasher, values.len);
    for (values) |value| updateBytes(hasher, value);
}

fn updateIdentity(hasher: *std.crypto.hash.Blake3, value: FileIdentity) void {
    updateInt(hasher, value.size_bytes);
    var modified: [8]u8 = undefined;
    std.mem.writeInt(i64, &modified, value.modified_ns, .little);
    hasher.update(&modified);
    hasher.update(&value.quick_hash);
    hasher.update(&.{if (value.content_hash == null) 0 else 1});
    const content: content_hash.Digest = value.content_hash orelse @splat(0);
    hasher.update(&content);
}

test "mutation preview is inert and execution requires exact approval" {
    const actions = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{.{ .field = .title, .before = "Old", .after = "New" }},
    } }};
    var plan = try Plan.init(std.testing.allocator, 42, &actions);
    defer plan.deinit();
    const preview = plan.preview();
    try std.testing.expectEqual(@as(usize, 1), preview.tag_writes);
    try std.testing.expectEqual(@as(usize, 1), preview.field_changes);
    try std.testing.expectError(error.MutationPlanNotApproved, plan.beginExecution());
    try std.testing.expectError(error.MutationApprovalMismatch, plan.approve(.{
        .plan_id = 41,
        .digest = plan.sealed_digest,
    }));
    try plan.approve(plan.approval());
    try plan.beginExecution();
    try plan.finish(true);
    try std.testing.expectEqual(State.completed, plan.state);
}

test "a plan writes a recording id only when it is a MusicBrainz id" {
    const valid = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{.{ .field = .musicbrainz_recording_id, .before = null, .after = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a" }},
    } }};
    var plan = try Plan.init(std.testing.allocator, 42, &valid);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.preview().field_changes);

    const uppercase = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{.{ .field = .musicbrainz_recording_id, .before = null, .after = "8F3471B5-7E6A-48DA-86A9-C1C07A0F5B4A" }},
    } }};
    try std.testing.expectError(error.InvalidMutationPlan, Plan.init(std.testing.allocator, 42, &uppercase));
}

test "a plan writes a release, release-group, release-track or album-artist id only when it is a MusicBrainz id" {
    for ([_]Field{
        .musicbrainz_release_id,
        .musicbrainz_release_group_id,
        .musicbrainz_release_track_id,
        .musicbrainz_album_artist_id,
    }) |field| {
        const valid = [_]Action{.{ .write_tags = .{
            .path = "/music/example.flac",
            .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
            .changes = &.{.{ .field = field, .before = null, .after = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a" }},
        } }};
        var plan = try Plan.init(std.testing.allocator, 42, &valid);
        plan.deinit();

        const invalid = [_]Action{.{ .write_tags = .{
            .path = "/music/example.flac",
            .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
            .changes = &.{.{ .field = field, .before = null, .after = "Some Album" }},
        } }};
        try std.testing.expectError(error.InvalidMutationPlan, Plan.init(std.testing.allocator, 42, &invalid));
    }
}

test "an approved plan cannot be altered through a caller-held alias" {
    var path_buffer = "/music/original.mp3".*;
    var title_buffer = "Approved title".*;
    var actions = [_]Action{.{ .write_tags = .{
        .path = &path_buffer,
        .expected = .{ .size_bytes = 10, .modified_ns = 20, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{.{ .field = .title, .before = null, .after = &title_buffer }},
    } }};
    var plan = try Plan.init(std.testing.allocator, 7, &actions);
    defer plan.deinit();
    const approval = plan.approval();
    try plan.approve(approval);

    // Every alias the caller still holds is rewritten after approval.
    @memcpy(&path_buffer, "/music/attacker.mp3");
    @memcpy(&title_buffer, "Attacker title");
    actions[0] = .{ .move = .{
        .source_path = "/music/original.mp3",
        .destination_path = "/music/attacker.mp3",
        .expected = .{ .size_bytes = 10, .modified_ns = 20, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
    } };

    try plan.beginExecution();
    try std.testing.expectEqual(@as(usize, 1), plan.preview().tag_writes);
    try std.testing.expectEqualStrings("/music/original.mp3", plan.actions[0].write_tags.path);
    try std.testing.expectEqualStrings(
        "Approved title",
        plan.actions[0].write_tags.changes[0].after.?,
    );
    try std.testing.expectEqualSlices(u8, &approval.digest, &plan.sealed_digest);
}

test "approval digests separate plans that differ only in a single value" {
    const first = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{.{ .field = .title, .before = "Old", .after = "New" }},
    } }};
    const second = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{.{ .field = .title, .before = "Old", .after = "Different" }},
    } }};
    var first_plan = try Plan.init(std.testing.allocator, 5, &first);
    defer first_plan.deinit();
    var second_plan = try Plan.init(std.testing.allocator, 5, &second);
    defer second_plan.deinit();
    try std.testing.expect(!std.mem.eql(
        u8,
        &first_plan.sealed_digest,
        &second_plan.sealed_digest,
    ));
    try std.testing.expectError(
        error.MutationApprovalMismatch,
        second_plan.approve(first_plan.approval()),
    );
}

test "a genre list alone is a tag write, sealed into the digest and copied away from the caller" {
    var genre_buffer = "Shoegaze".*;
    const genres_only = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{},
        .genres = .{ .before = &.{"Rock, Pop"}, .after = &.{ &genre_buffer, "Dream Pop" } },
    } }};
    var plan = try Plan.init(std.testing.allocator, 9, &genres_only);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.preview().field_changes);
    @memcpy(&genre_buffer, "Attacker");
    try std.testing.expectEqualStrings("Shoegaze", plan.actions[0].write_tags.genres.?.after[0]);

    const reordered = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
        .changes = &.{},
        .genres = .{ .before = &.{"Rock, Pop"}, .after = &.{ "Dream Pop", "Shoegaze" } },
    } }};
    var reordered_plan = try Plan.init(std.testing.allocator, 9, &reordered);
    defer reordered_plan.deinit();
    try std.testing.expectError(error.MutationApprovalMismatch, reordered_plan.approve(plan.approval()));
    try plan.approve(plan.approval());
}

test "a genre write refuses an empty list, a blank genre or one containing NUL" {
    for ([_][]const []const u8{ &.{}, &.{""}, &.{ "Rock", "Po\x00p" } }) |after| {
        const actions = [_]Action{.{ .write_tags = .{
            .path = "/music/example.flac",
            .expected = .{ .size_bytes = 100, .modified_ns = 200, .quick_hash = quick_hash.zero, .content_hash = @splat(0) },
            .changes = &.{},
            .genres = .{ .before = &.{}, .after = after },
        } }};
        try std.testing.expectError(error.InvalidMutationPlan, Plan.init(std.testing.allocator, 9, &actions));
    }
}

test "file identity separates same-size edits that preserve a timestamp" {
    const base: FileIdentity = .{
        .size_bytes = 4096,
        .modified_ns = 1234,
        .quick_hash = quick_hash.zero,
        .content_hash = @splat(0),
    };
    var edited = base;
    edited.quick_hash[0] = 1;
    // Same size, same timestamp, different bytes: only the quick hash separates
    // them, and the journal stores it so recovery can tell them apart too.
    try std.testing.expect(!base.eql(edited));

    var middle = base;
    middle.content_hash.?[0] = 1;
    try std.testing.expect(!base.eql(middle));

    var legacy = middle;
    legacy.content_hash = null;
    try std.testing.expect(base.eql(legacy));
    try std.testing.expect(legacy.eql(base));
}

test "approval digests separate identities that differ only in content hash" {
    var identity: FileIdentity = .{
        .size_bytes = 100,
        .modified_ns = 200,
        .quick_hash = quick_hash.zero,
        .content_hash = @splat(0),
    };
    const first = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = identity,
        .changes = &.{.{ .field = .title, .before = "Old", .after = "New" }},
    } }};
    identity.content_hash.?[31] = 1;
    const second = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = identity,
        .changes = &.{.{ .field = .title, .before = "Old", .after = "New" }},
    } }};
    var first_plan = try Plan.init(std.testing.allocator, 5, &first);
    defer first_plan.deinit();
    var second_plan = try Plan.init(std.testing.allocator, 5, &second);
    defer second_plan.deinit();
    try std.testing.expectError(
        error.MutationApprovalMismatch,
        second_plan.approve(first_plan.approval()),
    );
}

test "a plan refuses a file identity without a content hash" {
    const identity: FileIdentity = .{
        .size_bytes = 100,
        .modified_ns = 200,
        .quick_hash = quick_hash.zero,
        .content_hash = null,
    };
    const write = [_]Action{.{ .write_tags = .{
        .path = "/music/example.flac",
        .expected = identity,
        .changes = &.{.{ .field = .title, .before = "Old", .after = "New" }},
    } }};
    try std.testing.expectError(error.InvalidMutationPlan, Plan.init(std.testing.allocator, 5, &write));
    const move = [_]Action{.{ .move = .{
        .source_path = "/music/a.flac",
        .destination_path = "/music/b.flac",
        .expected = identity,
    } }};
    try std.testing.expectError(error.InvalidMutationPlan, Plan.init(std.testing.allocator, 5, &move));
}
