//! Repairs `files` rows whose declared audio properties are missing.
//!
//! The scanner probes a file's headers only when its bytes changed, and that
//! is deliberate: the unchanged fast path is what makes rescanning a large
//! library nearly free. The consequence is that a library scanned before
//! probing existed keeps null `duration_ms`, `sample_rate` and `channels`
//! indefinitely, because a music collection's bytes essentially never change.
//! A Track whose duration is null has nothing for a transport bar to draw
//! against and shows no length in a listing.
//!
//! This pass is the other direction, exactly as the projection is the other
//! direction from the scanner: it repairs by `files.id`, never by walking a
//! filesystem, and it touches only the rows that are actually incomplete.
//!
//! It observes the same law the scanner does — it writes `files` and the one
//! health-issue kind it owns, and nothing else. Turning repaired properties
//! into Track durations is the projection's job, which is why each committed
//! batch is handed to the projection exactly as a scan batch is.

const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const storage = @import("../storage/root.zig");
const projection = @import("projection.zig");
const scanner = @import("scanner.zig");

pub const CancellationToken = scanner.CancellationToken;

pub const Result = struct {
    /// Rows selected and examined.
    files_seen: u64 = 0,
    /// Rows whose properties were rewritten from a successful probe.
    changed: u64 = 0,
    /// Rows probed successfully that still declare no duration. Rare, and left
    /// for a later run rather than papered over with a zero.
    unchanged: u64 = 0,
    /// Rows whose file is not reachable or is not audio at all. Not a failure:
    /// files go missing, and `locations.state` already models absence.
    unsupported: u64 = 0,
    /// Rows whose file opened and then refused to decode.
    errors: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
    /// What the projection made of the rows this pass repaired.
    projection: projection.Result = .{},
};

/// What one probe decided about one row, held until its batch commits.
const Repair = struct {
    file_id: i64,
    outcome: Outcome,

    const Outcome = union(enum) {
        /// Headers parsed. Written to the row; an empty `codec` cannot occur
        /// here, because a decoder that opened always names its encoding.
        probed: database.repository.FilePropertyUpdate,
        /// Opened and refused to decode. Raises the one health issue this pass
        /// owns; the row keeps whatever it already said.
        unreadable: []const u8,
        /// Not reachable, or not audio. Counted and passed over, with no
        /// health issue: a location that is gone is already `missing`, and
        /// filing 22,060 errors when a drive is unmounted would bury every
        /// real finding under a mount problem the library already records.
        skipped,
    };
};

pub const PropertyBackfill = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *database.FileRepository,
    health_issues: *database.repository.HealthIssueRepository,
    write_lane: *database.repository.WriteLane,
    database_handle: database.sqlite.Database,
    /// Decoders used to read each row's declared properties. Injectable so a
    /// test can narrow the set; absent, the builtins are used.
    codecs: ?*const codec.CodecRegistry = null,
    cancellation: ?*const CancellationToken = null,
    /// Rows examined so far, published for a host showing progress. Unlike a
    /// filesystem walk this pass has an honest denominator before it starts,
    /// which the runtime reads separately through `incompletePropertiesCount`.
    progress: ?*std.atomic.Value(u64) = null,
    /// Rows per selected page and per bounded commit.
    batch_size: usize = 256,
    /// Re-probe every row, including rows that already declare properties.
    ///
    /// Off by default, and that is the important half. A probe that already
    /// succeeded read the container's own declarations; running it again reads
    /// the same bytes and writes the same numbers, so the default pass costs
    /// one indexed lookup on a healthy library instead of 22,060 file opens.
    /// Force exists for the case the default cannot serve — a probe
    /// implementation that got *better*, such as MPEG length gaining Xing and
    /// LAME awareness — where the stored value is present but no longer what
    /// this build would compute. It is therefore an explicit operator action,
    /// not a fallback, and it is **not** restart-resumable: a re-probed row
    /// still matches, so an interrupted force run restarts from the first row
    /// rather than resuming.
    force: bool = false,
    /// Where repaired properties become Track durations. Absent, the rows are
    /// repaired and `tracks` is refreshed by a later standalone reprojection.
    projection: ?*projection.Projection = null,
    /// File ids the last batch committed, held until the projection has
    /// consumed them.
    projected: std.ArrayList(i64) = .empty,

    pub fn deinit(self: *PropertyBackfill) void {
        self.projected.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn run(self: *PropertyBackfill) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        var result: Result = .{};
        if (self.isCancelled()) {
            result.cancelled = true;
            return result;
        }
        var builtin_codecs = codec.CodecRegistry.builtins();
        const codecs = self.codecs orelse &builtin_codecs;
        const page_limit: u32 = @intCast(@min(
            self.batch_size,
            @as(usize, database.repository.max_page),
        ));

        var repairs: std.ArrayList(Repair) = .empty;
        defer repairs.deinit(self.allocator);
        // The cursor is a file id, so a page whose rows this run could not
        // repair does not make the next page re-serve them. Nothing else
        // checkpoints: which rows still owe a probe is a property of the rows.
        var cursor: i64 = 0;
        while (true) {
            var page = try self.files.incompletePropertiesPage(
                self.allocator,
                cursor,
                page_limit,
                self.force,
            );
            defer page.deinit();
            if (page.items.len == 0) break;

            for (page.items) |item| {
                if (self.isCancelled()) {
                    result.cancelled = true;
                    break;
                }
                cursor = item.id;
                result.files_seen += 1;
                if (self.progress) |counter| counter.store(result.files_seen, .release);
                try repairs.append(self.allocator, .{
                    .file_id = item.id,
                    .outcome = self.probe(codecs, item.uri),
                });
            }
            // A cancelled run still commits what it already probed, so the
            // next run resumes from a shorter list rather than repeating work
            // it has already paid for.
            if (repairs.items.len > 0) {
                try self.commit(repairs.items, &result);
                repairs.clearRetainingCapacity();
                result.batches_committed += 1;
                try self.project(&result);
            }
            if (result.cancelled) break;
        }
        try self.project(&result);
        return result;
    }

    fn isCancelled(self: *const PropertyBackfill) bool {
        const token = self.cancellation orelse return false;
        return token.isCancelled();
    }

    /// Headers only, never audio — the same contract the scanner probes under.
    fn probe(
        self: *PropertyBackfill,
        codecs: *const codec.CodecRegistry,
        uri: []const u8,
    ) Repair.Outcome {
        if (uri.len == 0) return .skipped;
        var local = storage.LocalFileSource.open(self.io, uri) catch return .skipped;
        defer local.close();
        // Detected here rather than taken from the row, because the row is
        // exactly what may be wrong. A library scanned before sniffing looked
        // past an ID3v2 tag recorded 104 FLAC files as MPEG, and nothing else
        // will ever correct that column: the scanner's unchanged fast path
        // never re-reads a file whose bytes have not moved, which for a music
        // collection is every file, for ever.
        const detection = storage.format.detect(local.readable()) catch null;
        const properties = codecs.probeDetected(self.allocator, local.readable()) catch |err| {
            // Sniffing decides who opens a file, so a container nothing claims
            // is a row that is not audio rather than a file that is broken.
            if (err == error.UnsupportedAudioFormat) return .skipped;
            return .{ .unreadable = @errorName(err) };
        };
        return .{ .probed = .{
            .codec = properties.codec orelse "",
            .sample_rate = optionalCount(properties.sample_rate),
            .bit_depth = optionalCount(properties.bit_depth),
            .channels = optionalCount(properties.channels),
            .duration_ms = optionalCount(properties.duration_ms),
            .audio_format = if (detection) |resolved|
                @intFromEnum(resolved.format)
            else
                null,
        } };
    }

    /// One bounded commit per batch, holding the Library's one write lane.
    fn commit(self: *PropertyBackfill, repairs: []const Repair, result: *Result) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.database_handle.exec("BEGIN IMMEDIATE;");
        errdefer self.database_handle.exec("ROLLBACK;") catch {};
        for (repairs) |repair| switch (repair.outcome) {
            .probed => |properties| {
                try self.files.updatePropertiesLocked(repair.file_id, properties);
                // The pass owns this kind outright, so retiring it here cannot
                // erase a finding some other worker made.
                try self.health_issues.clearLocked(repair.file_id, .unreadable_file);
                if (properties.duration_ms == null) {
                    result.unchanged += 1;
                } else {
                    result.changed += 1;
                }
                if (self.projection != null)
                    try self.projected.append(self.allocator, repair.file_id);
            },
            .unreadable => |details| {
                try self.health_issues.recordLocked(repair.file_id, .{
                    .kind = .unreadable_file,
                    .severity = .warning,
                    .details = details,
                });
                result.errors += 1;
            },
            .skipped => result.unsupported += 1,
        };
        try self.database_handle.exec("COMMIT;");
    }

    /// Reproject exactly the rows this pass repaired, outside the batch
    /// transaction and after the write lane is released, because the
    /// projection takes both itself.
    fn project(self: *PropertyBackfill, result: *Result) !void {
        const target = self.projection orelse return;
        if (self.projected.items.len == 0) return;
        const batch = try target.run(.{ .files = self.projected.items });
        self.projected.clearRetainingCapacity();
        result.projection.folders_visited += batch.folders_visited;
        result.projection.groups_projected += batch.groups_projected;
        result.projection.files_projected += batch.files_projected;
        result.projection.tracks_written += batch.tracks_written;
        result.projection.releases_written += batch.releases_written;
        result.projection.recordings_created += batch.recordings_created;
        result.projection.compilations += batch.compilations;
        result.projection.filename_titles += batch.filename_titles;
        result.projection.synthetic_positions += batch.synthetic_positions;
        result.projection.displaced_positions += batch.displaced_positions;
    }
};

/// A property too large for the column is stored as unknown rather than as a
/// wrapped or saturated number.
fn optionalCount(value: anytype) ?i64 {
    return std.math.cast(i64, value orelse return null);
}

const testing = std.testing;
const metadata = @import("../metadata/model.zig");

/// A root of real files the probe can actually open, plus the Library rows
/// that point at them.
const Fixture = struct {
    directory: std.testing.TmpDir,
    root: []u8,
    library: database.LibraryDatabase,

    fn init(name: [:0]const u8) !Fixture {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const root = try std.fmt.allocPrint(
            testing.allocator,
            ".zig-cache/tmp/{s}",
            .{directory.sub_path},
        );
        errdefer testing.allocator.free(root);
        return .{
            .directory = directory,
            .root = root,
            .library = try database.LibraryDatabase.open(testing.allocator, testing.io, name),
        };
    }

    fn deinit(self: *Fixture) void {
        self.library.close();
        testing.allocator.free(self.root);
        self.directory.cleanup();
    }

    fn writeBytes(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.directory.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    }

    fn copyFixture(self: *Fixture, name: []const u8) !void {
        const source = try std.fmt.allocPrint(testing.allocator, "fixtures/audio/{s}", .{name});
        defer testing.allocator.free(source);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            source,
            testing.allocator,
            .limited(4 * 1024 * 1024),
        );
        defer testing.allocator.free(bytes);
        try self.writeBytes(name, bytes);
    }

    /// A `files` row that names a path under the root, with whatever the
    /// caller wants it to already declare.
    fn record(
        self: *Fixture,
        name: []const u8,
        upsert: database.FileUpsert,
        tags: metadata.ObservedTags,
    ) !i64 {
        const uri = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.root, name });
        defer testing.allocator.free(uri);
        const file_id = try self.library.files.create(upsert);
        _ = try self.library.locations.upsert(.{
            .file_id = file_id,
            .volume_id = database.LibraryDatabase.null_volume,
            .uri = uri,
            .state = .present,
        });
        try self.library.observed_tags.upsert(.{ .file_id = file_id, .values = tags });
        return file_id;
    }

    fn backfill(self: *Fixture) PropertyBackfill {
        return .{
            .allocator = testing.allocator,
            .io = testing.io,
            .files = &self.library.files,
            .health_issues = &self.library.health_issues,
            .write_lane = self.library.write_lane,
            .database_handle = self.library.database,
        };
    }
};

const reference_tags: metadata.ObservedTags = .{
    .title = "One",
    .artist = "Artist",
    .album = "Album",
    .album_artist = "Artist",
    .track_number = 1,
};

fn scalar(library: *database.LibraryDatabase, sql: [:0]const u8) !i64 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

/// Every `detail` row of an `EXPLAIN QUERY PLAN`, joined, which is the column
/// that names the index a step used.
fn queryPlan(library: *database.LibraryDatabase, sql: [:0]const u8) ![]u8 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(testing.allocator);
    while (try statement.step() == .row) {
        try joined.appendSlice(testing.allocator, statement.columnText(3));
        try joined.append(testing.allocator, '\n');
    }
    return joined.toOwnedSlice(testing.allocator);
}

fn text(library: *database.LibraryDatabase, sql: [:0]const u8) ![]u8 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return testing.allocator.dupe(u8, statement.columnText(0));
}

test "selecting the rows that still owe a probe is an index search, not a table scan" {
    // The predicate and the partial index are one shared string precisely so
    // this stays true. Paraphrasing either half would still return the right
    // rows, silently, by reading every file row in the library.
    var fixture = try Fixture.init("file:orca-backfill-plan?mode=memory&cache=shared");
    defer fixture.deinit();
    const plan = try queryPlan(
        &fixture.library,
        "EXPLAIN QUERY PLAN SELECT files.id FROM files WHERE files.id > 0 AND (" ++
            database.repository.incomplete_properties_predicate ++
            ") ORDER BY files.id LIMIT 256;",
    );
    defer testing.allocator.free(plan);
    try testing.expect(std.mem.indexOf(u8, plan, "files_incomplete_properties") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
}

test "a backfill reads only the rows whose declared properties are missing" {
    var fixture = try Fixture.init("file:orca-backfill-selective?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("tagged-reference.flac");
    try fixture.copyFixture("vbr-xing-reference.mp3");
    // Already probed by some earlier scan, and complete.
    _ = try fixture.record("tagged-reference.flac", .{
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
        .codec = "flac",
        .sample_rate = 44100,
        .bit_depth = 16,
        .channels = 2,
        .duration_ms = 200,
    }, reference_tags);
    const incomplete = try fixture.record("vbr-xing-reference.mp3", .{
        .audio_format = @intFromEnum(storage.AudioFormat.mp3),
    }, reference_tags);

    var pass = fixture.backfill();
    defer pass.deinit();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.files_seen);
    try testing.expectEqual(@as(u64, 1), result.changed);
    try testing.expectEqual(@as(u64, 2000), @as(u64, @intCast(try scalar(
        &fixture.library,
        "SELECT duration_ms FROM files WHERE codec='mp3';",
    ))));
    try testing.expectEqual(incomplete, try scalar(
        &fixture.library,
        "SELECT id FROM files WHERE codec='mp3';",
    ));

    // And a second run has nothing left to do at all.
    const second = try pass.run();
    try testing.expectEqual(@as(u64, 0), second.files_seen);
}

test "a lossy row and a lossless row are told apart by the codec the backfill wrote" {
    var fixture = try Fixture.init("file:orca-backfill-codec?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("tagged-reference.flac");
    try fixture.copyFixture("vbr-xing-reference.mp3");
    _ = try fixture.record("tagged-reference.flac", .{}, reference_tags);
    _ = try fixture.record("vbr-xing-reference.mp3", .{}, reference_tags);

    var pass = fixture.backfill();
    defer pass.deinit();
    _ = try pass.run();
    const lossless = try text(&fixture.library, "SELECT codec FROM files WHERE id=1;");
    defer testing.allocator.free(lossless);
    const lossy = try text(&fixture.library, "SELECT codec FROM files WHERE id=2;");
    defer testing.allocator.free(lossy);
    try testing.expectEqualStrings("flac", lossless);
    try testing.expectEqualStrings("mp3", lossy);
    try testing.expect(codec.decoder.codec_id.isLossless(lossless));
    try testing.expect(!codec.decoder.codec_id.isLossless(lossy));
}

test "a file that will not decode leaves its row alone and is reported as unreadable" {
    var fixture = try Fixture.init("file:orca-backfill-unreadable?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.writeBytes("broken.flac", "fLaC but not a stream");
    const file_id = try fixture.record("broken.flac", .{
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
        .size_bytes = 21,
    }, reference_tags);

    var pass = fixture.backfill();
    defer pass.deinit();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.errors);
    try testing.expectEqual(@as(u64, 0), result.changed);
    // The row keeps exactly what it had: a probe that failed knows nothing.
    try testing.expectEqual(@as(i64, 21), try scalar(
        &fixture.library,
        "SELECT size_bytes FROM files;",
    ));
    try testing.expectEqual(@as(i64, 1), try scalar(
        &fixture.library,
        "SELECT count(*) FROM files WHERE duration_ms IS NULL;",
    ));
    var issues = try fixture.library.health_issues.page(testing.allocator, 8, 0);
    defer issues.deinit();
    try testing.expectEqual(@as(usize, 1), issues.items.len);
    try testing.expectEqual(file_id, issues.items[0].file_id);
    try testing.expectEqual(
        database.HealthIssueKind.unreadable_file,
        issues.items[0].kind,
    );

    // Repairing the bytes retires the issue, because this pass owns the kind
    // outright and may therefore clear it.
    try fixture.copyFixture("tagged-reference.flac");
    try fixture.library.database.exec(
        \\UPDATE locations SET uri = replace(uri, 'broken.flac', 'tagged-reference.flac');
    );
    _ = try pass.run();
    try testing.expectEqual(@as(u64, 0), try fixture.library.health_issues.count());
}

test "a file that is not there is counted without being reported as a defect" {
    // Files go missing, drives get unmounted, and `locations.state` already
    // models that. Filing a health issue per absent file would bury every real
    // finding under a mount problem the library has already recorded.
    var fixture = try Fixture.init("file:orca-backfill-missing?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("tagged-reference.flac");
    _ = try fixture.record("not-written-to-disk.flac", .{}, reference_tags);
    _ = try fixture.record("tagged-reference.flac", .{}, reference_tags);

    var pass = fixture.backfill();
    defer pass.deinit();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.files_seen);
    try testing.expectEqual(@as(u64, 1), result.unsupported);
    try testing.expectEqual(@as(u64, 1), result.changed);
    try testing.expectEqual(@as(u64, 0), try fixture.library.health_issues.count());
}

/// A decoder that cancels the pass part-way through a batch.
///
/// Racing a watcher thread against a probe would decide *between batches* most
/// of the time, which is the case that needs no partial commit at all. The
/// invariant worth protecting is the other one: a run interrupted with rows
/// already probed and not yet written must still write them. Making the probe
/// itself pull the trigger is the only way to land there every time.
const InterruptingCodec = struct {
    var token: ?*CancellationToken = null;
    var probes: usize = 0;
    var cancel_at: usize = 0;

    fn open(
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) anyerror!codec.Decoder {
        probes += 1;
        if (probes >= cancel_at) {
            if (token) |requested| requested.cancel();
        }
        return codec.flac.openDecoder(allocator, source);
    }

    fn registry(stop: *CancellationToken, after: usize) codec.CodecRegistry {
        token = stop;
        probes = 0;
        cancel_at = after;
        var codecs: codec.CodecRegistry = .{};
        codecs.register(.{
            .name = "interrupting FLAC",
            .format = .flac,
            .open = open,
        }) catch unreachable;
        return codecs;
    }
};

test "an interrupted backfill commits what it probed and resumes at the rest" {
    var fixture = try Fixture.init("file:orca-backfill-resume?mode=memory&cache=shared");
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "fixtures/audio/tagged-reference.flac",
        testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer testing.allocator.free(bytes);
    for (0..6) |index| {
        const name = try std.fmt.allocPrint(testing.allocator, "copy-{d}.flac", .{index});
        defer testing.allocator.free(name);
        try fixture.writeBytes(name, bytes);
        _ = try fixture.record(name, .{}, reference_tags);
    }

    // One page holds all six, so cancelling at the third probe leaves three
    // rows probed and unwritten at the moment the run gives up.
    var token: CancellationToken = .{};
    const codecs = InterruptingCodec.registry(&token, 3);
    var first = fixture.backfill();
    defer first.deinit();
    first.cancellation = &token;
    first.codecs = &codecs;
    const interrupted = try first.run();
    try testing.expect(interrupted.cancelled);
    try testing.expectEqual(@as(u64, 3), interrupted.files_seen);
    try testing.expectEqual(@as(u64, 3), interrupted.changed);
    try testing.expectEqual(@as(i64, 3), try scalar(
        &fixture.library,
        "SELECT count(*) FROM files WHERE duration_ms IS NULL;",
    ));

    // The second run asks the same question and gets the shorter answer. It
    // never re-serves a row the first run already repaired.
    var second = fixture.backfill();
    defer second.deinit();
    const resumed = try second.run();
    try testing.expectEqual(@as(u64, 3), resumed.files_seen);
    try testing.expectEqual(@as(u64, 3), resumed.changed);
    try testing.expectEqual(@as(i64, 0), try scalar(
        &fixture.library,
        "SELECT count(*) FROM files WHERE duration_ms IS NULL;",
    ));
}

test "a backfill fills the track durations derived from the rows it repaired" {
    // The user-visible half. A backfill that repaired `files` and left
    // `tracks.duration_ms` at zero has not solved anything a transport bar or
    // a track listing can show.
    var fixture = try Fixture.init("file:orca-backfill-projected?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("tagged-reference.flac");
    _ = try fixture.record("tagged-reference.flac", .{
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
    }, reference_tags);

    var pass = projection.Projection{
        .allocator = testing.allocator,
        .library = &fixture.library,
    };
    _ = try pass.run(.all);
    try testing.expectEqual(@as(i64, 1), try scalar(
        &fixture.library,
        "SELECT count(*) FROM tracks WHERE duration_ms IS NULL;",
    ));

    var backfill = fixture.backfill();
    defer backfill.deinit();
    backfill.projection = &pass;
    const result = try backfill.run();
    try testing.expectEqual(@as(u64, 1), result.projection.files_projected);
    try testing.expectEqual(@as(i64, 200), try scalar(
        &fixture.library,
        "SELECT duration_ms FROM tracks;",
    ));
}

test "forcing a backfill re-probes a row that already declares properties" {
    var fixture = try Fixture.init("file:orca-backfill-force?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("tagged-reference.flac");
    _ = try fixture.record("tagged-reference.flac", .{
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
        .codec = "flac",
        .sample_rate = 44100,
        .bit_depth = 16,
        .channels = 2,
        // What an older, worse probe stored. Only a force run can correct a
        // value that is present but wrong.
        .duration_ms = 999_999,
    }, reference_tags);

    var pass = fixture.backfill();
    defer pass.deinit();
    try testing.expectEqual(@as(u64, 0), (try pass.run()).files_seen);
    pass.force = true;
    try testing.expectEqual(@as(u64, 1), (try pass.run()).files_seen);
    try testing.expectEqual(@as(i64, 200), try scalar(
        &fixture.library,
        "SELECT duration_ms FROM files;",
    ));
}

test "a row that names the wrong container is corrected by the probe that reads it" {
    // A library scanned before sniffing looked past an ID3v2 tag recorded 104
    // real FLAC files as MPEG. Nothing else will ever fix that column: the
    // scanner's unchanged fast path never re-reads a file whose bytes have not
    // moved, and a music collection's bytes never move. This pass is the only
    // thing that opens those rows again.
    var fixture = try Fixture.init("file:orca-backfill-container?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("id3-prefixed-reference.flac");
    // Exactly what the old sniffer wrote: ID3 at byte zero, therefore MPEG.
    const misfiled = try fixture.record("id3-prefixed-reference.flac", .{
        .audio_format = @intFromEnum(storage.AudioFormat.mp3),
    }, reference_tags);

    var pass = fixture.backfill();
    defer pass.deinit();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.changed);

    try testing.expectEqual(
        @as(i64, @intFromEnum(storage.AudioFormat.flac)),
        try scalar(&fixture.library, "SELECT audio_format FROM files WHERE id = 1;"),
    );
    try testing.expectEqual(misfiled, try scalar(
        &fixture.library,
        "SELECT id FROM files WHERE codec = 'flac';",
    ));
}
