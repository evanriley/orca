//! Measures the covers a Library observed before it measured covers.
//!
//! The scanner measures an embedded cover and a folder image when it observes
//! their bytes, and never again while those bytes stay unchanged, so a library
//! scanned before covers were measured keeps them unmeasured for ever, and an
//! unmeasured cover raises no `undersized` or `conflicting` problem. A cover
//! the Library kept from the Cover Art Archive before then is never fetched
//! again, so it stays unmeasured too.
//!
//! This pass repairs them as `PropertyBackfill` repairs audio properties: by
//! id, never by walking a filesystem, through the partial indexes that name
//! exactly the unmeasured rows. A kept cover is measured from the bytes the
//! Library holds, inside the commit. Each batch settles the `artwork_problem`
//! of the Releases it measured covers for in the same commit.

const std = @import("std");
const database = @import("../database/root.zig");
const image_header = @import("../metadata/root.zig").image_header;
const storage = @import("../storage/root.zig");
const scanner = @import("scanner.zig");
const tag_reader = @import("tag_reader.zig");

pub const CancellationToken = scanner.CancellationToken;
const CurrentItem = scanner.CurrentItem;
const CoverOrigin = database.repository.CoverOrigin;
const UnmeasuredCover = database.repository.UnmeasuredCover;

pub const Result = struct {
    /// Unmeasured covers examined.
    covers_seen: u64 = 0,
    /// Covers measured and stored, including those whose bytes would not
    /// read, which are stored as unreadable so they are not examined again.
    measured: u64 = 0,
    /// Covers whose file is not reachable or whose bytes changed since they
    /// were observed; the next scan observes a changed one.
    skipped: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
};

const Repair = struct {
    cover: UnmeasuredCover,
    measured: ?image_header.Measurement,
};

pub const ArtworkBackfill = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    locations: *database.LocationRepository,
    write_lane: *database.repository.WriteLane,
    database_handle: database.sqlite.Database,
    cancellation: ?*const CancellationToken = null,
    current_item: ?*CurrentItem = null,
    /// Covers examined so far, published for a host showing progress.
    progress: ?*std.atomic.Value(u64) = null,
    /// Covers per selected page and per bounded commit.
    batch_size: usize = 256,

    pub fn run(self: *ArtworkBackfill) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        var result: Result = .{};
        for ([_]CoverOrigin{ .embedded, .folder, .kept }) |origin| {
            try self.repair(origin, &result);
            if (result.cancelled) break;
        }
        return result;
    }

    fn repair(self: *ArtworkBackfill, origin: CoverOrigin, result: *Result) !void {
        const page_limit: u32 = @intCast(@min(self.batch_size, @as(usize, database.repository.max_page)));
        var repairs: std.ArrayList(Repair) = .empty;
        defer repairs.deinit(self.allocator);
        var cursor: i64 = 0;
        while (true) {
            var page = try database.repository.unmeasuredCoverPage(
                self.database_handle,
                self.allocator,
                origin,
                cursor,
                page_limit,
            );
            defer page.deinit();
            if (page.items.len == 0) return;
            for (page.items) |item| {
                if (self.isCancelled()) {
                    result.cancelled = true;
                    break;
                }
                cursor = item.id;
                if (self.current_item) |current| current.set(item.uri);
                result.covers_seen += 1;
                if (self.progress) |counter| counter.store(result.covers_seen, .release);
                try repairs.append(self.allocator, .{
                    .cover = item,
                    .measured = try self.measure(origin, item),
                });
            }
            if (repairs.items.len > 0) {
                try self.commit(origin, repairs.items, result);
                repairs.clearRetainingCapacity();
                result.batches_committed += 1;
            }
            if (result.cancelled) return;
        }
    }

    fn isCancelled(self: *const ArtworkBackfill) bool {
        const token = self.cancellation orelse return false;
        return token.checkpoint();
    }

    /// Null when the cover cannot be measured now: its file is unreachable, or
    /// its bytes are not the ones that were observed.
    fn measure(self: *ArtworkBackfill, origin: CoverOrigin, cover: UnmeasuredCover) !?image_header.Measurement {
        if (origin == .kept) return .{ .hash = image_header.unreadable_hash };
        if (cover.uri.len == 0) return null;
        var local = storage.LocalFileSource.open(self.io, cover.uri) catch return null;
        defer local.close();
        const identity = local.readable().identity();
        const size_bytes = std.math.cast(i64, identity.size) orelse return null;
        const modified_ns = std.math.cast(i64, identity.modified_ns) orelse return null;
        if (size_bytes != cover.size_bytes or modified_ns != cover.modified_ns) return null;
        const unreadable: image_header.Measurement = .{ .hash = image_header.unreadable_hash };
        return switch (origin) {
            .folder => image_header.measureAt(local.readable(), 0, identity.size) catch unreadable,
            .embedded => try embeddedMeasurement(self.allocator, local.readable()) orelse unreadable,
            .kept => unreachable,
        };
    }

    fn commit(self: *ArtworkBackfill, origin: CoverOrigin, repairs: []const Repair, result: *Result) !void {
        var release_ids: std.ArrayList(i64) = .empty;
        defer release_ids.deinit(self.allocator);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.database_handle.exec("BEGIN IMMEDIATE;");
        errdefer self.database_handle.exec("ROLLBACK;") catch {};
        for (repairs) |pending| {
            const measured = pending.measured orelse {
                result.skipped += 1;
                continue;
            };
            if (origin == .kept) {
                const kept = try database.repository.measureKeptCoverLocked(self.database_handle, pending.cover.id) orelse {
                    result.skipped += 1;
                    continue;
                };
                result.measured += 1;
                if (kept.front) try release_ids.append(self.allocator, kept.release_id);
                continue;
            }
            try database.repository.storeCoverMeasurementLocked(self.database_handle, origin, pending.cover, measured);
            result.measured += 1;
            switch (origin) {
                .embedded => try database.repository.appendFileReleases(
                    self.database_handle,
                    self.allocator,
                    pending.cover.id,
                    &release_ids,
                ),
                .folder => try self.locations.refreshFolderCoversLocked(
                    self.allocator,
                    pending.cover.volume_id,
                    pending.cover.uri,
                ),
                .kept => unreachable,
            }
        }
        std.mem.sortUnstable(i64, release_ids.items, {}, std.sort.asc(i64));
        var previous: ?i64 = null;
        for (release_ids.items) |release_id| {
            if (previous == release_id) continue;
            previous = release_id;
            try database.repository.settleReleaseArtworkLocked(self.database_handle, release_id);
        }
        try self.database_handle.exec("COMMIT;");
    }
};

/// The measurement the file's tag reader takes of its cover, or null when the
/// tags no longer hold one or would not read.
fn embeddedMeasurement(allocator: std.mem.Allocator, readable: storage.ReadableSource) !?image_header.Measurement {
    const detection = (storage.format.detect(readable) catch return null) orelse return null;
    var tag_view: storage.OffsetSource = .{ .inner = readable, .offset = detection.payload_offset };
    const tags = (tag_reader.read(
        allocator,
        detection.format,
        if (detection.payload_offset == 0) readable else tag_view.readable(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    }) orelse return null;
    defer tags.deinit();
    const artwork = tags.values.artwork orelse return null;
    return .{
        .width = artwork.width,
        .height = artwork.height,
        .hash = artwork.hash orelse image_header.unreadable_hash,
    };
}

const testing = std.testing;

fn pngBytes(comptime width: u32, comptime height: u32) [33]u8 {
    var bytes: [33]u8 = undefined;
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    @memcpy(bytes[24..33], "\x08\x02\x00\x00\x00\x00\x00\x00\x00");
    return bytes;
}

const Fixture = struct {
    directory: std.testing.TmpDir,
    root: []u8,
    library: database.LibraryDatabase,

    fn init(name: [:0]const u8) !Fixture {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
        errdefer testing.allocator.free(root);
        var library = try database.LibraryDatabase.open(testing.allocator, testing.io, name);
        errdefer library.close();
        try library.database.exec(
            \\INSERT INTO volumes(id, stable_key) VALUES (2, 'music');
            \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Album', 'album');
        );
        return .{ .directory = directory, .root = root, .library = library };
    }

    fn deinit(self: *Fixture) void {
        self.library.close();
        testing.allocator.free(self.root);
        self.directory.cleanup();
    }

    fn path(self: *const Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.root, name });
    }

    fn identity(self: *const Fixture, name: []const u8) !storage.StorageIdentity {
        const full = try self.path(name);
        defer testing.allocator.free(full);
        var local = try storage.LocalFileSource.open(testing.io, full);
        defer local.close();
        return local.readable().identity();
    }

    /// A Track of release 1 on a file observed with an unmeasured embedded
    /// cover, as a scan before measuring left it.
    fn observeAudio(self: *Fixture, file_id: i64, name: []const u8) !void {
        const full = try self.path(name);
        defer testing.allocator.free(full);
        const stat = try self.identity(name);
        var statement = try self.library.database.prepare("INSERT INTO files(id) VALUES (?1);");
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        _ = try statement.step();
        var location = try self.library.database.prepare(
            \\INSERT INTO locations(file_id, volume_id, uri, size_bytes, modified_ns, state)
            \\VALUES (?1, 2, ?2, ?3, ?4, 'present');
        );
        defer location.deinit();
        try location.bindInt64(1, file_id);
        try location.bindText(2, full);
        try location.bindInt64(3, @intCast(stat.size));
        try location.bindInt64(4, @intCast(stat.modified_ns));
        _ = try location.step();
        var tags = try self.library.database.prepare(
            \\INSERT INTO observed_file_tags(file_id, artwork_mime_type, artwork_byte_size) VALUES (?1, 'image/png', 100);
        );
        defer tags.deinit();
        try tags.bindInt64(1, file_id);
        _ = try tags.step();
        var track = try self.library.database.prepare(
            \\INSERT INTO tracks(title, release_id, preferred_file_id) VALUES ('Song', 1, ?1);
        );
        defer track.deinit();
        try track.bindInt64(1, file_id);
        _ = try track.step();
    }

    /// An unmeasured folder image beside the Release's files.
    fn observeImage(self: *Fixture, name: []const u8) !void {
        const full = try self.path(name);
        defer testing.allocator.free(full);
        const stat = try self.identity(name);
        var statement = try self.library.database.prepare(
            \\INSERT INTO folder_images(volume_id, uri, mime, role, size_bytes, modified_ns)
            \\VALUES (2, ?1, 'image/png', 0, ?2, ?3);
        );
        defer statement.deinit();
        try statement.bindText(1, full);
        try statement.bindInt64(2, @intCast(stat.size));
        try statement.bindInt64(3, @intCast(stat.modified_ns));
        _ = try statement.step();
    }

    fn backfill(self: *Fixture) !Result {
        var pass: ArtworkBackfill = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .locations = &self.library.locations,
            .write_lane = self.library.write_lane,
            .database_handle = self.library.database,
        };
        return pass.run();
    }

    fn details(self: *Fixture, file_id: i64) !?ArtworkDetails {
        var statement = try self.library.database.prepare(
            "SELECT details FROM library_health_issues WHERE file_id = ?1 AND kind = ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(database.repository.HealthIssueKind.artwork_problem));
        if (try statement.step() != .row) return null;
        var copy: ArtworkDetails = .{};
        const text = statement.columnText(0);
        @memcpy(copy.buffer[0..text.len], text);
        copy.len = text.len;
        return copy;
    }
};

const ArtworkDetails = struct {
    buffer: [database.ArtworkFinding.max_details]u8 = undefined,
    len: usize = 0,

    fn text(self: *const ArtworkDetails) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn copyAudioFixture(directory: std.Io.Dir, name: []const u8, sub_path: []const u8) !void {
    const source = try std.fmt.allocPrint(testing.allocator, "fixtures/audio/{s}", .{name});
    defer testing.allocator.free(source);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, source, testing.allocator, .limited(4 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try directory.writeFile(testing.io, .{ .sub_path = sub_path, .data = bytes });
}

test "the backfill measures covers observed before measuring and settles their Release's artwork problem" {
    var fixture = try Fixture.init("file:orca-artwork-backfill-measures?mode=memory&cache=shared");
    defer fixture.deinit();
    try copyAudioFixture(fixture.directory.dir, "covered-reference.flac", "song.flac");
    try fixture.directory.dir.writeFile(testing.io, .{ .sub_path = "cover.png", .data = &pngBytes(300, 300) });
    try fixture.observeAudio(1, "song.flac");
    try fixture.observeImage("cover.png");
    try testing.expectEqual(@as(u64, 2), try database.repository.unmeasuredCoverCount(fixture.library.database));

    const result = try fixture.backfill();
    try testing.expectEqual(@as(u64, 2), result.covers_seen);
    try testing.expectEqual(@as(u64, 2), result.measured);
    try testing.expectEqual(@as(u64, 0), try database.repository.unmeasuredCoverCount(fixture.library.database));
    try testing.expectEqual(@as(i64, 16), try database.columns.scalar(
        fixture.library.database,
        "SELECT artwork_width FROM observed_file_tags WHERE file_id = 1;",
    ));
    try testing.expectEqual(@as(i64, 300), try database.columns.scalar(
        fixture.library.database,
        "SELECT width FROM folder_images;",
    ));
    const found = (try fixture.details(1)).?;
    try testing.expectEqualStrings("problem=conflicting", found.text());

    const again = try fixture.backfill();
    try testing.expectEqual(@as(u64, 0), again.covers_seen);
}

test "the backfill passes over covers whose bytes changed or are gone and measures them on a later run" {
    var fixture = try Fixture.init("file:orca-artwork-backfill-skips?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.directory.dir.writeFile(testing.io, .{ .sub_path = "cover.png", .data = &pngBytes(300, 300) });
    try fixture.observeImage("cover.png");
    try fixture.library.database.exec("UPDATE folder_images SET size_bytes = size_bytes + 1;");
    try copyAudioFixture(fixture.directory.dir, "covered-reference.flac", "song.flac");
    try fixture.observeAudio(1, "song.flac");
    try fixture.directory.dir.deleteFile(testing.io, "song.flac");

    const result = try fixture.backfill();
    try testing.expectEqual(@as(u64, 2), result.skipped);
    try testing.expectEqual(@as(u64, 0), result.measured);
    try testing.expectEqual(@as(u64, 2), try database.repository.unmeasuredCoverCount(fixture.library.database));

    try fixture.library.database.exec("UPDATE folder_images SET size_bytes = size_bytes - 1;");
    const later = try fixture.backfill();
    try testing.expectEqual(@as(u64, 1), later.measured);
    try testing.expectEqual(@as(u64, 1), try database.repository.unmeasuredCoverCount(fixture.library.database));
}

test "the measurable count leaves out embedded covers of missing files and covers under an offline root" {
    var fixture = try Fixture.init("file:orca-artwork-backfill-measurable?mode=memory&cache=shared");
    defer fixture.deinit();
    try copyAudioFixture(fixture.directory.dir, "covered-reference.flac", "song.flac");
    try copyAudioFixture(fixture.directory.dir, "covered-reference.flac", "gone.flac");
    try fixture.directory.dir.writeFile(testing.io, .{ .sub_path = "cover.png", .data = &pngBytes(300, 300) });
    try fixture.observeAudio(1, "song.flac");
    try fixture.observeAudio(2, "gone.flac");
    try fixture.observeImage("cover.png");
    try fixture.library.database.exec("UPDATE locations SET state = 'missing' WHERE file_id = 2;");
    try testing.expectEqual(@as(u64, 3), try database.repository.unmeasuredCoverCount(fixture.library.database));
    try testing.expectEqual(@as(u64, 2), try database.repository.measurableCoverCount(fixture.library.database, ""));

    const root_id = try fixture.library.library_roots.add(2, fixture.root);
    {
        var statement = try fixture.library.database.prepare("UPDATE locations SET root_id = ?1 WHERE file_id = 1;");
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .done) return error.SqlFailed;
        var images = try fixture.library.database.prepare("UPDATE folder_images SET root_id = ?1;");
        defer images.deinit();
        try images.bindInt64(1, root_id);
        if (try images.step() != .done) return error.SqlFailed;
    }
    var offline_ids: [32]u8 = undefined;
    const offline_roots = try std.fmt.bufPrint(&offline_ids, ",{d},", .{root_id});
    try testing.expectEqual(@as(u64, 2), try database.repository.measurableCoverCount(fixture.library.database, ""));
    try testing.expectEqual(@as(u64, 0), try database.repository.measurableCoverCount(fixture.library.database, offline_roots));
}

test "a cover whose bytes will not read is stored unreadable and raises no conflict" {
    var fixture = try Fixture.init("file:orca-artwork-backfill-unreadable?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.directory.dir.writeFile(testing.io, .{ .sub_path = "song.flac", .data = "not audio at all" });
    try fixture.directory.dir.writeFile(testing.io, .{ .sub_path = "cover.png", .data = &pngBytes(800, 800) });
    try fixture.observeAudio(1, "song.flac");
    try fixture.observeImage("cover.png");

    const result = try fixture.backfill();
    try testing.expectEqual(@as(u64, 2), result.measured);
    try testing.expectEqual(image_header.unreadable_hash, try database.columns.scalar(
        fixture.library.database,
        "SELECT artwork_hash FROM observed_file_tags WHERE file_id = 1;",
    ));
    try testing.expectEqual(@as(?ArtworkDetails, null), try fixture.details(1));
}

test "the backfill measures a cover the Library kept before measuring from its stored bytes, and marks one whose header will not read unreadable" {
    var fixture = try Fixture.init("file:orca-artwork-backfill-kept?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.library.database.exec(
        \\INSERT INTO files(id) VALUES (1);
        \\INSERT INTO observed_file_tags(file_id) VALUES (1);
        \\INSERT INTO tracks(title, release_id, preferred_file_id) VALUES ('Song', 1, 1);
    );
    var statement = try fixture.library.database.prepare(
        \\INSERT INTO release_artwork(release_id, kind, source, image, mime, fetched_at)
        \\VALUES (1, 0, 2, ?1, 'image/png', 0), (1, 1, 2, ?2, 'image/png', 0);
    );
    defer statement.deinit();
    try statement.bindBlob(1, &pngBytes(300, 300));
    try statement.bindBlob(2, "\x89PNG\r\n\x1a\n");
    _ = try statement.step();
    try testing.expectEqual(@as(u64, 2), try database.repository.unmeasuredCoverCount(fixture.library.database));

    const result = try fixture.backfill();
    try testing.expectEqual(@as(u64, 2), result.covers_seen);
    try testing.expectEqual(@as(u64, 2), result.measured);
    try testing.expectEqual(@as(i64, 300), try database.columns.scalar(
        fixture.library.database,
        "SELECT width FROM release_artwork WHERE kind = 0;",
    ));
    try testing.expectEqual(database.repository.unreadable_cover_side, try database.columns.scalar(
        fixture.library.database,
        "SELECT width FROM release_artwork WHERE kind = 1;",
    ));
    try testing.expectEqualStrings("problem=undersized width=300 height=300", (try fixture.details(1)).?.text());
    try testing.expectEqual(@as(u64, 0), try database.repository.unmeasuredCoverCount(fixture.library.database));
    try testing.expectEqual(@as(u64, 0), (try fixture.backfill()).covers_seen);
}

test "a kept front whose header will not read is read once and raises no undersized problem" {
    var fixture = try Fixture.init("file:orca-artwork-backfill-kept-unreadable?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.library.database.exec(
        \\INSERT INTO files(id) VALUES (1);
        \\INSERT INTO observed_file_tags(file_id) VALUES (1);
        \\INSERT INTO tracks(title, release_id, preferred_file_id) VALUES ('Song', 1, 1);
    );
    var statement = try fixture.library.database.prepare(
        \\INSERT INTO release_artwork(release_id, kind, source, image, mime, fetched_at)
        \\VALUES (1, 0, 2, ?1, 'image/png', 0);
    );
    defer statement.deinit();
    try statement.bindBlob(1, "\x89PNG\r\n\x1a\n");
    _ = try statement.step();

    const result = try fixture.backfill();
    try testing.expectEqual(@as(u64, 1), result.measured);
    try testing.expectEqual(database.repository.unreadable_cover_side, try database.columns.scalar(
        fixture.library.database,
        "SELECT height FROM release_artwork WHERE kind = 0;",
    ));
    try testing.expectEqual(@as(?ArtworkDetails, null), try fixture.details(1));
    try testing.expectEqual(@as(u64, 0), (try fixture.backfill()).covers_seen);

    try fixture.library.release_artwork.set(1, .back, "\x89PNG\r\n\x1a\n", "image/png", null, 0);
    try testing.expectEqual(database.repository.unreadable_cover_side, try database.columns.scalar(
        fixture.library.database,
        "SELECT width FROM release_artwork WHERE kind = 1;",
    ));
    try testing.expectEqual(@as(u64, 0), try database.repository.unmeasuredCoverCount(fixture.library.database));
}
