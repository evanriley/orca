const std = @import("std");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const runtime = @import("runtime.zig");
const track_details = @import("track_details.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const TrackDetails = track_details.TrackDetails;
const max_page = database.repository.max_page;

/// Files the duplicate scan found to be copies of one another, as one row of
/// the Duplicates view.
pub const DuplicateGroup = struct {
    /// The lowest file id in the group: the same on every read while the
    /// group's duplicate issues are unchanged.
    id: i64,
    /// The suggested copy's Track's title, or its path when it backs none.
    title: []u8,
    artist: []u8,
    /// Every copy, each further location of a file counting as one.
    copies: u32,
    /// Whether every copy is an encoding of one recording, so they share one
    /// play count and rating.
    same_recording: bool,
    /// How alike the least alike copies sound, from 0 to 1; 1 for exact
    /// copies and identical audio. Null when a likely duplicate was found
    /// before similarities were stored.
    similarity: ?f32,
    /// What the duplicate scan proved of every copy: the same bytes, the same
    /// audio, or matching fingerprints.
    verdict: database.DuplicateVerdict,
    /// The bytes removing every copy but the suggested one would free.
    bytes_redundant: u64,

    pub fn deinit(self: DuplicateGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
    }
};

/// A page of duplicate groups, ordered by id. Caller-owned.
pub const DuplicateGroupPage = struct {
    allocator: std.mem.Allocator,
    items: []DuplicateGroup,

    pub fn deinit(self: *DuplicateGroupPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const DuplicateGroupTotals = struct {
    groups: u64,
    /// The summed `bytes_redundant` of every group.
    bytes: u64,
};

/// One file of a duplicate group.
pub const DuplicateCopy = struct {
    file_id: i64,
    /// The lowest-numbered Track the file backs, or null when none does.
    track_id: ?i64,
    /// That Track as this file describes it: its format, size, path and
    /// loudness are this file's. Null without a Track.
    details: ?TrackDetails,
    /// Whether this is the copy to keep: lossless over lossy, then the higher
    /// sample rate, the higher bit depth, then the larger file. Exactly one
    /// copy of a group is suggested.
    suggested_keep: bool,
    /// The playlists holding this file's recording.
    playlist_count: u64,
    /// The file's locations that are not missing, at least 1.
    locations: u32,
    /// What this file's own tags state, unresolved, where `details` holds
    /// the values of the Track and Release its copies share. Null when the
    /// tags state nothing.
    tagged_date: ?[]u8 = null,
    tagged_track_number: ?u32 = null,
    tagged_track_total: ?u32 = null,
};

/// The copies of one group, the suggested one first. Caller-owned.
pub const DuplicateCopyList = struct {
    allocator: std.mem.Allocator,
    items: []DuplicateCopy,
    same_recording: bool,
    similarity: ?f32,
    verdict: database.DuplicateVerdict,
    copies: u32,
    bytes_redundant: u64,

    pub fn deinit(self: *DuplicateCopyList) void {
        for (self.items) |item| {
            if (item.details) |details| details.deinit();
            if (item.tagged_date) |date| self.allocator.free(date);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// What `libraryMergeDuplicateMetadata` changed.
pub const DuplicateMerge = struct {
    /// The kept Track's id after its files were reprojected: a new id when a
    /// copied value moved it to another Release.
    track_id: i64,
    /// Orca value rows written across the kept Track's files.
    values: u32,
    rating: bool,
    feedback: bool,
    /// The other Track's user genres replaced the kept Track's, which had
    /// none of its own.
    genres: bool,
};

const Ranked = struct {
    files: []database.DuplicateFile,
    same_recording: bool,
    bytes_redundant: u64,
    copies: u32,
};

fn rank(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    members: database.DuplicateGroupMembers,
) !Ranked {
    var files: std.ArrayList(database.DuplicateFile) = .empty;
    errdefer files.deinit(allocator);
    for (members.file_ids) |file_id| {
        if (try library.duplicate_groups.file(file_id)) |file| try files.append(allocator, file);
    }
    std.mem.sort(database.DuplicateFile, files.items, {}, database.repository.keepsBefore);
    var bytes: u64 = 0;
    var copies: u32 = 0;
    var recording: ?i64 = null;
    var same_recording = files.items.len > 0;
    for (files.items, 0..) |file, index| {
        const size: u64 = @intCast(file.size_bytes);
        const redundant = if (index == 0) file.copies - 1 else file.copies;
        bytes +|= size *| redundant;
        copies +|= file.copies;
        if (file.recording_id == null or (recording != null and recording.? != file.recording_id.?)) {
            same_recording = false;
        }
        recording = file.recording_id;
    }
    return .{
        .files = try files.toOwnedSlice(allocator),
        .same_recording = same_recording,
        .bytes_redundant = bytes,
        .copies = copies,
    };
}

pub fn libraryDuplicateGroupPage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    limit: u32,
    offset: u32,
) !DuplicateGroupPage {
    if (limit > max_page) return error.PageOutOfRange;
    const library_database = try runtime.libraryDatabase(self, library);
    var grouping = try library_database.duplicate_groups.grouping(allocator);
    defer grouping.deinit();
    const start = @min(offset, grouping.groups.len);
    const end = @min(start + limit, grouping.groups.len);

    var items: std.ArrayList(DuplicateGroup) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }
    for (grouping.groups[start..end]) |members| {
        const ranked = try rank(allocator, library_database, members);
        defer allocator.free(ranked.files);
        const label: database.DuplicateLabel = if (ranked.files.len > 0)
            try library_database.duplicate_groups.label(allocator, ranked.files[0])
        else
            .{ .title = try allocator.dupe(u8, ""), .artist = try allocator.dupe(u8, "") };
        errdefer {
            allocator.free(label.title);
            allocator.free(label.artist);
        }
        try items.append(allocator, .{
            .id = members.id,
            .title = label.title,
            .artist = label.artist,
            .copies = ranked.copies,
            .same_recording = ranked.same_recording,
            .similarity = members.similarity,
            .verdict = members.verdict,
            .bytes_redundant = ranked.bytes_redundant,
        });
    }
    return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn libraryDuplicateGroupTotals(self: *OrcaRuntime, library: LibraryHandle) !DuplicateGroupTotals {
    const library_database = try runtime.libraryDatabase(self, library);
    var grouping = try library_database.duplicate_groups.grouping(self.allocator);
    defer grouping.deinit();
    var bytes: u64 = 0;
    for (grouping.groups) |members| {
        const ranked = try rank(self.allocator, library_database, members);
        defer self.allocator.free(ranked.files);
        bytes +|= ranked.bytes_redundant;
    }
    return .{ .groups = grouping.groups.len, .bytes = bytes };
}

pub fn libraryDuplicateGroup(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    group_id: i64,
) !DuplicateCopyList {
    const library_database = try runtime.libraryDatabase(self, library);
    var grouping = try library_database.duplicate_groups.grouping(allocator);
    defer grouping.deinit();
    const members = grouping.find(group_id) orelse return error.UnknownDuplicateGroup;
    const ranked = try rank(allocator, library_database, members);
    defer allocator.free(ranked.files);

    var items: std.ArrayList(DuplicateCopy) = .empty;
    errdefer {
        for (items.items) |item| {
            if (item.details) |details| details.deinit();
            if (item.tagged_date) |date| allocator.free(date);
        }
        items.deinit(allocator);
    }
    for (ranked.files, 0..) |file, index| {
        const details = if (file.track_id) |track_id|
            try track_details.loadForFile(allocator, library_database, track_id, file.file_id)
        else
            null;
        errdefer if (details) |value| value.deinit();
        const tags = try library_database.observed_tags.get(allocator, file.file_id);
        defer if (tags) |stored| stored.deinit();
        const tagged: metadata.ObservedTags = if (tags) |stored| stored.values else .{};
        const tagged_date = if (tagged.date) |date| try allocator.dupe(u8, date) else null;
        errdefer if (tagged_date) |date| allocator.free(date);
        try items.append(allocator, .{
            .file_id = file.file_id,
            .track_id = file.track_id,
            .details = details,
            .suggested_keep = index == 0,
            .playlist_count = if (file.recording_id) |recording|
                try library_database.duplicate_groups.playlistCount(recording)
            else
                0,
            .locations = file.copies,
            .tagged_date = tagged_date,
            .tagged_track_number = tagged.track_number,
            .tagged_track_total = tagged.track_total,
        });
    }
    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
        .same_recording = ranked.same_recording,
        .similarity = members.similarity,
        .verdict = members.verdict,
        .copies = ranked.copies,
        .bytes_redundant = ranked.bytes_redundant,
    };
}

pub fn libraryDuplicateCopyPlaylists(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    file_id: i64,
) ![][]u8 {
    const library_database = try runtime.libraryDatabase(self, library);
    const file = try library_database.duplicate_groups.file(file_id) orelse return error.UnknownFile;
    const recording = file.recording_id orelse return allocator.alloc([]u8, 0);
    return library_database.duplicate_groups.playlistNames(allocator, recording, max_page);
}

pub fn libraryKeepBoth(self: *OrcaRuntime, library: LibraryHandle, file_id: i64, other_file_id: i64) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    var grouping = try library_database.duplicate_groups.grouping(self.allocator);
    defer grouping.deinit();
    const group = grouping.groupOf(file_id) orelse return error.NotDuplicates;
    if (std.mem.indexOfScalar(i64, group.file_ids, other_file_id) == null) return error.NotDuplicates;
    try library_database.duplicate_groups.dismiss(&.{ file_id, other_file_id });
}

pub fn libraryIgnoreDuplicateGroup(self: *OrcaRuntime, library: LibraryHandle, group_id: i64) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    var grouping = try library_database.duplicate_groups.grouping(self.allocator);
    defer grouping.deinit();
    const members = grouping.find(group_id) orelse return error.UnknownDuplicateGroup;
    try library_database.duplicate_groups.dismiss(members.file_ids);
}

pub fn libraryMergeDuplicateMetadata(
    self: *OrcaRuntime,
    library: LibraryHandle,
    keep_track_id: i64,
    from_track_id: i64,
) !DuplicateMerge {
    const library_database = try runtime.libraryDatabase(self, library);
    const result = try library_database.duplicate_groups.mergeMetadata(self.allocator, keep_track_id, from_track_id);
    defer self.allocator.free(result.kept_file_ids);
    var track_id = keep_track_id;
    if (result.values > 0 and result.kept_file_ids.len > 0) {
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = library_database,
        };
        _ = try pass.run(.{ .files = result.kept_file_ids });
        const ids = try library_database.tracks.idsForFile(self.allocator, result.kept_file_ids[0]);
        defer self.allocator.free(ids);
        if (ids.len > 0) track_id = std.mem.min(i64, ids);
    }
    return .{
        .track_id = track_id,
        .values = result.values,
        .rating = result.rating,
        .feedback = result.feedback,
        .genres = result.genres,
    };
}

fn scanFixtures(owner: *OrcaRuntime, uri: [:0]const u8) !LibraryHandle {
    const library = try owner.openLibrary(std.testing.io, uri);
    const binding = try owner.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    const job_handle = try owner.startLibraryScan(library, .{ .root_id = binding.root_id });
    while (true) {
        owner.reapFinishedJobs();
        const snapshot = try owner.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) return library;
        if (snapshot.state == .failed or snapshot.state == .cancelled) return error.ScanDidNotSucceed;
        std.Thread.yield() catch {};
    }
}

fn fixtureFile(library: *database.LibraryDatabase, suffix: []const u8) !i64 {
    var statement = try library.database.prepare(
        "SELECT file_id FROM locations WHERE uri LIKE '%' || ?1 ORDER BY id LIMIT 1;",
    );
    defer statement.deinit();
    try statement.bindText(1, suffix);
    if (try statement.step() != .row) return error.FixtureNotScanned;
    return statement.columnInt64(0);
}

test "duplicate groups page, total, rank their copies, and leave the view when kept or ignored" {
    var owner = OrcaRuntime.init(std.testing.allocator);
    defer owner.deinit();
    const library = try scanFixtures(&owner, "file:orca-duplicate-groups-runtime?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&owner, library);
    const flac = try fixtureFile(library_database, "/tagged-reference.flac");
    const mp3 = try fixtureFile(library_database, "/tagged-reference.mp3");
    const opus = try fixtureFile(library_database, "/tagged-reference.opus");
    const wav = try fixtureFile(library_database, "/tagged-reference.wav");
    try library_database.health_issues.replaceFile(mp3, &.{.{ .kind = .likely_duplicate, .severity = .information, .related_file_id = flac, .similarity = 0.99 }});
    try library_database.health_issues.replaceFile(flac, &.{.{ .kind = .likely_duplicate, .severity = .information, .related_file_id = mp3, .similarity = 0.99 }});
    try library_database.health_issues.replaceFile(opus, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = wav }});
    try library_database.health_issues.replaceFile(wav, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = opus }});

    var page = try owner.libraryDuplicateGroupPage(library, std.testing.allocator, 10, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    const likely_id = @min(flac, mp3);
    const likely = for (page.items) |item| {
        if (item.id == likely_id) break item;
    } else return error.GroupMissing;
    try std.testing.expectEqual(@as(u32, 2), likely.copies);
    try std.testing.expectEqual(@as(?f32, 0.99), likely.similarity);
    try std.testing.expectEqual(database.DuplicateVerdict.likely_duplicate, likely.verdict);
    const mp3_size = (try library_database.duplicate_groups.file(mp3)).?.size_bytes;
    try std.testing.expectEqual(@as(u64, @intCast(mp3_size)), likely.bytes_redundant);

    var again = try owner.libraryDuplicateGroupPage(library, std.testing.allocator, 1, 1);
    defer again.deinit();
    try std.testing.expectEqual(page.items[1].id, again.items[0].id);

    const totals = try owner.libraryDuplicateGroupTotals(library);
    try std.testing.expectEqual(@as(u64, 2), totals.groups);
    try std.testing.expectEqual(page.items[0].bytes_redundant + page.items[1].bytes_redundant, totals.bytes);

    var copies = try owner.libraryDuplicateGroup(library, std.testing.allocator, likely_id);
    defer copies.deinit();
    try std.testing.expectEqual(database.DuplicateVerdict.likely_duplicate, copies.verdict);
    try std.testing.expectEqual(@as(usize, 2), copies.items.len);
    try std.testing.expectEqual(flac, copies.items[0].file_id);
    try std.testing.expect(copies.items[0].suggested_keep);
    try std.testing.expect(!copies.items[1].suggested_keep);
    try std.testing.expectEqualStrings("flac", copies.items[0].details.?.codec);
    try std.testing.expectEqualStrings("mp3", copies.items[1].details.?.codec);
    try std.testing.expectEqualStrings("2026", copies.items[0].tagged_date.?);
    try std.testing.expectEqual(@as(?u32, 1), copies.items[0].tagged_track_number);
    try std.testing.expectEqual(@as(?u32, 3), copies.items[0].tagged_track_total);
    try std.testing.expectEqual(@as(?[]u8, null), copies.items[1].tagged_date);
    try std.testing.expectEqual(@as(?u32, 1), copies.items[1].tagged_track_number);
    try std.testing.expectEqual(@as(?u32, null), copies.items[1].tagged_track_total);

    const road = try owner.libraryCreatePlaylist(library, "Road Trip");
    const late = try owner.libraryCreatePlaylist(library, "late night");
    _ = try owner.libraryPlaylistInsert(library, road, &.{copies.items[1].track_id.?}, null);
    _ = try owner.libraryPlaylistInsert(library, late, &.{ copies.items[1].track_id.?, copies.items[1].track_id.? }, null);
    const names = try owner.libraryDuplicateCopyPlaylists(library, std.testing.allocator, mp3);
    defer {
        for (names) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("late night", names[0]);
    try std.testing.expectEqualStrings("Road Trip", names[1]);
    const generated = try fixtureFile(library_database, "/generated-reference.flac");
    const none = try owner.libraryDuplicateCopyPlaylists(library, std.testing.allocator, generated);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expectError(error.UnknownFile, owner.libraryDuplicateCopyPlaylists(library, std.testing.allocator, 1_000_000));

    try std.testing.expectError(error.NotDuplicates, owner.libraryKeepBoth(library, flac, wav));
    try owner.libraryKeepBoth(library, mp3, flac);
    try std.testing.expectError(error.UnknownDuplicateGroup, owner.libraryDuplicateGroup(library, std.testing.allocator, likely_id));
    try owner.libraryIgnoreDuplicateGroup(library, @min(opus, wav));
    try std.testing.expectEqual(DuplicateGroupTotals{ .groups = 0, .bytes = 0 }, try owner.libraryDuplicateGroupTotals(library));
    try std.testing.expectError(error.UnknownDuplicateGroup, owner.libraryIgnoreDuplicateGroup(library, @min(opus, wav)));
}

test "identical-audio findings form a duplicate group that states its verdict and can be ignored" {
    var owner = OrcaRuntime.init(std.testing.allocator);
    defer owner.deinit();
    const library = try scanFixtures(&owner, "file:orca-duplicate-groups-identical?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(&owner, library);
    const flac = try fixtureFile(library_database, "/tagged-reference.flac");
    const wav = try fixtureFile(library_database, "/tagged-reference.wav");
    try library_database.health_issues.replaceFile(flac, &.{.{ .kind = .identical_audio, .severity = .warning, .related_file_id = wav }});
    try library_database.health_issues.replaceFile(wav, &.{.{ .kind = .identical_audio, .severity = .warning, .related_file_id = flac }});

    var page = try owner.libraryDuplicateGroupPage(library, std.testing.allocator, 10, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqual(database.DuplicateVerdict.identical_audio, page.items[0].verdict);
    try std.testing.expectEqual(@as(?f32, 1), page.items[0].similarity);
    var copies = try owner.libraryDuplicateGroup(library, std.testing.allocator, page.items[0].id);
    defer copies.deinit();
    try std.testing.expectEqual(database.DuplicateVerdict.identical_audio, copies.verdict);
    try std.testing.expectEqual(@as(usize, 2), copies.items.len);
    try std.testing.expectEqual(@min(flac, wav) + @max(flac, wav), copies.items[0].file_id + copies.items[1].file_id);

    try owner.libraryIgnoreDuplicateGroup(library, page.items[0].id);
    try std.testing.expectEqual(DuplicateGroupTotals{ .groups = 0, .bytes = 0 }, try owner.libraryDuplicateGroupTotals(library));
}
