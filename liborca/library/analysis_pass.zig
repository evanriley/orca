//! Measures every file in a Library that has not been measured yet.
//!
//! `analysis/` has computed loudness, peak, clipping, silence and a temporal
//! fingerprint for a long time, but only ever for one file a human named. A
//! measurement nothing runs at library scale is a measurement nothing can use:
//! ReplayGain on playback needs a figure for the track about to play, and
//! duplicate detection needs fingerprints for files nobody has thought about.
//!
//! It is the property backfill's shape — a runtime job on the shared
//! `JobWorker`, cancellable through the same token, bounded commits, row
//! selection through an indexed query rather than a walk — with one difference
//! that governs everything else: **the backfill reads headers, this decodes
//! whole files.** So cancellation, resumption and progress are load-bearing
//! rather than polite, the Library's write lane is never held across a decode,
//! and a batch is small enough that an interrupted run loses a bounded amount
//! of the most expensive work in the codebase.
//!
//! Like the scanner and the backfill it writes only what it owns: the analysis
//! results, the audio hash it just computed, and the health-issue kinds that
//! belong to a pass which actually decoded the audio: `corrupt_audio`,
//! `clipping`, `excessive_silence` and `missing_analysis`.

const std = @import("std");
const analysis = @import("../analysis/root.zig");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const storage = @import("../storage/root.zig");
const scanner = @import("scanner.zig");

pub const CancellationToken = scanner.CancellationToken;
const CurrentItem = scanner.CurrentItem;

pub const Result = struct {
    /// Rows selected and carried through to a commit.
    files_seen: u64 = 0,
    /// Rows measured with a loudness figure, which is the useful outcome:
    /// these are the files playback can now correct.
    changed: u64 = 0,
    /// Rows measured whose audio has no gateable loudness — too short, or
    /// silent. Stored like any other measurement, so they are not re-decoded
    /// on every run, but they yield no correction.
    unchanged: u64 = 0,
    /// Rows this pass declined: not reachable, not audio, or an identity the
    /// Library's own record no longer matches. Not failures — `locations.state`
    /// models absence and a scan repairs a stale identity — so none of them
    /// files a health issue.
    unsupported: u64 = 0,
    /// Rows whose file opened and then would not decode.
    errors: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
    /// Bytes of encoded result written. Analysis storage is not incidental at
    /// library scale, so the pass reports it rather than leaving an operator
    /// to discover it from a file size.
    bytes_stored: u64 = 0,
};

/// What one file's analysis decided, held until its batch commits.
const Measurement = struct {
    file_id: i64,
    outcome: Outcome,

    const Measured = struct {
        /// The identity the measurement was taken from, which is also the one
        /// it is filed under. Never the row's claim about the file.
        source_identity: quick_hash.Digest,
        diagnostics_bytes: []u8,
        fingerprint_bytes: []u8,
        /// Null when the audio is too short to fingerprint or Chromaprint
        /// failed; the other measurements are stored regardless.
        chromaprint_bytes: ?[]u8,
        /// BLAKE3 over the decoded samples: tier 4 of the identity cascade,
        /// and the only tier that survives Orca writing a tag into the file.
        audio_hash: [32]u8,
        has_loudness: bool,
        integrated_lufs: ?f32,
        clipped_runs: u64,
        clipped_samples: u64,
        silent_frames: u64,
        decoded_frames: u64,
    };

    const Outcome = union(enum) {
        measured: Measured,
        /// Opened and refused to decode. Raises `corrupt_audio`, the kind that
        /// belongs to a pass which read the whole stream — the property
        /// backfill deliberately cannot raise or clear it, because a
        /// header-only probe has not looked at the audio.
        unreadable: []const u8,
        /// Not reachable, not audio, or the Library's recorded identity for
        /// the file is not the file's identity any more. Counted and passed
        /// over with no health issue: filing a defect per file when a drive
        /// is unmounted would bury every real finding.
        skipped,

        fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
            switch (self) {
                .measured => |value| {
                    allocator.free(value.diagnostics_bytes);
                    allocator.free(value.fingerprint_bytes);
                    if (value.chromaprint_bytes) |bytes| allocator.free(bytes);
                },
                .unreadable, .skipped => {},
            }
        }
    };

    fn deinit(self: Measurement, allocator: std.mem.Allocator) void {
        self.outcome.deinit(allocator);
    }
};

/// Logical processors, at least 1 and at most `maxInt(u16)`: the most
/// analysis threads that can each have a processor of their own.
pub fn availableThreads() u16 {
    const count = std.Thread.getCpuCount() catch return 1;
    return @intCast(std.math.clamp(count, 1, std.math.maxInt(u16)));
}

/// One thread fewer than `availableThreads`, and at least 1, so playback and
/// the host keep a processor while the library is measured.
pub fn defaultThreads() u16 {
    return @max(1, availableThreads() - 1);
}

/// One page of candidates measured by several threads at once. Each thread
/// claims the next index and writes only that index's slot, and the
/// coordinator reads the slots only after joining every thread.
const Batch = struct {
    pass: *const LibraryAnalysis,
    codecs: *const codec.CodecRegistry,
    items: []const database.repository.AnalysisCandidate,
    /// Null for a file no thread claimed.
    slots: []?(anyerror!Measurement.Outcome),
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn work(self: *Batch, io: std.Io) void {
        while (!self.failed.load(.acquire) and !self.pass.isCancelled()) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.items.len) return;
            if (self.pass.current_item) |current| current.set(self.items[index].uri);
            const outcome = self.pass.measure(io, self.codecs, self.items[index]);
            self.slots[index] = outcome;
            if (outcome) |_| {
                if (self.pass.progress) |counter| _ = counter.fetchAdd(1, .release);
            } else |err| switch (err) {
                error.Cancelled => return,
                else => {
                    self.failed.store(true, .release);
                    return;
                },
            }
        }
    }

    fn helper(self: *Batch) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        self.work(threaded.io());
    }

    fn deinitSlots(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| {
            if (slot.*) |value| {
                if (value) |outcome| outcome.deinit(allocator) else |_| {}
            }
            slot.* = null;
        }
    }
};

pub const LibraryAnalysis = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *database.FileRepository,
    analysis_cache: *database.AnalysisCacheRepository,
    health_issues: *database.repository.HealthIssueRepository,
    write_lane: *database.repository.WriteLane,
    database_handle: database.sqlite.Database,
    /// Decoders used to read each file. Injectable so a test can narrow the
    /// set; absent, the builtins are used.
    codecs: ?*const codec.CodecRegistry = null,
    cancellation: ?*const CancellationToken = null,
    current_item: ?*CurrentItem = null,
    /// Rows carried to a commit so far, published for a host showing progress.
    /// The denominator is separate and indexed: `unanalyzedCount`.
    progress: ?*std.atomic.Value(u64) = null,
    /// Files decoded at once. A page of `batch_size` files is shared between
    /// at most this many threads, so more threads than `batch_size` gain
    /// nothing. Null takes `defaultThreads`.
    threads: ?u16 = null,
    /// Files per selected page and per bounded commit.
    ///
    /// Much smaller than the backfill's 256 on purpose. A batch is the unit of
    /// work an interrupted run throws away, and here one unit is a whole file
    /// decoded end to end rather than one header read.
    batch_size: usize = 32,
    /// The measurement this pass produces.
    ///
    /// Deliberately not a knob on the job: the playback path looks a
    /// correction up under the canonical parameters, so a library measured
    /// under anything else would store results no Player would ever adopt.
    /// It is a field only so a test can shrink the waveform it does not read.
    parameters: analysis.diagnostics.Parameters = .{},
    /// Measures this one file again, whether or not it still owes a
    /// measurement, and settles its health; nothing else is selected.
    only_file_id: ?i64 = null,

    pub fn run(self: *LibraryAnalysis) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        const threads: usize = self.threads orelse defaultThreads();
        if (threads == 0) return error.InvalidThreadCount;
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
        const measurement_selector = self.selector();

        const slots = try self.allocator.alloc(?(anyerror!Measurement.Outcome), page_limit);
        defer self.allocator.free(slots);
        @memset(slots, null);
        const helpers = try self.allocator.alloc(std.Thread, @min(threads, page_limit) - 1);
        defer self.allocator.free(helpers);
        var measurements: std.ArrayList(Measurement) = .empty;
        defer {
            for (measurements.items) |item| item.deinit(self.allocator);
            measurements.deinit(self.allocator);
        }
        // A file id, not an offset: a file this run declined does not make the
        // next page re-serve it, and nothing else checkpoints, because which
        // files still owe a measurement is a property of the rows.
        var cursor: i64 = 0;
        while (true) {
            var page = if (self.only_file_id) |file_id|
                try self.files.analysisCandidate(self.allocator, file_id)
            else
                try self.files.unanalyzedPage(
                    self.allocator,
                    cursor,
                    page_limit,
                    measurement_selector,
                );
            defer page.deinit();
            if (page.items.len == 0) break;
            cursor = page.items[page.items.len - 1].id;

            var batch: Batch = .{
                .pass = self,
                .codecs = codecs,
                .items = page.items,
                .slots = slots[0..page.items.len],
            };
            defer batch.deinitSlots(self.allocator);
            self.measureBatch(&batch, helpers[0..@min(helpers.len, page.items.len - 1)]);
            try measurements.ensureUnusedCapacity(self.allocator, batch.slots.len);
            for (batch.slots, page.items) |*slot, item| {
                const outcome = (slot.* orelse error.Cancelled) catch |err| switch (err) {
                    // Interrupted mid-decode, or never started. The partial
                    // work is discarded and the file is not counted: it was
                    // not examined, and the run that resumes will select it
                    // again.
                    error.Cancelled => {
                        result.cancelled = true;
                        continue;
                    },
                    else => return err,
                };
                slot.* = null;
                result.files_seen += 1;
                measurements.appendAssumeCapacity(.{ .file_id = item.id, .outcome = outcome });
            }
            // A cancelled run still commits what it already measured. Losing a
            // decoded file to a cancellation that arrived a moment later would
            // be the most expensive kind of wasted work in this codebase.
            if (measurements.items.len > 0) {
                try self.commit(measurements.items, &result);
                for (measurements.items) |item| item.deinit(self.allocator);
                measurements.clearRetainingCapacity();
                result.batches_committed += 1;
            }
            if (result.cancelled or self.only_file_id != null) break;
        }
        return result;
    }

    /// The measurement this pass selects on and stores under. One function, so
    /// "which files still owe work" and "what was written" cannot drift.
    pub fn selector(self: *const LibraryAnalysis) database.repository.AnalysisSelector {
        return analysis.service.diagnosticsSelector(self.parameters);
    }

    fn isCancelled(self: *const LibraryAnalysis) bool {
        const token = self.cancellation orelse return false;
        return token.checkpoint();
    }

    /// Measures a batch on this thread and `helpers.len` more, and returns once
    /// every thread that started has been joined. A thread that fails to
    /// start leaves its share to the others.
    fn measureBatch(self: *const LibraryAnalysis, batch: *Batch, helpers: []std.Thread) void {
        var started: usize = 0;
        defer for (helpers[0..started]) |thread| thread.join();
        for (helpers) |*thread| {
            thread.* = std.Thread.spawn(.{}, Batch.helper, .{batch}) catch break;
            started += 1;
        }
        batch.work(self.io);
    }

    /// Decodes one file end to end, on whichever thread claimed it, so it
    /// touches no SQLite. Never holds the write lane: this is the slow half,
    /// and parking every reader of the Library behind it for the length of a
    /// song would be indistinguishable from a hang.
    fn measure(
        self: *const LibraryAnalysis,
        io: std.Io,
        codecs: *const codec.CodecRegistry,
        candidate: database.repository.AnalysisCandidate,
    ) !Measurement.Outcome {
        if (candidate.uri.len == 0) return .skipped;
        const recorded = candidate.source_identity orelse return .skipped;
        // Cheap, and it settles provenance before anything expensive happens.
        // A file whose bytes no longer match what the Library recorded would
        // have its measurement filed under an identity the selection does not
        // look for, so it would be decoded again on every run for ever. Two
        // 64 KiB reads decline it instead, and a scan is the pass that repairs
        // the record.
        {
            var local = storage.LocalFileSource.open(io, candidate.uri) catch
                return .skipped;
            defer local.close();
            const observed = quick_hash.fromSource(local.readable()) catch return .skipped;
            if (!std.mem.eql(u8, &observed, &recorded)) return .skipped;
        }

        const service: analysis.service.Service = .{
            .allocator = self.allocator,
            .io = io,
            .codecs = codecs,
            // No cache: this pass owns the write, and it commits a whole batch
            // of results, identities and health together rather than letting
            // each file land in a transaction of its own.
            .cache = null,
            .cancellation = self.cancellation,
        };
        var measured = service.analyzeFile(null, candidate.uri, self.parameters) catch |err|
            switch (err) {
                error.Cancelled, error.OutOfMemory => return err,
                // Nothing claims this container or can decode its encoding,
                // the file went away between the identity check and the
                // decode, or it changed underneath the analysis. None of those
                // is a defect in the file.
                error.UnsupportedAudioFormat,
                error.CodecUnavailable,
                error.SourceChangedDuringAnalysis,
                error.FileNotFound,
                error.AccessDenied,
                => return .skipped,
                // Opened, and would not yield its audio.
                else => return .{ .unreadable = @errorName(err) },
            };
        defer measured.deinit();
        if (!std.mem.eql(u8, &measured.source_identity, &recorded)) return .skipped;

        const diagnostics_bytes = try analysis.encoding.encode(
            self.allocator,
            measured.diagnostics,
        );
        errdefer self.allocator.free(diagnostics_bytes);
        const fingerprint_bytes = try analysis.fingerprint.encode(
            self.allocator,
            measured.fingerprint,
        );
        errdefer self.allocator.free(fingerprint_bytes);
        const chromaprint_bytes = if (measured.chromaprint) |value|
            try value.encode(self.allocator)
        else
            null;
        return .{ .measured = .{
            .source_identity = measured.source_identity,
            .diagnostics_bytes = diagnostics_bytes,
            .fingerprint_bytes = fingerprint_bytes,
            .chromaprint_bytes = chromaprint_bytes,
            .audio_hash = measured.fingerprint.decoded_audio_hash,
            .has_loudness = measured.diagnostics.replay_gain_db != null,
            .integrated_lufs = measured.diagnostics.integrated_lufs,
            .clipped_runs = measured.diagnostics.clipped_runs,
            .clipped_samples = measured.diagnostics.clipped_samples,
            .silent_frames = measured.diagnostics.silent_frames,
            .decoded_frames = measured.decoded_frames orelse return error.UnexpectedCachedAnalysis,
        } };
    }

    /// One bounded commit per batch, holding the Library's one write lane —
    /// and only here, with every decode already finished.
    fn commit(
        self: *LibraryAnalysis,
        measurements: []const Measurement,
        result: *Result,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.database_handle.exec("BEGIN IMMEDIATE;");
        errdefer self.database_handle.exec("ROLLBACK;") catch {};
        for (measurements) |measurement| switch (measurement.outcome) {
            .measured => |value| {
                try self.analysis_cache.putLocked(
                    analysis.service.diagnosticsKey(
                        measurement.file_id,
                        value.source_identity,
                        self.parameters,
                    ),
                    value.diagnostics_bytes,
                );
                try self.analysis_cache.putLocked(
                    analysis.service.fingerprintKey(
                        measurement.file_id,
                        value.source_identity,
                    ),
                    value.fingerprint_bytes,
                );
                if (value.chromaprint_bytes) |bytes| {
                    try self.analysis_cache.putLocked(
                        analysis.chromaprint.cacheKey(measurement.file_id, value.source_identity, .{}),
                        bytes,
                    );
                    result.bytes_stored += bytes.len;
                }
                try self.files.setAudioHashLocked(measurement.file_id, &value.audio_hash);
                // Safe to retire: only a pass that decoded the whole stream
                // may raise or clear this kind, and this is that pass.
                try self.health_issues.clearLocked(measurement.file_id, .corrupt_audio);
                var details: analysis.health.DetailsBuffer = undefined;
                try self.health_issues.settleLocked(
                    measurement.file_id,
                    .clipping,
                    analysis.health.clipping(&details, value.clipped_runs, value.clipped_samples),
                );
                try self.health_issues.settleLocked(
                    measurement.file_id,
                    .excessive_silence,
                    analysis.health.excessiveSilence(&details, value.silent_frames, value.decoded_frames),
                );
                try self.health_issues.settleLocked(
                    measurement.file_id,
                    .missing_analysis,
                    analysis.health.missingAnalysis(value.integrated_lufs),
                );
                result.bytes_stored += value.diagnostics_bytes.len +
                    value.fingerprint_bytes.len;
                if (value.has_loudness) {
                    result.changed += 1;
                } else {
                    result.unchanged += 1;
                }
            },
            .unreadable => |details| {
                try self.health_issues.recordLocked(measurement.file_id, .{
                    .kind = .corrupt_audio,
                    .severity = .error_severity,
                    .details = details,
                });
                for ([_]database.HealthIssueKind{ .clipping, .excessive_silence, .missing_analysis }) |kind|
                    try self.health_issues.clearLocked(measurement.file_id, kind);
                result.errors += 1;
            },
            .skipped => result.unsupported += 1,
        };
        try self.database_handle.exec("COMMIT;");
    }
};

const testing = std.testing;
const metadata = @import("../metadata/model.zig");

/// A root of real files the pass can decode, plus the Library rows that point
/// at them with the identity a scan would have recorded.
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

    fn copyFixture(self: *Fixture, source_name: []const u8, name: []const u8) !void {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "fixtures/audio/{s}",
            .{source_name},
        );
        defer testing.allocator.free(source);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            source,
            testing.allocator,
            .limited(8 * 1024 * 1024),
        );
        defer testing.allocator.free(bytes);
        try self.writeBytes(name, bytes);
    }

    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.root, name });
    }

    /// A `files` row carrying the quick hash a scan would have observed, plus
    /// the location that names it.
    fn record(self: *Fixture, name: []const u8) !i64 {
        const uri = try self.path(name);
        defer testing.allocator.free(uri);
        const digest = try quick_hash.fromPath(testing.io, uri);
        const file_id = try self.library.files.create(.{
            .audio_format = 1,
            .quick_hash = &digest,
        });
        _ = try self.library.locations.upsert(.{
            .file_id = file_id,
            .volume_id = database.LibraryDatabase.null_volume,
            .uri = uri,
            .state = .present,
        });
        try self.library.observed_tags.upsert(.{
            .file_id = file_id,
            .values = .{ .title = "One", .artist = "Artist", .album = "Album" },
        });
        return file_id;
    }

    /// A row whose recorded identity is not the file's, as a library scanned
    /// before the bytes changed would hold it.
    fn recordWithIdentity(self: *Fixture, name: []const u8, digest: quick_hash.Digest) !i64 {
        const uri = try self.path(name);
        defer testing.allocator.free(uri);
        const file_id = try self.library.files.create(.{
            .audio_format = 1,
            .quick_hash = &digest,
        });
        _ = try self.library.locations.upsert(.{
            .file_id = file_id,
            .volume_id = database.LibraryDatabase.null_volume,
            .uri = uri,
            .state = .present,
        });
        return file_id;
    }

    fn pass(self: *Fixture) LibraryAnalysis {
        return .{
            .allocator = testing.allocator,
            .io = testing.io,
            .files = &self.library.files,
            .analysis_cache = &self.library.analysis_cache,
            .health_issues = &self.library.health_issues,
            .write_lane = self.library.write_lane,
            .database_handle = self.library.database,
            // The waveform is the bulk of a stored result and nothing here
            // reads it.
            .parameters = .{ .waveform_buckets = 8 },
        };
    }
};

const scalar = database.columns.scalar;

test "selecting the files that still owe an analysis is an index search, not a table scan" {
    // `files` is walked by primary key and each row costs one full-prefix probe
    // of the analysis cache's own primary key; a paraphrase of either half
    // would still return the right rows, silently, by reading everything twice.
    var fixture = try Fixture.init("file:orca-analysis-plan?mode=memory&cache=shared");
    defer fixture.deinit();
    var statement = try fixture.library.database.prepare(
        "EXPLAIN QUERY PLAN SELECT files.id FROM files WHERE files.id > 0 AND (" ++
            database.repository.unanalyzed_predicate ++
            ") ORDER BY files.id LIMIT 32;",
    );
    defer statement.deinit();
    var plan: std.ArrayList(u8) = .empty;
    defer plan.deinit(testing.allocator);
    while (try statement.step() == .row) {
        try plan.appendSlice(testing.allocator, statement.columnText(3));
        try plan.append(testing.allocator, '\n');
    }
    try testing.expect(std.mem.indexOf(u8, plan.items, "SCAN files") == null);
    try testing.expect(std.mem.indexOf(u8, plan.items, "analysis_results") != null);
    try testing.expect(std.mem.indexOf(u8, plan.items, "SCAN analysis_results") == null);
}

test "an analysis measures every file once and a second pass has nothing left to do" {
    var fixture = try Fixture.init("file:orca-analysis-once?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "one.flac");
    try fixture.copyFixture("generated-reference.qoa", "two.qoa");
    _ = try fixture.record("one.flac");
    _ = try fixture.record("two.qoa");

    var pass = fixture.pass();
    try testing.expectEqual(@as(u64, 2), try fixture.library.files.unanalyzedCount(pass.selector()));
    const first = try pass.run();
    try testing.expectEqual(@as(u64, 2), first.files_seen);
    try testing.expectEqual(@as(u64, 2), first.changed + first.unchanged);
    try testing.expectEqual(@as(u64, 0), first.errors);
    try testing.expect(first.bytes_stored > 0);
    // Both measurements, for both files.
    try testing.expectEqual(@as(i64, 4), try scalar(
        fixture.library.database,
        "SELECT count(*) FROM analysis_results;",
    ));
    // Tier 4 of the identity cascade, which only a pass that decoded the audio
    // can write.
    try testing.expectEqual(@as(i64, 0), try scalar(
        fixture.library.database,
        "SELECT count(*) FROM files WHERE audio_hash IS NULL;",
    ));

    const second = try pass.run();
    try testing.expectEqual(@as(u64, 0), second.files_seen);
    try testing.expectEqual(@as(u64, 0), try fixture.library.files.unanalyzedCount(pass.selector()));
}

test "a file whose recorded identity is stale is declined rather than measured" {
    // Its measurement would be filed under the identity it actually has, which
    // is not the one the selection looks for, so it would be decoded again on
    // every run for ever. A scan is what repairs the record.
    var fixture = try Fixture.init("file:orca-analysis-stale?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "one.flac");
    _ = try fixture.recordWithIdentity("one.flac", @splat(0x5a));

    var pass = fixture.pass();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.files_seen);
    try testing.expectEqual(@as(u64, 1), result.unsupported);
    try testing.expectEqual(@as(u64, 0), result.changed + result.unchanged);
    try testing.expectEqual(@as(i64, 0), try scalar(
        fixture.library.database,
        "SELECT count(*) FROM analysis_results;",
    ));
    // Declined, not reported: a stale row is a library-state problem the
    // scanner owns, not a defect in the file.
    try testing.expectEqual(@as(u64, 0), try fixture.library.health_issues.count());
}

test "a file that will not decode is reported as corrupt audio and keeps no result" {
    var fixture = try Fixture.init("file:orca-analysis-corrupt?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.writeBytes("broken.flac", "fLaC but not a stream at all, truly");
    const file_id = try fixture.record("broken.flac");

    var pass = fixture.pass();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.errors);
    try testing.expectEqual(@as(u64, 0), result.changed + result.unchanged);
    try testing.expectEqual(@as(i64, 0), try scalar(
        fixture.library.database,
        "SELECT count(*) FROM analysis_results;",
    ));
    var issues = try fixture.library.health_issues.page(testing.allocator, 8, 0);
    defer issues.deinit();
    try testing.expectEqual(@as(usize, 1), issues.items.len);
    try testing.expectEqual(file_id, issues.items[0].file_id);
    try testing.expectEqual(database.HealthIssueKind.corrupt_audio, issues.items[0].kind);
}

test "a file no registered codec can decode is declined, not reported as corrupt" {
    var fixture = try Fixture.init("file:orca-analysis-no-codec?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "undecodable.flac");
    _ = try fixture.record("undecodable.flac");

    const no_codecs: codec.CodecRegistry = .{};
    var pass = fixture.pass();
    pass.codecs = &no_codecs;
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.unsupported);
    try testing.expectEqual(@as(u64, 0), result.errors);
    var issues = try fixture.library.health_issues.page(testing.allocator, 8, 0);
    defer issues.deinit();
    try testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "an analysis pass counts a file that is not there without reporting it as a defect" {
    // Files go missing and drives get unmounted; `locations.state` already
    // models that. One health issue per absent file would bury every real
    // finding under a mount problem the Library has already recorded.
    var fixture = try Fixture.init("file:orca-analysis-missing?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "present.flac");
    _ = try fixture.record("present.flac");
    const absent = try fixture.recordWithIdentity("never-written.flac", @splat(0x11));

    var pass = fixture.pass();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.files_seen);
    try testing.expectEqual(@as(u64, 1), result.unsupported);
    try testing.expectEqual(@as(u64, 1), result.changed + result.unchanged);
    const kinds = try issueKinds(&fixture.library, absent);
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(database.HealthIssueKind, &.{}, kinds);
}

/// A decoder that cancels the pass part way through a file's decode.
///
/// Racing a watcher thread would land between files most of the time, which is
/// the easy case. The invariant worth protecting is the other one: a run
/// interrupted with files already measured and not yet written must still
/// write them, and must not count the file it abandoned mid-decode.
const InterruptingCodec = struct {
    var token: ?*CancellationToken = null;
    var opens: std.atomic.Value(usize) = .init(0);
    var cancel_at: usize = 0;

    fn open(
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) anyerror!codec.Decoder {
        if (opens.fetchAdd(1, .acq_rel) + 1 >= cancel_at) {
            if (token) |requested| requested.cancel();
        }
        return codec.flac.openDecoder(allocator, source);
    }

    fn registry(stop: *CancellationToken, after: usize) codec.CodecRegistry {
        token = stop;
        opens.store(0, .release);
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

/// Decoders that record how many files were actually opened for decoding.
const CountingCodec = struct {
    var opens: std.atomic.Value(usize) = .init(0);

    fn openFlac(
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) anyerror!codec.Decoder {
        _ = opens.fetchAdd(1, .acq_rel);
        return codec.flac.openDecoder(allocator, source);
    }

    fn openMp3(
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) anyerror!codec.Decoder {
        _ = opens.fetchAdd(1, .acq_rel);
        return codec.mp3.openDecoder(allocator, source);
    }

    fn registry() codec.CodecRegistry {
        opens.store(0, .release);
        var codecs: codec.CodecRegistry = .{};
        codecs.register(.{
            .name = "counting FLAC",
            .format = .flac,
            .open = openFlac,
        }) catch unreachable;
        codecs.register(.{
            .name = "counting MPEG Audio",
            .format = .mp3,
            .open = openMp3,
        }) catch unreachable;
        return codecs;
    }
};

test "a file whose recorded identity is stale is declined before it is decoded" {
    // Declining it after the decode would also be correct, and is what the
    // check on the measurement itself already guarantees. This is about cost:
    // a stale row is selected again on every run, so paying a whole decode to
    // reach the same conclusion each time is the difference between an hour
    // and a second on a library that has drifted.
    var fixture = try Fixture.init("file:orca-analysis-early-decline?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "current.flac");
    try fixture.copyFixture("generated-reference.flac", "drifted.flac");
    _ = try fixture.record("current.flac");
    _ = try fixture.recordWithIdentity("drifted.flac", @splat(0x7e));

    const codecs = CountingCodec.registry();
    var pass = fixture.pass();
    pass.codecs = &codecs;
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.files_seen);
    try testing.expectEqual(@as(u64, 1), result.unsupported);
    try testing.expectEqual(@as(u64, 1), result.changed + result.unchanged);
    try testing.expectEqual(@as(usize, 1), CountingCodec.opens.load(.acquire));
}

test "an interrupted analysis commits what it measured and resumes at the rest" {
    var fixture = try Fixture.init("file:orca-analysis-resume?mode=memory&cache=shared");
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "fixtures/audio/generated-reference.flac",
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(bytes);
    for (0..6) |index| {
        const name = try std.fmt.allocPrint(testing.allocator, "copy-{d}.flac", .{index});
        defer testing.allocator.free(name);
        try fixture.writeBytes(name, bytes);
        _ = try fixture.record(name);
    }

    // One page holds all six. Cancelling as the third file's decoder opens
    // leaves two measured and unwritten at the moment the run gives up, and
    // the third abandoned part way through.
    var token: CancellationToken = .{};
    const codecs = InterruptingCodec.registry(&token, 3);
    var first = fixture.pass();
    first.cancellation = &token;
    first.codecs = &codecs;
    first.threads = 1;
    const interrupted = try first.run();
    try testing.expect(interrupted.cancelled);
    try testing.expectEqual(@as(u64, 2), interrupted.files_seen);
    try testing.expectEqual(@as(u64, 2), interrupted.changed + interrupted.unchanged);
    try testing.expectEqual(@as(u64, 1), interrupted.batches_committed);

    // The second run asks the same question and gets the shorter answer, and
    // the two answers add up to the whole library.
    var second = fixture.pass();
    const resumed = try second.run();
    try testing.expect(!resumed.cancelled);
    try testing.expectEqual(@as(u64, 4), resumed.files_seen);
    try testing.expectEqual(@as(u64, 6), interrupted.files_seen + resumed.files_seen);
    try testing.expectEqual(@as(u64, 0), try fixture.library.files.unanalyzedCount(
        second.selector(),
    ));
}

test "changing the measurement's parameters selects every file again" {
    // The stored result describes a measurement that is no longer the one
    // being asked for, and the cache key says so without a flag on `files`
    // that could disagree with it.
    var fixture = try Fixture.init("file:orca-analysis-parameters?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "one.flac");
    _ = try fixture.record("one.flac");

    var pass = fixture.pass();
    try testing.expectEqual(@as(u64, 1), (try pass.run()).files_seen);
    try testing.expectEqual(@as(u64, 0), (try pass.run()).files_seen);

    pass.parameters.replay_gain_target_lufs = -14;
    try testing.expectEqual(@as(u64, 1), try fixture.library.files.unanalyzedCount(
        pass.selector(),
    ));
    try testing.expectEqual(@as(u64, 1), (try pass.run()).files_seen);
}

test "a file whose bytes changed is measured again once a scan has recorded them" {
    var fixture = try Fixture.init("file:orca-analysis-rebytes?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("generated-reference.flac", "one.flac");
    const file_id = try fixture.record("one.flac");

    var pass = fixture.pass();
    try testing.expectEqual(@as(u64, 1), (try pass.run()).files_seen);
    try testing.expectEqual(@as(u64, 0), (try pass.run()).files_seen);

    // Different audio at the same path, and a scan that recorded it.
    try fixture.copyFixture("generated-reference.qoa", "one.flac");
    const uri = try fixture.path("one.flac");
    defer testing.allocator.free(uri);
    const digest = try quick_hash.fromPath(testing.io, uri);
    try fixture.library.files.update(file_id, .{ .audio_format = 1, .quick_hash = &digest });

    try testing.expectEqual(@as(u64, 1), try fixture.library.files.unanalyzedCount(
        pass.selector(),
    ));
    const again = try pass.run();
    try testing.expectEqual(@as(u64, 1), again.files_seen);
    try testing.expectEqual(@as(u64, 1), again.changed + again.unchanged);
}

test "a parallel analysis interrupted part way commits what finished and resumes at the rest" {
    var fixture = try Fixture.init("file:orca-analysis-parallel-resume?mode=memory&cache=shared");
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "fixtures/audio/generated-reference.flac",
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(bytes);
    const total = 12;
    for (0..total) |index| {
        const name = try std.fmt.allocPrint(testing.allocator, "copy-{d}.flac", .{index});
        defer testing.allocator.free(name);
        try fixture.writeBytes(name, bytes);
        _ = try fixture.record(name);
    }

    var token: CancellationToken = .{};
    const codecs = InterruptingCodec.registry(&token, 5);
    var first = fixture.pass();
    first.cancellation = &token;
    first.codecs = &codecs;
    first.threads = 4;
    var progress: std.atomic.Value(u64) = .init(0);
    first.progress = &progress;
    const interrupted = try first.run();
    try testing.expect(interrupted.cancelled);
    try testing.expect(interrupted.files_seen < total);
    try testing.expectEqual(interrupted.files_seen, progress.load(.acquire));
    try testing.expectEqual(@as(i64, @intCast(interrupted.files_seen)), try scalar(
        fixture.library.database,
        "SELECT count(*) FROM analysis_results WHERE kind = 1;",
    ));

    var second = fixture.pass();
    second.threads = 4;
    const resumed = try second.run();
    try testing.expect(!resumed.cancelled);
    try testing.expectEqual(@as(u64, total), interrupted.files_seen + resumed.files_seen);
    try testing.expectEqual(@as(u64, 0), try fixture.library.files.unanalyzedCount(
        second.selector(),
    ));
}

const parity_audio = "fixtures/audio/chromaprint-test.mp3";

fn expectSameRows(
    first: database.sqlite.Database,
    second: database.sqlite.Database,
    sql: [:0]const u8,
    columns: c_int,
) !usize {
    var first_rows = try first.prepare(sql);
    defer first_rows.deinit();
    var second_rows = try second.prepare(sql);
    defer second_rows.deinit();
    var rows: usize = 0;
    while (true) {
        const step = try first_rows.step();
        try testing.expectEqual(step, try second_rows.step());
        if (step == .done) return rows;
        rows += 1;
        var column: c_int = 0;
        while (column < columns) : (column += 1) try testing.expectEqualSlices(
            u8,
            first_rows.columnBlob(column),
            second_rows.columnBlob(column),
        );
    }
}

test "measuring on four threads stores exactly what measuring on one thread stores" {
    const names = [_][]const u8{
        "generated-reference.flac",
        "generated-reference.qoa",
        "chromaprint-test.mp3",
        "midside-reference.flac",
        "stereo-reference.qoa",
        "tagged-reference.ogg",
        "tagged-reference.opus",
        "generated-reference.wav",
        "tagged-reference-aac.m4a",
        "tagged-reference-alac.m4a",
        "tagged-reference.mp3",
        "tagged-reference.aiff",
    };
    var sequential = try Fixture.init("file:orca-analysis-sequential?mode=memory&cache=shared");
    defer sequential.deinit();
    var parallel = try Fixture.init("file:orca-analysis-parallel?mode=memory&cache=shared");
    defer parallel.deinit();
    for (names) |name| {
        try sequential.copyFixture(name, name);
        _ = try sequential.record(name);
        try parallel.copyFixture(name, name);
        _ = try parallel.record(name);
    }

    var one = sequential.pass();
    one.threads = 1;
    var four = parallel.pass();
    four.threads = 4;
    const one_result = try one.run();
    const four_result = try four.run();
    try testing.expectEqual(one_result, four_result);
    try testing.expectEqual(@as(u64, names.len), four_result.changed + four_result.unchanged);

    const stored = try expectSameRows(
        sequential.library.database,
        parallel.library.database,
        "SELECT file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result " ++
            "FROM analysis_results ORDER BY file_id, kind;",
        7,
    );
    try testing.expect(stored > 2 * names.len);
    _ = try expectSameRows(
        sequential.library.database,
        parallel.library.database,
        "SELECT id, audio_hash FROM files ORDER BY id;",
        2,
    );
}

test "the pass stores the AcoustID fingerprint, so taking it again decodes nothing" {
    var fixture = try Fixture.init("file:orca-analysis-chromaprint?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.copyFixture("chromaprint-test.mp3", "song.mp3");
    try fixture.copyFixture("generated-reference.qoa", "blip.qoa");
    const song = try fixture.record("song.mp3");
    _ = try fixture.record("blip.qoa");

    var pass = fixture.pass();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.changed + result.unchanged);
    // Too short to fingerprint, and measured all the same.
    try testing.expectEqual(@as(i64, 1), try scalar(
        fixture.library.database,
        "SELECT count(*) FROM analysis_results WHERE kind = 3;",
    ));

    const uri = try fixture.path("song.mp3");
    defer testing.allocator.free(uri);
    const codecs = CountingCodec.registry();
    const fingerprinter: analysis.chromaprint.Fingerprinter = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .codecs = &codecs,
        .cache = &fixture.library.analysis_cache,
    };
    const cached = try fingerprinter.fingerprintFile(song, uri);
    defer cached.fingerprint.deinit();
    try testing.expect(cached.cache_hit);
    try testing.expectEqual(@as(usize, 0), CountingCodec.opens.load(.acquire));

    const fresh = try fingerprinter.fingerprintFile(null, parity_audio);
    defer fresh.fingerprint.deinit();
    try testing.expectEqualStrings(fresh.fingerprint.encoded, cached.fingerprint.encoded);
    try testing.expectEqual(fresh.fingerprint.duration_ms, cached.fingerprint.duration_ms);
}

test "an analysis refuses zero threads" {
    var fixture = try Fixture.init("file:orca-analysis-zero-threads?mode=memory&cache=shared");
    defer fixture.deinit();
    var pass = fixture.pass();
    pass.threads = 0;
    try testing.expectError(error.InvalidThreadCount, pass.run());
}

/// One second of 16-bit mono PCM at 48 kHz, every sample `amplitude` times a
/// 1 kHz sine.
fn sineWav(amplitude: f32) ![]u8 {
    const rate = 48_000;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(testing.allocator);
    const data_size: u32 = rate * 2;
    try bytes.appendSlice(testing.allocator, "RIFF");
    try bytes.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, 36 + data_size)));
    try bytes.appendSlice(testing.allocator, "WAVEfmt ");
    for ([_]u32{ 16, 0x0001_0001, rate, rate * 2, 0x0010_0002 }) |word|
        try bytes.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, word)));
    try bytes.appendSlice(testing.allocator, "data");
    try bytes.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, data_size)));
    for (0..rate) |frame| {
        const phase = 2 * std.math.pi * 1000 * @as(f32, @floatFromInt(frame)) / rate;
        const sample = std.math.clamp(amplitude * @sin(phase) * 32768, -32768, 32767);
        try bytes.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(i16, @intFromFloat(sample))));
    }
    return bytes.toOwnedSlice(testing.allocator);
}

fn issueKinds(library: *database.LibraryDatabase, file_id: i64) ![]database.HealthIssueKind {
    var issues = try library.health_issues.page(testing.allocator, 16, 0);
    defer issues.deinit();
    var kinds: std.ArrayList(database.HealthIssueKind) = .empty;
    for (issues.items) |issue| {
        if (issue.file_id == file_id) try kinds.append(testing.allocator, issue.kind);
    }
    return kinds.toOwnedSlice(testing.allocator);
}

fn rewrite(fixture: *Fixture, name: []const u8, file_id: i64, bytes: []const u8) !void {
    try fixture.writeBytes(name, bytes);
    const uri = try fixture.path(name);
    defer testing.allocator.free(uri);
    const digest = try quick_hash.fromPath(testing.io, uri);
    var update = try fixture.library.database.prepare("UPDATE files SET quick_hash = ?1 WHERE id = ?2;");
    defer update.deinit();
    try update.bindBlob(1, &digest);
    try update.bindInt64(2, file_id);
    try testing.expectEqual(database.sqlite.Step.done, try update.step());
}

test "analysis raises clipping and retires it when the file is clean" {
    var fixture = try Fixture.init("file:orca-analysis-clipping?mode=memory&cache=shared");
    defer fixture.deinit();
    const clipped = try sineWav(2);
    defer testing.allocator.free(clipped);
    try fixture.writeBytes("song.wav", clipped);
    const file_id = try fixture.record("song.wav");

    var pass = fixture.pass();
    _ = try pass.run();
    const before = try issueKinds(&fixture.library, file_id);
    defer testing.allocator.free(before);
    try testing.expectEqualSlices(database.HealthIssueKind, &.{.clipping}, before);

    const clean = try sineWav(0.5);
    defer testing.allocator.free(clean);
    try rewrite(&fixture, "song.wav", file_id, clean);

    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.changed);
    const after = try issueKinds(&fixture.library, file_id);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(database.HealthIssueKind, &.{}, after);
}

test "a single full-scale sample in an otherwise clean file is not clipping" {
    var fixture = try Fixture.init("file:orca-analysis-one-full-scale-sample?mode=memory&cache=shared");
    defer fixture.deinit();
    const bytes = try sineWav(0.5);
    defer testing.allocator.free(bytes);
    const first_sample = 44;
    std.mem.writeInt(i16, bytes[first_sample + 200 ..][0..2], -32768, .little);
    try fixture.writeBytes("song.wav", bytes);
    const file_id = try fixture.record("song.wav");

    var pass = fixture.pass();
    _ = try pass.run();
    const kinds = try issueKinds(&fixture.library, file_id);
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(database.HealthIssueKind, &.{}, kinds);
}

test "a silent file is reported as silent and too quiet to measure" {
    var fixture = try Fixture.init("file:orca-analysis-silence?mode=memory&cache=shared");
    defer fixture.deinit();
    const silent = try sineWav(0);
    defer testing.allocator.free(silent);
    try fixture.writeBytes("silence.wav", silent);
    const file_id = try fixture.record("silence.wav");

    var pass = fixture.pass();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.unchanged);
    const kinds = try issueKinds(&fixture.library, file_id);
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(
        database.HealthIssueKind,
        &.{ .excessive_silence, .missing_analysis },
        kinds,
    );
}

test "a file that turns corrupt keeps only corrupt audio" {
    var fixture = try Fixture.init("file:orca-analysis-turns-corrupt?mode=memory&cache=shared");
    defer fixture.deinit();
    const clipped = try sineWav(2);
    defer testing.allocator.free(clipped);
    try fixture.writeBytes("song.wav", clipped);
    const file_id = try fixture.record("song.wav");

    var pass = fixture.pass();
    _ = try pass.run();
    try rewrite(&fixture, "song.wav", file_id, "fLaC but not a stream at all, truly");
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.errors);
    const kinds = try issueKinds(&fixture.library, file_id);
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(database.HealthIssueKind, &.{.corrupt_audio}, kinds);
}

test "analysing one file measures it again even when it owes nothing and settles its health" {
    var fixture = try Fixture.init("file:orca-analysis-one-file?mode=memory&cache=shared");
    defer fixture.deinit();
    const clipped = try sineWav(2);
    defer testing.allocator.free(clipped);
    try fixture.writeBytes("loud.wav", clipped);
    const loud = try fixture.record("loud.wav");
    const clean = try sineWav(0.5);
    defer testing.allocator.free(clean);
    try fixture.writeBytes("clean.wav", clean);
    _ = try fixture.record("clean.wav");

    var pass = fixture.pass();
    _ = try pass.run();
    try fixture.library.database.exec("DELETE FROM library_health_issues;");

    var one = fixture.pass();
    one.only_file_id = loud;
    const result = try one.run();
    try testing.expectEqual(@as(u64, 1), result.files_seen);
    const kinds = try issueKinds(&fixture.library, loud);
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(database.HealthIssueKind, &.{.clipping}, kinds);

    var missing = fixture.pass();
    missing.only_file_id = loud + 100;
    try testing.expectEqual(@as(u64, 0), (try missing.run()).files_seen);
}
