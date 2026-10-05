const std = @import("std");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const job = @import("job.zig");
const runtime = @import("runtime.zig");
const runtime_roots = @import("runtime_roots.zig");

const consistency_pass = library_pass.consistency_pass;
const genre_alias = metadata.genre_alias;
const max_page = database.repository.max_page;

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;

pub const IssueCategory = consistency_pass.Category;
pub const IssueState = consistency_pass.State;
pub const IssueField = consistency_pass.Field;

pub const IssueOption = struct {
    id: u32,
    value: []const u8,
    support: job.BoundedText(128),
    tracks: u32,
};

pub const MetadataIssueProposal = struct {
    track_id: i64,
    title: []const u8,
    current: ?[]const u8,
    proposed: []const u8,
};

pub const MetadataIssueGroup = struct {
    id: i64,
    release_id: i64,
    title: []const u8,
    artist: []const u8,
    track_count: u32,
    category: IssueCategory,
    field: IssueField,
    options: []IssueOption,
    proposals: []MetadataIssueProposal,
    gap: ?u32,
    missing: u32,
    precision: bool,
    case_only: bool,
};

pub const MetadataIssueStatus = struct {
    open: u64,
    releases: u64,
    by_category: std.EnumArray(IssueCategory, u64),
    last_pass_at: ?i64,
    stale: bool,
};

pub const MetadataIssueApplication = struct {
    group_id: i64,
    choice: MetadataIssueChoice,
    tracks: ?[]const i64 = null,
};

pub const MetadataIssuePage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []MetadataIssueGroup,

    pub fn deinit(self: MetadataIssuePage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const MetadataIssueChoice = union(enum) {
    option: u32,
    custom: []const u8,
};

pub fn libraryMetadataIssueCount(self: *OrcaRuntime, library: LibraryHandle, category: ?IssueCategory) !u64 {
    const db = (try runtime.libraryDatabase(self, library)).database;
    var statement = try db.prepare(if (category == null)
        "SELECT count(*) FROM metadata_proposals WHERE id = group_id AND state = 0;"
    else
        "SELECT count(*) FROM metadata_proposals WHERE id = group_id AND state = 0 AND category = ?1;");
    defer statement.deinit();
    if (category) |value| try statement.bindInt64(1, @backingInt(value));
    if (try statement.step() != .row) return error.SqlFailed;
    return @intCast(statement.columnInt64(0));
}

pub fn libraryMetadataIssueStatus(self: *OrcaRuntime, library: LibraryHandle) !MetadataIssueStatus {
    const db = (try runtime.libraryDatabase(self, library)).database;
    var status: MetadataIssueStatus = .{
        .open = 0,
        .releases = 0,
        .by_category = .initFill(0),
        .last_pass_at = null,
        .stale = true,
    };
    {
        var statement = try db.prepare(
            \\SELECT category, count(*) FROM metadata_proposals
            \\WHERE id = group_id AND state = 0 GROUP BY category;
        );
        defer statement.deinit();
        while (try statement.step() == .row) {
            const count: u64 = @intCast(statement.columnInt64(1));
            status.by_category.set(try categoryFrom(statement.columnInt64(0)), count);
            status.open += count;
        }
    }
    var statement = try db.prepare(
        \\SELECT (SELECT count(DISTINCT release_id) FROM metadata_proposals WHERE id = group_id AND state = 0),
        \\    (SELECT max(finished_at) FROM job_history WHERE kind = 'consistency' AND state = 'succeeded'),
        \\    (SELECT max(finished_at) FROM scan_runs WHERE state = 'completed' AND changed != 0);
    );
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    status.releases = @intCast(statement.columnInt64(0));
    if (!statement.columnIsNull(1)) {
        const finished = statement.columnInt64(1);
        status.last_pass_at = finished;
        status.stale = !statement.columnIsNull(2) and statement.columnInt64(2) > finished;
    }
    return status;
}

const page_columns =
    \\SELECT h.id, h.release_id, r.title, r.album_artist,
    \\    (SELECT count(*) FROM tracks t WHERE t.release_id = h.release_id), h.category, h.field, h.gap
    \\FROM metadata_proposals h JOIN releases r ON r.id = h.release_id
    \\WHERE h.id = h.group_id AND h.state = 0
;

pub fn libraryMetadataIssuePage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    category: ?IssueCategory,
    limit: u32,
    offset: u32,
) !MetadataIssuePage {
    if (limit == 0 or limit > max_page) return error.PageOutOfRange;
    const db = (try runtime.libraryDatabase(self, library)).database;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    const page: MetadataIssuePage = .{ .arena = arena, .items = &.{} };
    errdefer page.deinit();
    const owned = arena.allocator();

    var groups: std.ArrayList(MetadataIssueGroup) = .empty;
    {
        var statement = try db.prepare(if (category == null)
            page_columns ++ "\nORDER BY h.category, h.release_id, h.id LIMIT ?2 OFFSET ?3;"
        else
            page_columns ++ " AND h.category = ?1\nORDER BY h.release_id, h.id LIMIT ?2 OFFSET ?3;");
        defer statement.deinit();
        if (category) |value| try statement.bindInt64(1, @backingInt(value));
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);
        while (try statement.step() == .row) try groups.append(owned, .{
            .id = statement.columnInt64(0),
            .release_id = statement.columnInt64(1),
            .title = try owned.dupe(u8, statement.columnText(2)),
            .artist = try owned.dupe(u8, statement.columnText(3)),
            .track_count = @intCast(statement.columnInt64(4)),
            .category = try categoryFrom(statement.columnInt64(5)),
            .field = std.meta.stringToEnum(IssueField, statement.columnText(6)) orelse return error.InvalidStoredIssue,
            .options = &.{},
            .proposals = &.{},
            .gap = if (statement.columnIsNull(7)) null else @intCast(statement.columnInt64(7)),
            .missing = 0,
            .precision = false,
            .case_only = false,
        });
    }

    var members = try db.prepare(
        \\SELECT m.option, m.track_id, COALESCE(t.title, ''), m.current, m.proposed, COALESCE(m.reason, ''),
        \\    COALESCE(m.tracks, 0)
        \\FROM metadata_proposals m LEFT JOIN tracks t ON t.id = m.track_id
        \\WHERE m.group_id = ?1 AND m.id <> ?1
        \\ORDER BY m.option, m.id;
    );
    defer members.deinit();
    for (groups.items) |*group| {
        var options: std.ArrayList(IssueOption) = .empty;
        var proposals: std.ArrayList(MetadataIssueProposal) = .empty;
        try members.bindInt64(1, group.id);
        while (try members.step() == .row) {
            const proposed = try owned.dupe(u8, members.columnText(4));
            if (!members.columnIsNull(0)) {
                try options.append(owned, .{
                    .id = @intCast(members.columnInt64(0)),
                    .value = proposed,
                    .support = .init(members.columnText(5)),
                    .tracks = @intCast(members.columnInt64(6)),
                });
            } else if (!members.columnIsNull(1)) {
                if (members.columnIsNull(3)) group.missing += 1;
                try proposals.append(owned, .{
                    .track_id = members.columnInt64(1),
                    .title = try owned.dupe(u8, members.columnText(2)),
                    .current = if (members.columnIsNull(3)) null else try owned.dupe(u8, members.columnText(3)),
                    .proposed = proposed,
                });
            }
        }
        try members.reset();
        group.options = options.items;
        group.proposals = proposals.items;
        group.precision = group.category == .dates and isPrecision(options.items);
        group.case_only = isCaseOnly(options.items);
    }
    return .{ .arena = arena, .items = groups.items };
}

fn isPrecision(options: []const IssueOption) bool {
    if (options.len < 2 or !consistency_pass.validDate(options[0].value)) return false;
    for (options[1..]) |option| {
        if (option.value.len >= options[0].value.len) return false;
        if (!std.mem.startsWith(u8, options[0].value, option.value)) return false;
    }
    return true;
}

fn isCaseOnly(options: []const IssueOption) bool {
    if (options.len < 2) return false;
    for (options[1..]) |option| {
        if (!std.ascii.eqlIgnoreCase(options[0].value, option.value)) return false;
    }
    return true;
}

fn categoryFrom(value: i64) !IssueCategory {
    if (value < 0 or value > std.math.maxInt(u8)) return error.InvalidStoredIssue;
    return std.enums.fromInt(IssueCategory, @as(u8, @intCast(value))) orelse error.InvalidStoredIssue;
}

const Header = struct {
    release_id: i64,
    category: IssueCategory,
    field: IssueField,
    key: []const u8,
    fingerprint: i64,
    state: IssueState,
};

fn loadHeader(allocator: std.mem.Allocator, db: database.sqlite.Database, group_id: i64) !Header {
    var statement = try db.prepare(
        \\SELECT release_id, category, field, COALESCE(current, ''), fingerprint, state
        \\FROM metadata_proposals WHERE id = ?1 AND group_id = ?1;
    );
    defer statement.deinit();
    try statement.bindInt64(1, group_id);
    if (try statement.step() != .row) return error.IssueNotFound;
    const state = statement.columnInt64(5);
    return .{
        .release_id = statement.columnInt64(0),
        .category = try categoryFrom(statement.columnInt64(1)),
        .field = std.meta.stringToEnum(IssueField, statement.columnText(2)) orelse return error.InvalidStoredIssue,
        .key = try allocator.dupe(u8, statement.columnText(3)),
        .fingerprint = statement.columnInt64(4),
        .state = switch (state) {
            0 => .open,
            1 => .skipped,
            2 => .applied,
            else => return error.InvalidStoredIssue,
        },
    };
}

fn chosenValue(allocator: std.mem.Allocator, db: database.sqlite.Database, group_id: i64, header: Header, choice: MetadataIssueChoice) ![]const u8 {
    switch (choice) {
        .option => |id| {
            var statement = try db.prepare("SELECT proposed FROM metadata_proposals WHERE group_id = ?1 AND option = ?2;");
            defer statement.deinit();
            try statement.bindInt64(1, group_id);
            try statement.bindInt64(2, id);
            if (try statement.step() != .row) return error.UnknownIssueOption;
            return allocator.dupe(u8, statement.columnText(0));
        },
        .custom => |text| {
            const value = std.mem.trim(u8, text, " \t\r\n");
            if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidEditValue;
            switch (header.field) {
                .track_number => return error.CustomValueNotAllowed,
                .date => if (!consistency_pass.validDate(value)) return error.InvalidEditValue,
                .genre => {
                    const folded = try genre_alias.fold(allocator, value);
                    if (!std.mem.eql(u8, folded.key, header.key)) return error.GenreDoesNotMatchIssue;
                },
                .album, .album_artist => {},
            }
            return value;
        },
    }
}

fn metadataField(field: IssueField) metadata.Field {
    return switch (field) {
        .album => .album,
        .album_artist => .album_artist,
        .date => .date,
        .track_number => .track_number,
        .genre => unreachable,
    };
}

fn tracksOfFile(allocator: std.mem.Allocator, library_database: *database.LibraryDatabase, file_id: i64) ![]i64 {
    return library_database.tracks.idsForFile(allocator, file_id);
}

/// Applies the chosen value to the issue's tracks as Orca values, skipping
/// locked ones, and marks the issue applied. Returns the Tracks changed.
pub fn libraryApplyMetadataIssue(
    self: *OrcaRuntime,
    library: LibraryHandle,
    group_id: i64,
    choice: MetadataIssueChoice,
) !u64 {
    return libraryApplyMetadataIssues(self, library, &.{.{ .group_id = group_id, .choice = choice }});
}

const Prepared = struct {
    group_id: i64,
    header: Header,
    value: []const u8,
    issue: *const consistency_pass.Issue,
    tracks: ?[]const i64,

    fn includes(self: *const Prepared, member: consistency_pass.Member) bool {
        const chosen = self.tracks orelse return true;
        return std.mem.indexOfScalar(i64, chosen, member.track_id) != null;
    }
};

/// Checks every application before changing anything, so one out-of-date
/// issue leaves all of them open, then applies each and marks it applied.
pub fn libraryApplyMetadataIssues(
    self: *OrcaRuntime,
    library: LibraryHandle,
    applications: []const MetadataIssueApplication,
) !u64 {
    if (applications.len > max_page) return error.PageOutOfRange;
    const library_database = try runtime.libraryDatabase(self, library);
    const db = library_database.database;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prepared = try arena.alloc(Prepared, applications.len);
    for (applications, prepared, 0..) |application, *entry, index| {
        for (applications[0..index]) |earlier| {
            if (earlier.group_id == application.group_id) return error.InvalidIssueSelection;
        }
        const header = try loadHeader(arena, db, application.group_id);
        if (header.state != .open) return error.IssueNotOpen;
        const value = try chosenValue(arena, db, application.group_id, header, application.choice);
        const issues = try consistency_pass.detect(arena, db, header.release_id, header.release_id);
        const issue = for (issues) |*candidate| {
            if (candidate.matches(header.category, header.field, header.key)) break candidate;
        } else return error.IssueOutOfDate;
        if (issue.fingerprint != header.fingerprint) return error.IssueOutOfDate;
        if (application.tracks) |chosen| {
            if (chosen.len == 0) return error.NoTracksChosen;
            for (chosen) |track_id| {
                for (issue.members) |member| {
                    if (member.track_id == track_id) break;
                } else return error.TrackNotInIssue;
            }
        }
        entry.* = .{
            .group_id = application.group_id,
            .header = header,
            .value = value,
            .issue = issue,
            .tracks = application.tracks,
        };
    }

    var changed: u64 = 0;
    for (prepared) |*entry| changed += try applyPrepared(self, library, library_database, arena, entry);

    library_database.write_lane.acquire();
    defer library_database.write_lane.release();
    var mark = try db.prepare("UPDATE metadata_proposals SET state = 2 WHERE group_id = ?1;");
    defer mark.deinit();
    for (prepared) |entry| {
        try mark.bindInt64(1, entry.group_id);
        _ = try mark.step();
        try mark.reset();
    }
    return changed;
}

fn applyPrepared(
    self: *OrcaRuntime,
    library: LibraryHandle,
    library_database: *database.LibraryDatabase,
    arena: std.mem.Allocator,
    entry: *const Prepared,
) !u64 {
    const db = library_database.database;
    const header = entry.header;
    const issue = entry.issue;
    const value = entry.value;
    var changed: u64 = 0;
    switch (header.field) {
        .genre => {
            for (issue.members) |member| {
                if (!entry.includes(member)) continue;
                var names: std.ArrayList([]const u8) = .empty;
                var keys: std.ArrayList([]const u8) = .empty;
                var differs = false;
                for (member.genres) |part| {
                    const folded = try genre_alias.fold(arena, part);
                    const name = if (std.mem.eql(u8, folded.key, header.key)) value else part;
                    if (!std.mem.eql(u8, name, part)) differs = true;
                    const seen = for (keys.items) |key| {
                        if (std.mem.eql(u8, key, folded.key)) break true;
                    } else false;
                    if (seen) {
                        differs = true;
                        continue;
                    }
                    try keys.append(arena, folded.key);
                    try names.append(arena, name);
                }
                if (!differs) continue;
                try library_database.genres.setTrackGenres(self.allocator, &.{member.track_id}, names.items);
                changed += 1;
            }
            library_database.write_lane.acquire();
            defer library_database.write_lane.release();
            var rename = try db.prepare("UPDATE genres SET name = ?1 WHERE key = ?2;");
            defer rename.deinit();
            try rename.bindText(1, value);
            try rename.bindText(2, header.key);
            _ = try rename.step();
        },
        .track_number => for (issue.members) |member| {
            if (member.locked or !entry.includes(member)) continue;
            const number = member.renumbered orelse continue;
            const tracks = try tracksOfFile(arena, library_database, member.file_id);
            if (tracks.len == 0) continue;
            const edited = try runtime_roots.libraryEditTracks(self, library, tracks, &.{
                .{ .field = .track_number, .value = number },
            });
            edited.deinit();
            changed += 1;
        },
        .album, .album_artist, .date => {
            var selected: std.ArrayList(i64) = .empty;
            for (issue.members) |member| {
                if (member.locked or !entry.includes(member) or issue.proposed(member, value) == null) continue;
                const tracks = try tracksOfFile(arena, library_database, member.file_id);
                for (tracks) |id| if (std.mem.indexOfScalar(i64, selected.items, id) == null)
                    try selected.append(arena, id);
            }
            var start: usize = 0;
            while (start < selected.items.len) : (start += max_page) {
                const chunk = selected.items[start..@min(start + max_page, selected.items.len)];
                const edited = try runtime_roots.libraryEditTracks(self, library, chunk, &.{
                    .{ .field = metadataField(header.field), .value = value },
                });
                edited.deinit();
            }
            changed = selected.items.len;
        },
    }
    return changed;
}

/// Hides an open issue until its tracks' values change.
pub fn librarySkipMetadataIssue(self: *OrcaRuntime, library: LibraryHandle, group_id: i64) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    const db = library_database.database;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const header = try loadHeader(arena_state.allocator(), db, group_id);
    if (header.state != .open) return error.IssueNotOpen;
    library_database.write_lane.acquire();
    defer library_database.write_lane.release();
    var statement = try db.prepare("UPDATE metadata_proposals SET state = 1 WHERE group_id = ?1 AND state = 0;");
    defer statement.deinit();
    try statement.bindInt64(1, group_id);
    _ = try statement.step();
}

const testing = std.testing;

fn observe(library_database: *database.LibraryDatabase, uri: []const u8, values: metadata.ObservedTags) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = uri,
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = values });
    return file_id;
}

fn project(library_database: *database.LibraryDatabase) !void {
    var projection: library_pass.Projection = .{ .allocator = testing.allocator, .library = library_database };
    _ = try projection.run(.all);
}

fn runPassToEnd(orca: *OrcaRuntime, library: LibraryHandle) !void {
    const job_handle = try orca.startLibraryConsistencyPass(library, .{ .batch_size = 1 });
    while (true) {
        orca.reapFinishedJobs();
        const snapshot = try orca.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) return;
        if (snapshot.state == .failed or snapshot.state == .cancelled) return error.ConsistencyPassDidNotSucceed;
        std.Thread.yield() catch {};
    }
}

test "applying an issue changes the unlocked tracks that differ, keeps a locked value and returns the count" {
    var orca: OrcaRuntime = .init(testing.allocator);
    defer orca.deinit();
    const library = try orca.openLibrary(testing.io, "file:orca-consistency-apply?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&orca, library);
    _ = try observe(library_database, "/m/E/01.flac", .{ .title = "One", .album = "E", .album_artist = "AB", .track_number = 1 });
    _ = try observe(library_database, "/m/E/02.flac", .{ .title = "Two", .album = "E", .album_artist = "AB", .track_number = 2 });
    _ = try observe(library_database, "/m/E/03.flac", .{ .title = "Three", .album = "E", .album_artist = "Ab", .track_number = 3 });
    const locked = try observe(library_database, "/m/E/04.flac", .{ .title = "Four", .album = "E", .album_artist = "ab", .track_number = 4 });
    try library_database.orca_metadata.upsert(.{ .file_id = locked, .field = .album_artist, .value = "ab", .provenance = .user, .locked = true });
    try project(library_database);

    try runPassToEnd(&orca, library);
    try testing.expectEqual(@as(u64, 1), try orca.libraryMetadataIssueCount(library, .album_artist));
    const page = try orca.libraryMetadataIssuePage(library, testing.allocator, .album_artist, 10, 0);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 1), page.items.len);
    const group = page.items[0];
    try testing.expectEqual(@as(u32, 4), group.track_count);
    try testing.expectEqual(@as(usize, 3), group.options.len);
    try testing.expectEqualStrings("AB", group.options[0].value);
    try testing.expectEqualStrings("2 tracks", group.options[0].support.slice());
    try testing.expectEqual(@as(usize, 1), group.proposals.len);
    try testing.expectEqualStrings("Ab", group.proposals[0].current.?);

    try testing.expectEqual(@as(u64, 1), try orca.libraryApplyMetadataIssue(library, group.id, .{ .option = 0 }));
    try testing.expectError(error.IssueNotOpen, orca.libraryApplyMetadataIssue(library, group.id, .{ .option = 0 }));
    try testing.expectEqual(@as(u64, 0), try orca.libraryMetadataIssueCount(library, null));
    const kept = (try library_database.orca_metadata.get(testing.allocator, locked, .album_artist)).?;
    defer kept.deinit(testing.allocator);
    try testing.expectEqualStrings("ab", kept.text);
    try testing.expect(kept.locked);

    try runPassToEnd(&orca, library);
    const again = try orca.libraryMetadataIssuePage(library, testing.allocator, .album_artist, 10, 0);
    defer again.deinit();
    try testing.expectEqual(@as(usize, 1), again.items.len);
    try testing.expectEqual(@as(usize, 2), again.items[0].options.len);
    try testing.expectEqual(@as(usize, 0), again.items[0].proposals.len);
}

test "an issue whose tracks changed since the pass is out of date, and a skipped one cannot be applied" {
    var orca: OrcaRuntime = .init(testing.allocator);
    defer orca.deinit();
    const library = try orca.openLibrary(testing.io, "file:orca-consistency-stale?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&orca, library);
    _ = try observe(library_database, "/m/F/01.flac", .{ .title = "One", .album = "F", .album_artist = "Cd", .track_number = 1 });
    const second = try observe(library_database, "/m/F/02.flac", .{ .title = "Two", .album = "F", .album_artist = "CD", .track_number = 2 });
    try project(library_database);
    try runPassToEnd(&orca, library);
    const page = try orca.libraryMetadataIssuePage(library, testing.allocator, null, 10, 0);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 1), page.items.len);
    const group_id = page.items[0].id;

    try library_database.observed_tags.upsert(.{ .file_id = second, .values = .{ .title = "Two", .album = "F", .album_artist = "cD", .track_number = 2 } });
    try project(library_database);
    try testing.expectError(error.IssueOutOfDate, orca.libraryApplyMetadataIssue(library, group_id, .{ .option = 0 }));
    try orca.librarySkipMetadataIssue(library, group_id);
    try testing.expectError(error.IssueNotOpen, orca.libraryApplyMetadataIssue(library, group_id, .{ .option = 0 }));
    try testing.expectEqual(@as(u64, 0), try orca.libraryMetadataIssueCount(library, null));
}

fn trackOf(page: MetadataIssuePage, title: []const u8) !i64 {
    for (page.items) |group| for (group.proposals) |proposal| {
        if (std.mem.eql(u8, proposal.title, title)) return proposal.track_id;
    };
    return error.TestUnexpectedResult;
}

test "applying a date issue to a subset of its tracks leaves the unchosen track's date as it was" {
    var orca: OrcaRuntime = .init(testing.allocator);
    defer orca.deinit();
    const library = try orca.openLibrary(testing.io, "file:orca-consistency-subset?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&orca, library);
    _ = try observe(library_database, "/m/G/01.flac", .{ .title = "Nikes", .album = "G", .album_artist = "X", .track_number = 1, .date = "2016-08-20" });
    _ = try observe(library_database, "/m/G/02.flac", .{ .title = "Ivy", .album = "G", .album_artist = "X", .track_number = 2, .date = "2016-08-20" });
    const solo = try observe(library_database, "/m/G/03.flac", .{ .title = "Solo (Reprise)", .album = "G", .album_artist = "X", .track_number = 3, .date = "2016" });
    const story = try observe(library_database, "/m/G/04.flac", .{ .title = "Facebook Story", .album = "G", .album_artist = "X", .track_number = 4, .date = "2016-08" });
    try project(library_database);
    try runPassToEnd(&orca, library);

    const page = try orca.libraryMetadataIssuePage(library, testing.allocator, .dates, 10, 0);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 1), page.items.len);
    const group = page.items[0];
    try testing.expect(group.precision);
    try testing.expect(!group.case_only);
    try testing.expectEqual(@as(u32, 0), group.missing);
    try testing.expectEqualStrings("2016-08-20", group.options[0].value);
    try testing.expectEqual(@as(u32, 2), group.options[0].tracks);
    try testing.expectEqualStrings("1 track · Solo (Reprise)", group.options[1].support.slice());
    try testing.expectEqual(@as(usize, 2), group.proposals.len);

    const chosen = [_]i64{try trackOf(page, "Solo (Reprise)")};
    try testing.expectError(error.NoTracksChosen, orca.libraryApplyMetadataIssues(library, &.{
        .{ .group_id = group.id, .choice = .{ .option = 0 }, .tracks = &.{} },
    }));
    try testing.expectError(error.TrackNotInIssue, orca.libraryApplyMetadataIssues(library, &.{
        .{ .group_id = group.id, .choice = .{ .option = 0 }, .tracks = &.{-1} },
    }));
    try testing.expectEqual(@as(u64, 1), try orca.libraryApplyMetadataIssues(library, &.{
        .{ .group_id = group.id, .choice = .{ .option = 0 }, .tracks = &chosen },
    }));
    const applied = (try library_database.orca_metadata.get(testing.allocator, solo, .date)).?;
    defer applied.deinit(testing.allocator);
    try testing.expectEqualStrings("2016-08-20", applied.text);
    try testing.expect((try library_database.orca_metadata.get(testing.allocator, story, .date)) == null);
    try testing.expectEqual(@as(u64, 0), try orca.libraryMetadataIssueCount(library, null));
}

test "applying several issues checks them all first, so an out-of-date one leaves every issue open" {
    var orca: OrcaRuntime = .init(testing.allocator);
    defer orca.deinit();
    const library = try orca.openLibrary(testing.io, "file:orca-consistency-several?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&orca, library);
    const first = try observe(library_database, "/m/H/01.flac", .{ .title = "One", .album = "H", .album_artist = "Hi", .track_number = 1 });
    _ = try observe(library_database, "/m/H/02.flac", .{ .title = "Two", .album = "H", .album_artist = "HI", .track_number = 2 });
    _ = try observe(library_database, "/m/H/03.flac", .{ .title = "Three", .album = "H", .album_artist = "HI", .track_number = 3 });
    _ = try observe(library_database, "/m/J/01.flac", .{ .title = "One", .album = "J", .album_artist = "Jo", .track_number = 1 });
    const changed = try observe(library_database, "/m/J/02.flac", .{ .title = "Two", .album = "J", .album_artist = "JO", .track_number = 2 });
    try project(library_database);
    try runPassToEnd(&orca, library);
    const page = try orca.libraryMetadataIssuePage(library, testing.allocator, .album_artist, 10, 0);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 2), page.items.len);
    try testing.expect(page.items[0].case_only);
    const applications = [_]MetadataIssueApplication{
        .{ .group_id = page.items[0].id, .choice = .{ .option = 0 } },
        .{ .group_id = page.items[1].id, .choice = .{ .option = 0 } },
    };

    try library_database.observed_tags.upsert(.{ .file_id = changed, .values = .{ .title = "Two", .album = "J", .album_artist = "jO", .track_number = 2 } });
    try project(library_database);
    try testing.expectError(error.IssueOutOfDate, orca.libraryApplyMetadataIssues(library, &applications));
    try testing.expectError(error.InvalidIssueSelection, orca.libraryApplyMetadataIssues(library, &.{ applications[0], applications[0] }));
    try testing.expect((try library_database.orca_metadata.get(testing.allocator, first, .album_artist)) == null);
    try testing.expectEqual(@as(u64, 2), try orca.libraryMetadataIssueCount(library, null));
    try testing.expectEqual(@as(u64, 1), try orca.libraryApplyMetadataIssues(library, applications[0..1]));
    try testing.expectEqual(@as(u64, 1), try orca.libraryMetadataIssueCount(library, null));
}

test "issue status counts open issues and their releases and is stale once a scan changes files after the pass" {
    var orca: OrcaRuntime = .init(testing.allocator);
    defer orca.deinit();
    const library = try orca.openLibrary(testing.io, "file:orca-consistency-status?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&orca, library);
    _ = try observe(library_database, "/m/K/01.flac", .{ .title = "One", .album = "K", .album_artist = "Ka", .track_number = 1, .date = "2018" });
    _ = try observe(library_database, "/m/K/02.flac", .{ .title = "Two", .album = "K", .album_artist = "KA", .track_number = 2, .date = "2018-04-05" });
    try project(library_database);

    const before = try orca.libraryMetadataIssueStatus(library);
    try testing.expect(before.stale);
    try testing.expectEqual(@as(?i64, null), before.last_pass_at);
    try testing.expectEqual(@as(u64, 0), before.open);

    try runPassToEnd(&orca, library);
    orca.reapFinishedJobs();
    const after = try orca.libraryMetadataIssueStatus(library);
    try testing.expect(!after.stale);
    try testing.expect(after.last_pass_at != null);
    try testing.expectEqual(@as(u64, 2), after.open);
    try testing.expectEqual(@as(u64, 1), after.releases);
    try testing.expectEqual(@as(u64, 1), after.by_category.get(.album_artist));
    try testing.expectEqual(@as(u64, 1), after.by_category.get(.dates));

    try library_database.database.exec(
        \\INSERT INTO library_roots(id, volume_id, path) SELECT 1, min(id), '/m' FROM volumes;
        \\INSERT INTO scan_runs(root_id, generation, finished_at, state) VALUES (1, 1, 4000000000, 'completed');
    );
    try testing.expect(!(try orca.libraryMetadataIssueStatus(library)).stale);
    try library_database.database.exec(
        \\INSERT INTO scan_runs(root_id, generation, finished_at, state, changed) VALUES (1, 2, 4000000001, 'completed', 1);
    );
    try testing.expect((try orca.libraryMetadataIssueStatus(library)).stale);
}
