const std = @import("std");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");
const job = @import("job.zig");
const runtime_roots = @import("runtime_roots.zig");

const MutationGroupSummary = database.repository.MutationGroupSummary;

pub const max_diff_rows = database.repository.max_page;

pub const TagWriteGroupState = database.repository.MutationGroupState;

pub const TagWriteGroup = struct {
    group_id: u64,
    written_at: i64,
    file_count: u64,
    state: TagWriteGroupState,
    can_undo: bool,
    expired: bool,
    title: job.BoundedText(256),

    pub fn fromSummary(summary: MutationGroupSummary) TagWriteGroup {
        const undo = summary.undo();
        return .{
            .group_id = summary.group_id,
            .written_at = summary.written_at,
            .file_count = summary.operations,
            .state = summary.state(),
            .can_undo = undo == .fresh or undo == .interrupted,
            .expired = undo == .backups_pruned,
            .title = .init(summary.title orelse ""),
        };
    }

    pub fn writeLine(self: *const TagWriteGroup, writer: *std.Io.Writer, shown: ?*const TagWriteGroupDetail) std.Io.Writer.Error!void {
        try writer.print("group={d} written_at={d} files={d} state={t} can_undo={s} expired={s}", .{
            self.group_id,
            self.written_at,
            self.file_count,
            self.state,
            if (self.can_undo) "yes" else "no",
            if (self.expired) "yes" else "no",
        });
        if (shown) |group_detail| try writer.print(" fields={d} more_files={d}", .{ group_detail.field_count, group_detail.more_files });
        try writer.print(" title={s}", .{self.title.slice()});
    }
};

pub const TagWriteGroupPage = struct {
    allocator: std.mem.Allocator,
    items: []TagWriteGroup,

    pub fn deinit(self: TagWriteGroupPage) void {
        self.allocator.free(self.items);
    }
};

pub const TagWriteDiffSubject = union(enum) {
    field: metadata.Field,
    genres,
    unknown,
};

pub const TagWriteDiff = struct {
    file: []const u8,
    subject: TagWriteDiffSubject,
    restores: []const u8,
    current: []const u8,
};

pub const TagWriteGroupDetail = struct {
    arena: *std.heap.ArenaAllocator,
    group: TagWriteGroup,
    diffs: []const TagWriteDiff,
    more_files: u64,
    field_count: u64,

    pub fn deinit(self: TagWriteGroupDetail) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub fn page(
    library_database: *database.LibraryDatabase,
    allocator: std.mem.Allocator,
    limit: u32,
    offset: u32,
) !TagWriteGroupPage {
    const summaries = try library_database.mutation_journal.groupSummaryPage(allocator, limit, offset);
    defer summaries.deinit();
    const items = try allocator.alloc(TagWriteGroup, summaries.items.len);
    for (items, summaries.items) |*item, summary| item.* = .fromSummary(summary);
    return .{ .allocator = allocator, .items = items };
}

pub const TagWriteHistoryExportOptions = struct {
    replace: bool = false,
};

pub const TagWriteHistoryExport = struct {
    groups: u64,
};

pub fn exportHistory(
    library_database: *database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: TagWriteHistoryExportOptions,
) !TagWriteHistoryExport {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = options.replace });
    defer file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.file.writer(io, &buffer);
    const writer = &file_writer.interface;
    var exported: u64 = 0;
    while (true) {
        const groups = try page(library_database, allocator, max_diff_rows, @intCast(exported));
        defer groups.deinit();
        for (groups.items) |*group| {
            try group.writeLine(writer, null);
            try writer.writeByte('\n');
        }
        exported += groups.items.len;
        if (groups.items.len < max_diff_rows) break;
    }
    try writer.flush();
    try file.file.sync(io);
    if (options.replace) try file.replace(io) else try file.link(io);
    return .{ .groups = exported };
}

pub fn detail(
    library_database: *database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    group_id: u64,
) !TagWriteGroupDetail {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    var result: TagWriteGroupDetail = .{
        .arena = arena,
        .group = undefined,
        .diffs = &.{},
        .more_files = 0,
        .field_count = 0,
    };
    errdefer result.deinit();
    const owned = arena.allocator();

    const summary = try library_database.mutation_journal.groupSummary(allocator, group_id) orelse
        return error.UnknownTagWriteGroup;
    defer summary.deinit(allocator);
    result.group = .fromSummary(summary);

    const operation_ids = try library_database.mutation_journal.groupOperationIds(allocator, group_id);
    defer allocator.free(operation_ids);

    var diffs: std.ArrayList(TagWriteDiff) = .empty;
    var index = operation_ids.len;
    while (index > 0) {
        index -= 1;
        const operation = try library_database.mutation_journal.get(allocator, operation_ids[index]);
        defer operation.deinit();
        if (operation.kind != .write_tags) continue;

        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        var file_diffs: std.ArrayList(TagWriteDiff) = .empty;
        const field_count = try diffFile(scratch.allocator(), io, operation, &file_diffs);
        result.field_count += field_count;

        if (file_diffs.items.len == 0) continue;
        if (result.more_files > 0 or diffs.items.len + file_diffs.items.len > max_diff_rows) {
            result.more_files += 1;
            continue;
        }
        const file = try owned.dupe(u8, operation.source_path);
        for (file_diffs.items) |row| try diffs.append(owned, .{
            .file = file,
            .subject = row.subject,
            .restores = try owned.dupe(u8, row.restores),
            .current = try owned.dupe(u8, row.current),
        });
    }
    result.diffs = diffs.items;
    return result;
}

fn diffFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: database.repository.MutationOperation,
    rows: *std.ArrayList(TagWriteDiff),
) !u64 {
    const backup = if (operation.backup_path) |path| try readTags(allocator, io, path) else null;
    const current = try readTags(allocator, io, operation.source_path);
    const before = backup orelse return unknownFile(allocator, rows);
    const after = current orelse return unknownFile(allocator, rows);

    var count: u64 = 0;
    for (std.enums.values(metadata.Field)) |field| {
        const restores = try fieldText(allocator, before.values, field);
        const now = try fieldText(allocator, after.values, field);
        if (std.mem.eql(u8, restores, now)) continue;
        count += 1;
        try rows.append(allocator, .{ .file = "", .subject = .{ .field = field }, .restores = restores, .current = now });
    }
    const restores = try std.mem.join(allocator, "; ", before.values.genres);
    const now = try std.mem.join(allocator, "; ", after.values.genres);
    if (!std.mem.eql(u8, restores, now)) {
        count += 1;
        try rows.append(allocator, .{ .file = "", .subject = .genres, .restores = restores, .current = now });
    }
    return count;
}

fn unknownFile(allocator: std.mem.Allocator, rows: *std.ArrayList(TagWriteDiff)) !u64 {
    try rows.append(allocator, .{ .file = "", .subject = .unknown, .restores = "", .current = "" });
    return 0;
}

fn readTags(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?library_pass.tag_reader.Tags {
    var file = storage.LocalFileSource.open(io, path) catch return null;
    defer file.close();
    const detection = (storage.format.detect(file.readable()) catch return null) orelse return null;
    var tag_view: storage.OffsetSource = .{ .inner = file.readable(), .offset = detection.payload_offset };
    const source = if (detection.payload_offset == 0) file.readable() else tag_view.readable();
    return library_pass.tag_reader.read(allocator, detection.format, source) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => null,
    };
}

fn fieldText(allocator: std.mem.Allocator, tags: metadata.ObservedTags, field: metadata.Field) ![]const u8 {
    return try runtime_roots.observedText(allocator, tags, field) orelse "";
}

const runtime_module = @import("runtime.zig");
const runtime_tests = @import("runtime_tests.zig");

fn expectDiffsMatchPreview(detail_view: TagWriteGroupDetail, preview: runtime_module.TagWritePlan) !void {
    var expected: usize = 0;
    for (preview.files) |file| {
        for (file.changes) |change| {
            expected += 1;
            const row = findRow(detail_view.diffs, file.path, .{ .field = change.field }) orelse return error.TestExpectedEqual;
            try std.testing.expectEqualStrings(change.before orelse "", row.restores);
            try std.testing.expectEqualStrings(change.after orelse "", row.current);
        }
        if (file.genres != null) expected += 1;
    }
    try std.testing.expectEqual(expected, detail_view.diffs.len);
    try std.testing.expectEqual(@as(u64, expected), detail_view.field_count);
    try std.testing.expectEqual(@as(u64, 0), detail_view.more_files);
}

fn findRow(rows: []const TagWriteDiff, file: []const u8, subject: TagWriteDiffSubject) ?TagWriteDiff {
    for (rows) |row| {
        if (std.mem.eql(u8, row.file, file) and std.meta.eql(row.subject, subject)) return row;
    }
    return null;
}

fn writeAlbum(runtime: *runtime_module.OrcaRuntime, library: runtime_module.LibraryHandle, album: []const u8) !runtime_module.TagWritePlan {
    const ids = try runtime_tests.allTrackIds(runtime, library);
    defer std.testing.allocator.free(ids);
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = album }})).deinit();
    const edited = try runtime_tests.allTrackIds(runtime, library);
    defer std.testing.allocator.free(edited);
    const preview = try runtime.planTagWrite(library, std.testing.io, edited);
    errdefer preview.deinit();
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    return preview;
}

test "the change history shows a tag write against its backup and offers undo exactly when the undo would run" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = runtime_module.OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime_tests.scannedTempLibrary(&runtime, &temporary, database_path);

    const first = try writeAlbum(&runtime, library, "History Album");
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.files.len);
    {
        const groups = try runtime.libraryTagWriteGroupPage(library, std.testing.allocator, 512, 0);
        defer groups.deinit();
        try std.testing.expectEqual(@as(usize, 1), groups.items.len);
        const group = groups.items[0];
        try std.testing.expectEqual(first.plan_id, group.group_id);
        try std.testing.expectEqual(@as(u64, 2), group.file_count);
        try std.testing.expectEqual(TagWriteGroupState.applied, group.state);
        try std.testing.expect(group.can_undo and !group.expired);
        try std.testing.expect(group.written_at > 0);
        try std.testing.expectEqualStrings("History Album", group.title.slice());

        const written = try runtime.libraryTagWriteGroup(library, std.testing.allocator, std.testing.io, first.plan_id);
        defer written.deinit();
        try std.testing.expectEqual(first.plan_id, written.group.group_id);
        try expectDiffsMatchPreview(written, first);
    }

    try runtime.undoTagWrite(library, std.testing.io, first.plan_id);
    {
        const groups = try runtime.libraryTagWriteGroupPage(library, std.testing.allocator, 512, 0);
        defer groups.deinit();
        try std.testing.expectEqual(TagWriteGroupState.undone, groups.items[0].state);
        try std.testing.expect(!groups.items[0].can_undo and !groups.items[0].expired);
        try std.testing.expectError(error.MutationGroupAlreadyUndone, runtime.undoTagWrite(library, std.testing.io, first.plan_id));

        const undone = try runtime.libraryTagWriteGroup(library, std.testing.allocator, std.testing.io, first.plan_id);
        defer undone.deinit();
        try std.testing.expectEqual(@as(u64, 0), undone.field_count);
        try std.testing.expectEqual(@as(usize, 2), undone.diffs.len);
        for (undone.diffs) |row| try std.testing.expectEqual(TagWriteDiffSubject.unknown, row.subject);
    }

    const second = try writeAlbum(&runtime, library, "Second Album");
    defer second.deinit();
    try std.testing.expect(second.plan_id > first.plan_id);
    try std.testing.expect((try runtime.pruneTagWriteBackups(library, std.testing.io, 0)).backups > 0);
    {
        const groups = try runtime.libraryTagWriteGroupPage(library, std.testing.allocator, 512, 0);
        defer groups.deinit();
        try std.testing.expectEqual(@as(usize, 2), groups.items.len);
        const newest = groups.items[0];
        try std.testing.expectEqual(second.plan_id, newest.group_id);
        try std.testing.expectEqual(TagWriteGroupState.applied, newest.state);
        try std.testing.expect(!newest.can_undo and newest.expired);
        try std.testing.expectError(error.TagWriteBackupPruned, runtime.undoTagWrite(library, std.testing.io, second.plan_id));

        const pruned = try runtime.libraryTagWriteGroup(library, std.testing.allocator, std.testing.io, second.plan_id);
        defer pruned.deinit();
        try std.testing.expectEqual(@as(u64, 0), pruned.field_count);
        for (pruned.diffs) |row| {
            try std.testing.expectEqual(TagWriteDiffSubject.unknown, row.subject);
            try std.testing.expectEqualStrings("", row.restores);
        }
    }
    try std.testing.expectError(error.UnknownTagWriteGroup, runtime.libraryTagWriteGroup(library, std.testing.allocator, std.testing.io, second.plan_id + 1));
}

test "a group's detail keeps at most a page of rows, whole files only, and still counts every changed field" {
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = runtime_module.OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, database_path);
    const library_database = try runtime_module.libraryDatabase(&runtime, library);

    const files: u64 = 600;
    for (0..files) |index| {
        const operation = try library_database.mutation_journal.prepare(.{
            .plan_id = 7,
            .group_id = 7,
            .action_index = @intCast(index),
            .kind = .write_tags,
            .source_path = "fixtures/audio/covered-reference.mp3",
            .backup_path = "fixtures/audio/tagged-reference.flac",
            .expected_size = 1,
            .expected_modified_ns = 1,
            .expected_quick_hash = @splat(1),
        });
        try library_database.mutation_journal.transition(operation, .planned, .staged, null);
        try library_database.mutation_journal.commit(operation, 2, 2, @splat(2));
    }

    const bounded = try runtime.libraryTagWriteGroup(library, std.testing.allocator, std.testing.io, 7);
    defer bounded.deinit();
    const per_file = bounded.field_count / files;
    try std.testing.expect(per_file > 0);
    try std.testing.expectEqual(per_file * files, bounded.field_count);
    const shown_files = max_diff_rows / per_file;
    try std.testing.expectEqual(shown_files * per_file, bounded.diffs.len);
    try std.testing.expectEqual(files - shown_files, bounded.more_files);
}

test "exporting the change history writes every group's line and replaces an existing file only when asked" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = runtime_module.OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime_tests.scannedTempLibrary(&runtime, &temporary, database_path);

    const first = try writeAlbum(&runtime, library, "Exported Album");
    defer first.deinit();
    const second = try writeAlbum(&runtime, library, "Exported Again");
    defer second.deinit();

    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    {
        const groups = try runtime.libraryTagWriteGroupPage(library, std.testing.allocator, 512, 0);
        defer groups.deinit();
        try std.testing.expectEqual(@as(usize, 2), groups.items.len);
        for (groups.items) |*group| {
            try group.writeLine(&expected.writer, null);
            try expected.writer.writeByte('\n');
        }
    }

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/changes.txt", .{data.sub_path});
    defer std.testing.allocator.free(path);
    try data.dir.writeFile(std.testing.io, .{ .sub_path = "changes.txt", .data = "kept" });

    try std.testing.expectError(error.PathAlreadyExists, runtime.exportTagWriteHistory(library, std.testing.io, path, .{}));
    const kept = try data.dir.readFileAlloc(std.testing.io, "changes.txt", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("kept", kept);

    const exported = try runtime.exportTagWriteHistory(library, std.testing.io, path, .{ .replace = true });
    try std.testing.expectEqual(@as(u64, 2), exported.groups);
    const written = try data.dir.readFileAlloc(std.testing.io, "changes.txt", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(expected.written(), written);
    try std.testing.expect(std.mem.indexOf(u8, written, "title=Exported Again\n") != null);

    try data.dir.deleteFile(std.testing.io, "changes.txt");
    try std.testing.expectEqual(@as(u64, 2), (try runtime.exportTagWriteHistory(library, std.testing.io, path, .{})).groups);
}
