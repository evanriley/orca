//! Finds the files a Library holds more than once, and records them where a
//! person can act on them.
//!
//! Comparing every pair is O(n^2) and cannot run at 500,000 files, so
//! candidates are found through indexes. `library/analysis_pass.zig` writes
//! `files.audio_hash` — BLAKE3 over the decoded samples. Two files whose
//! decoded audio hashes identically **are** the same audio, whatever their
//! containers, bitrates or tags claim, and that is an index lookup rather than
//! a comparison. Everything else the fingerprint decides, and it decides it
//! only inside a bucket small enough to afford:
//!
//! - **selection** walks `files` by primary key, cursor-resumable, bounded;
//! - the **exact bucket** is an equality search of `files_audio_hash`;
//! - the **plausible bucket** is a range search of `files_duration`, because
//!   length is the cheapest necessary condition for two files being the same
//!   recording and the only one an index can answer.
//!
//! `fingerprint.classifyDuplicate` is the one pairwise comparison in the
//! codebase and it runs only inside that plausible bucket, against at most
//! `max_bucket_peers` files, with at most two decoded fingerprints resident at
//! any moment.
//!
//! Like every other pass here it writes only what it owns: the two health
//! issue kinds that mean "this audio is in the library twice", rewritten for
//! every file it examines so a re-run converges rather than accumulating.

const std = @import("std");
const analysis = @import("../analysis/root.zig");
const database = @import("../database/root.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const scanner = @import("scanner.zig");

pub const CancellationToken = scanner.CancellationToken;

/// The most files one bucket may hold, and therefore the most fingerprint
/// comparisons one candidate can cost.
///
/// This is what turns O(n^2) into O(n): the work is bounded by a constant per
/// file rather than by the size of the library. A bucket that overflows is
/// counted rather than silently trimmed: some pairs in it went uncompared, and
/// a scan that quietly stopped looking would be the same lie of omission as
/// reporting "no duplicates" for a library nobody has analyzed.
pub const max_bucket_peers = 64;

pub const Result = struct {
    /// Rows examined and carried to a commit.
    files_seen: u64 = 0,
    /// Files reported as holding audio the Library also holds elsewhere,
    /// decided without listening to anything.
    exact: u64 = 0,
    /// Files whose audio only *resembles* another file's. A weaker claim, and
    /// counted separately because it is the one that will sometimes be wrong.
    likely: u64 = 0,
    /// Files compared against every plausible candidate and matched by none.
    unique: u64 = 0,
    /// Files nothing could be said about: never analyzed, so they carry no
    /// decoded-audio hash; never probed, so they carry no duration; or their
    /// stored fingerprint is filed under an identity the Library has since
    /// replaced. Reported rather than folded into `unique`, because "we found
    /// no duplicates" and "we could not look" are different answers.
    uncomparable: u64 = 0,
    /// Files whose stored fingerprint would not decode.
    errors: u64 = 0,
    /// Buckets that hit `max_bucket_peers`, so some pairs inside them were
    /// never compared.
    buckets_truncated: u64 = 0,
    /// Fingerprint comparisons performed, which is the pass's real cost.
    comparisons: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
};

/// What one file's examination decided, held until its batch commits.
///
/// At most one finding per file. `exact` outranks `likely` rather than
/// accompanying it: they are two strengths of the same claim, and telling a
/// person that a file is both a certain and a probable duplicate of something
/// helps nobody decide anything.
const Finding = struct {
    file_id: i64,
    /// Owned, formatted detail text, or null for a file with no finding of
    /// that kind. A null is as load-bearing as a value: the pass retires the
    /// stored issue for every kind it did not raise.
    exact_details: ?[]u8 = null,
    likely_details: ?[]u8 = null,

    fn deinit(self: Finding, allocator: std.mem.Allocator) void {
        if (self.exact_details) |details| allocator.free(details);
        if (self.likely_details) |details| allocator.free(details);
    }
};

/// Which counter a file's examination lands in. Disjoint by construction, so
/// the outcomes always add up to `files_seen`.
const Outcome = enum { exact, likely, unique, uncomparable, failed };

pub const DuplicateScan = struct {
    allocator: std.mem.Allocator,
    files: *database.FileRepository,
    locations: *database.repository.LocationRepository,
    analysis_cache: *database.AnalysisCacheRepository,
    health_issues: *database.repository.HealthIssueRepository,
    write_lane: *database.repository.WriteLane,
    database_handle: database.sqlite.Database,
    cancellation: ?*const CancellationToken = null,
    /// Rows carried to a commit so far, published for a host showing progress.
    /// The denominator is every file in the Library.
    progress: ?*std.atomic.Value(u64) = null,
    /// Files per selected page and per bounded commit.
    ///
    /// Larger than the analysis pass's 32 because a unit of work here is a
    /// handful of indexed lookups and at most `max_bucket_peers` fingerprint
    /// comparisons, not a whole file decoded end to end. There is no
    /// filesystem access in this pass at all.
    batch_size: usize = 256,
    /// How far two files' durations may differ and still be worth comparing.
    ///
    /// Two encodings of one recording differ only by codec padding — an MPEG
    /// encoder's delay and its final partial frame come to a few tens of
    /// milliseconds — so a quarter of a second is generous for the case this
    /// exists to catch. Widening it does not find better matches; it finds the
    /// same matches after comparing proportionally more files, and at some
    /// width it starts admitting genuinely different recordings that happen to
    /// run the same length.
    duration_tolerance_ms: i64 = 250,
    /// How similar two temporal fingerprints must be before the pass will say
    /// so.
    ///
    /// `likely_duplicate` is the finding that can be wrong. Unrelated tracks
    /// of one length score up to about 0.96, a track's own instrumental cut up
    /// to 0.98, and transcodes of one master from about 0.985 up; the threshold
    /// sits in that gap, and lowering it admits false positives at once.
    likely_threshold: f32 = 0.985,

    pub fn run(self: *DuplicateScan) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        if (self.likely_threshold < 0 or self.likely_threshold > 1)
            return error.InvalidSimilarityThreshold;
        var result: Result = .{};
        if (self.isCancelled()) {
            result.cancelled = true;
            return result;
        }
        const page_limit: u32 = @intCast(@min(
            self.batch_size,
            @as(usize, database.repository.max_page),
        ));

        var findings: std.ArrayList(Finding) = .empty;
        defer {
            for (findings.items) |item| item.deinit(self.allocator);
            findings.deinit(self.allocator);
        }
        // A file id, exactly as the analysis pass and the property backfill
        // use one, and for the same reason: a page is bounded and the next one
        // starts where the last ended, with nothing checkpointed separately.
        //
        // Unlike those two this pass is **restartable rather than
        // incremental**, and that is a property of the question rather than a
        // shortcut. Whether a file is a duplicate is a relation between rows:
        // adding one file can make an existing file a duplicate, and deleting
        // one can stop it being one, so there is no subset of rows that still
        // owes work. An interrupted run keeps everything it committed and a
        // later run examines the library again from the start.
        var cursor: i64 = 0;
        while (true) {
            var page = try self.files.duplicateCandidatePage(
                self.allocator,
                cursor,
                page_limit,
            );
            defer page.deinit();
            if (page.items.len == 0) break;

            for (page.items) |candidate| {
                if (self.isCancelled()) {
                    result.cancelled = true;
                    break;
                }
                cursor = candidate.id;
                var finding: Finding = .{ .file_id = candidate.id };
                errdefer finding.deinit(self.allocator);
                switch (try self.examine(candidate, &finding, &result)) {
                    .exact => result.exact += 1,
                    .likely => result.likely += 1,
                    .unique => result.unique += 1,
                    .uncomparable => result.uncomparable += 1,
                    .failed => result.errors += 1,
                }
                result.files_seen += 1;
                if (self.progress) |counter| counter.store(result.files_seen, .release);
                try findings.append(self.allocator, finding);
            }
            // A cancelled run still commits what it examined, so the findings
            // already paid for survive.
            if (findings.items.len > 0) {
                try self.commit(findings.items);
                for (findings.items) |item| item.deinit(self.allocator);
                findings.clearRetainingCapacity();
                result.batches_committed += 1;
            }
            if (result.cancelled) break;
        }
        return result;
    }

    fn isCancelled(self: *const DuplicateScan) bool {
        const token = self.cancellation orelse return false;
        return token.isCancelled();
    }

    /// Decides what, if anything, one file duplicates. Touches no filesystem
    /// and holds no write lane: every question here is an indexed read.
    fn examine(
        self: *DuplicateScan,
        candidate: database.repository.DuplicateCandidate,
        finding: *Finding,
        result: *Result,
    ) !Outcome {
        if (try self.exactDetails(candidate)) |details| {
            finding.exact_details = details;
            return .exact;
        }
        const audio_hash = candidate.audio_hash orelse return .uncomparable;
        const duration = candidate.duration_ms orelse return .uncomparable;
        const identity = candidate.source_identity orelse return .uncomparable;

        var peers: [max_bucket_peers]database.repository.DuplicatePeer = undefined;
        const found = try self.files.durationPeersInto(
            &peers,
            duration -| self.duration_tolerance_ms,
            duration +| self.duration_tolerance_ms,
            candidate.id,
        );
        if (found == peers.len) result.buckets_truncated += 1;
        if (found == 0) return .unique;

        var probe = (self.fingerprint(candidate.id, identity) catch |err| switch (err) {
            error.InvalidStoredFingerprint => return .failed,
            else => return err,
        }) orelse return .uncomparable;
        defer probe.deinit();

        var best_score: f32 = 0;
        var best_peer: ?i64 = null;
        for (peers[0..found]) |peer| {
            // A peer with no decoded-audio hash is one no analysis has
            // measured, so it has no fingerprint to compare either; and a peer
            // with *this* hash is already accounted for by the exact bucket,
            // which a comparison could only agree with more expensively.
            // Between them these two skips are what leaves `likely_recording`
            // as the only verdict this loop can reach.
            const peer_hash = peer.audio_hash orelse continue;
            if (std.mem.eql(u8, &peer_hash, &audio_hash)) continue;
            const peer_identity = peer.source_identity orelse continue;
            // A peer whose stored fingerprint is missing or unreadable is
            // skipped rather than failing the candidate: the defect belongs to
            // the peer's row, and the peer's own turn as a candidate is where
            // it gets counted.
            var stored = (self.fingerprint(peer.id, peer_identity) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            }) orelse continue;
            defer stored.deinit();
            result.comparisons += 1;
            const score = analysis.fingerprint.similarity(probe.signatures, stored.signatures);
            switch (analysis.fingerprint.classifyDuplicate(
                probe,
                stored,
                self.likely_threshold,
            )) {
                .likely_recording => if (score > best_score) {
                    best_score = score;
                    best_peer = peer.id;
                },
                // Unreachable by the two skips above, and left explicit rather
                // than folded into the match: if either skip is ever relaxed,
                // this is where the stronger verdict has to be handled instead
                // of being quietly downgraded to "resembles".
                .exact_audio, .none => continue,
            }
        }
        const matched = best_peer orelse return .unique;
        const path = try self.pathOf(matched);
        defer self.allocator.free(path);
        finding.likely_details = try std.fmt.allocPrint(
            self.allocator,
            analysis.health.likely_duplicate_details,
            .{ path, 100 * best_score },
        );
        return .likely;
    }

    /// The path of something that holds this file's audio as well, or null.
    ///
    /// Two sources, in order of how sure they are. A second *present location*
    /// of the same `files` row is a byte-identical copy the scanner's identity
    /// cascade already resolved to one row, so it never becomes a second row
    /// and could never be found by comparing rows. An equal `audio_hash` is a
    /// different row whose decoded samples are the same audio.
    fn exactDetails(
        self: *DuplicateScan,
        candidate: database.repository.DuplicateCandidate,
    ) !?[]u8 {
        if (try self.locations.secondPresentPath(self.allocator, candidate.id)) |copy| {
            defer self.allocator.free(copy);
            return try std.fmt.allocPrint(
                self.allocator,
                analysis.health.exact_duplicate_details,
                .{copy},
            );
        }
        const audio_hash = candidate.audio_hash orelse return null;
        var peers: [max_bucket_peers]i64 = undefined;
        const found = try self.files.audioHashPeersInto(&peers, &audio_hash, candidate.id);
        if (found == 0) return null;
        const path = try self.pathOf(peers[0]);
        defer self.allocator.free(path);
        return try std.fmt.allocPrint(
            self.allocator,
            analysis.health.exact_duplicate_details,
            .{path},
        );
    }

    /// How a peer is named to a person. A file with no location on any known
    /// volume still has to be nameable, or the finding would be unreportable
    /// for want of a display string.
    fn pathOf(self: *DuplicateScan, file_id: i64) ![]u8 {
        if (try self.locations.uri(self.allocator, file_id)) |path| return path;
        return std.fmt.allocPrint(self.allocator, "file #{d}", .{file_id});
    }

    /// The fingerprint stored for one file under the identity the Library
    /// recorded, or null when there is none.
    ///
    /// Keyed on the stored identity rather than on the bytes: this pass never
    /// opens a file. A fingerprint filed under a superseded identity is
    /// correctly invisible here — the analysis pass will select that file
    /// again, and comparing a measurement against audio it was not taken from
    /// is how a duplicate report becomes fiction.
    fn fingerprint(
        self: *DuplicateScan,
        file_id: i64,
        identity: quick_hash.Digest,
    ) !?analysis.fingerprint.Result {
        const bytes = try self.analysis_cache.get(
            self.allocator,
            analysis.service.fingerprintKey(file_id, identity),
        ) orelse return null;
        defer self.allocator.free(bytes);
        return analysis.fingerprint.decode(self.allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => err,
            else => error.InvalidStoredFingerprint,
        };
    }

    /// One bounded commit per batch, holding the Library's one write lane.
    ///
    /// Every examined file has both of this pass's kinds rewritten, present or
    /// absent. That is the replace-by-file semantic, narrowed to the two kinds
    /// this pass owns: `replaceFile` would also erase the corruption and
    /// metadata findings other passes made, and an insert-only pass would let
    /// a duplicate that has since been deleted keep its report for ever.
    /// Recording is an upsert on `(file_id, kind)`, so running the scan twice
    /// converges on the same rows rather than doubling them.
    fn commit(self: *DuplicateScan, findings: []const Finding) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.database_handle.exec("BEGIN IMMEDIATE;");
        errdefer self.database_handle.exec("ROLLBACK;") catch {};
        for (findings) |finding| {
            if (finding.exact_details) |details| {
                try self.health_issues.recordLocked(finding.file_id, .{
                    .kind = .exact_duplicate,
                    .severity = .warning,
                    .details = details,
                });
            } else {
                try self.health_issues.clearLocked(finding.file_id, .exact_duplicate);
            }
            if (finding.likely_details) |details| {
                try self.health_issues.recordLocked(finding.file_id, .{
                    .kind = .likely_duplicate,
                    .severity = .information,
                    .details = details,
                });
            } else {
                try self.health_issues.clearLocked(finding.file_id, .likely_duplicate);
            }
        }
        try self.database_handle.exec("COMMIT;");
    }
};

const testing = std.testing;

/// A Library holding the measurements a completed analysis pass would have
/// written, without decoding anything.
///
/// The duplicate scan never opens a file — its whole subject is what is
/// already stored — so synthesising the stored side is the honest fixture
/// here, and it makes the audio deterministic rather than dependent on a
/// checked-in encoder's output.
const Fixture = struct {
    library: database.LibraryDatabase,
    next_identity: u8 = 1,

    const sample_rate: u32 = 48_000;

    fn init(name: [:0]const u8) !Fixture {
        return .{ .library = try database.LibraryDatabase.open(testing.allocator, testing.io, name) };
    }

    fn deinit(self: *Fixture) void {
        self.library.close();
    }

    /// A tone whose partials and envelope are decided by `seed`, so two seeds
    /// are two genuinely different pieces of audio of exactly the same length
    /// rather than the same audio twice.
    fn tone(seconds: f32, seed: u32, amplitude: f32) ![]f32 {
        const frames: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(sample_rate)));
        const samples = try testing.allocator.alloc(f32, frames);
        const base: f32 = @floatFromInt(180 + seed * 130);
        for (samples, 0..) |*sample, frame| {
            const time = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(sample_rate));
            const envelope = 0.5 + 0.5 * @sin(2 * std.math.pi * @as(f32, @floatFromInt(1 + seed)) * time);
            sample.* = amplitude * envelope * (@sin(2 * std.math.pi * base * time) +
                0.4 * @sin(2 * std.math.pi * base * 3 * time)) / 1.4;
        }
        return samples;
    }

    /// A `files` row carrying exactly what the analysis pass stores: the
    /// decoded-audio hash on `files`, the encoded fingerprint in
    /// `analysis_results` under the file's recorded identity.
    fn recordMeasured(self: *Fixture, path: []const u8, samples: []const f32) !i64 {
        var analyzer = try analysis.fingerprint.Analyzer.init(testing.allocator, sample_rate, 1);
        defer analyzer.deinit();
        try analyzer.process(samples);
        const measured = try analyzer.finish();
        defer measured.deinit();

        const identity: quick_hash.Digest = @splat(self.next_identity);
        self.next_identity += 1;
        const file_id = try self.library.files.create(.{
            .audio_format = 1,
            .quick_hash = &identity,
            .audio_hash = &measured.decoded_audio_hash,
            .duration_ms = @intCast(samples.len * 1000 / sample_rate),
        });
        const encoded = try analysis.fingerprint.encode(testing.allocator, measured);
        defer testing.allocator.free(encoded);
        try self.library.analysis_cache.put(
            analysis.service.fingerprintKey(file_id, identity),
            encoded,
        );
        try self.addLocation(file_id, path);
        return file_id;
    }

    /// A `files` row as a scan leaves it: a length and an identity, and no
    /// measurement of what the audio is.
    fn recordUnmeasured(self: *Fixture, path: []const u8, duration_ms: i64) !i64 {
        const identity: quick_hash.Digest = @splat(self.next_identity);
        self.next_identity += 1;
        const file_id = try self.library.files.create(.{
            .audio_format = 1,
            .quick_hash = &identity,
            .duration_ms = duration_ms,
        });
        try self.addLocation(file_id, path);
        return file_id;
    }

    fn addLocation(self: *Fixture, file_id: i64, path: []const u8) !void {
        _ = try self.library.locations.upsert(.{
            .file_id = file_id,
            .volume_id = database.LibraryDatabase.null_volume,
            .uri = path,
            .state = .present,
        });
    }

    fn scan(self: *Fixture) DuplicateScan {
        return .{
            .allocator = testing.allocator,
            .files = &self.library.files,
            .locations = &self.library.locations,
            .analysis_cache = &self.library.analysis_cache,
            .health_issues = &self.library.health_issues,
            .write_lane = self.library.write_lane,
            .database_handle = self.library.database,
        };
    }

    /// The stored finding of one kind for one file, or null. Read back through
    /// the same page a host reads, so a test cannot pass on a row `orca-cli
    /// health` would not show.
    fn finding(
        self: *Fixture,
        file_id: i64,
        kind: database.HealthIssueKind,
    ) !?[]u8 {
        var page = try self.library.health_issues.page(testing.allocator, 256, 0);
        defer page.deinit();
        for (page.items) |issue| {
            if (issue.file_id != file_id or issue.kind != kind) continue;
            return try testing.allocator.dupe(u8, issue.details);
        }
        return null;
    }
};

fn planOf(fixture: *Fixture, sql: [:0]const u8) ![]u8 {
    var statement = try fixture.library.database.prepare(sql);
    defer statement.deinit();
    var plan: std.ArrayList(u8) = .empty;
    errdefer plan.deinit(testing.allocator);
    while (try statement.step() == .row) {
        try plan.appendSlice(testing.allocator, statement.columnText(3));
        try plan.append(testing.allocator, '\n');
    }
    return plan.toOwnedSlice(testing.allocator);
}

test "selecting candidates and looking up either bucket are index searches, not scans" {
    // Selection walks the primary key, the certain bucket is an equality search
    // of `files_audio_hash`, and the plausible bucket is a range search of
    // `files_duration`. A paraphrase of any of the three would return the same
    // rows, silently, by reading the whole table for every candidate.
    var fixture = try Fixture.init("file:orca-duplicate-plan?mode=memory&cache=shared");
    defer fixture.deinit();

    const selection = try planOf(
        &fixture,
        "EXPLAIN QUERY PLAN SELECT id, audio_hash, duration_ms, quick_hash FROM files" ++
            " WHERE id > ?1 ORDER BY id LIMIT ?2;",
    );
    defer testing.allocator.free(selection);
    try testing.expect(std.mem.indexOf(u8, selection, "SCAN files") == null);
    try testing.expect(std.mem.indexOf(u8, selection, "SEARCH files") != null);

    const exact_bucket = try planOf(
        &fixture,
        "EXPLAIN QUERY PLAN SELECT id FROM files WHERE audio_hash = ?1 AND id <> ?2" ++
            " ORDER BY id LIMIT ?3;",
    );
    defer testing.allocator.free(exact_bucket);
    try testing.expect(std.mem.indexOf(u8, exact_bucket, "SCAN files") == null);
    try testing.expect(std.mem.indexOf(u8, exact_bucket, "files_audio_hash") != null);

    const plausible_bucket = try planOf(
        &fixture,
        "EXPLAIN QUERY PLAN SELECT id, quick_hash, audio_hash FROM files" ++
            " WHERE duration_ms >= ?1 AND duration_ms <= ?2 AND id <> ?3" ++
            " ORDER BY duration_ms, id LIMIT ?4;",
    );
    defer testing.allocator.free(plausible_bucket);
    try testing.expect(std.mem.indexOf(u8, plausible_bucket, "SCAN files") == null);
    try testing.expect(std.mem.indexOf(u8, plausible_bucket, "files_duration") != null);
}

test "two files whose decoded audio hashes alike are reported as exact duplicates" {
    var fixture = try Fixture.init("file:orca-duplicate-exact?mode=memory&cache=shared");
    defer fixture.deinit();
    const samples = try Fixture.tone(3, 1, 0.6);
    defer testing.allocator.free(samples);
    const first = try fixture.recordMeasured("/music/album/track.flac", samples);
    const second = try fixture.recordMeasured("/music/rip/track.wav", samples);

    var pass = fixture.scan();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.files_seen);
    try testing.expectEqual(@as(u64, 2), result.exact);
    try testing.expectEqual(@as(u64, 0), result.likely);
    // Both sides are told, because either is the one a person might delete.
    const forward = (try fixture.finding(first, .exact_duplicate)).?;
    defer testing.allocator.free(forward);
    try testing.expect(std.mem.endsWith(u8, forward, "/music/rip/track.wav"));
    const backward = (try fixture.finding(second, .exact_duplicate)).?;
    defer testing.allocator.free(backward);
    try testing.expect(std.mem.endsWith(u8, backward, "/music/album/track.flac"));
}

test "a byte-identical copy is one file at two paths and is still reported" {
    // The scanner's identity cascade resolves a copy by quick hash to the row
    // that already exists, so it never becomes a second `files` row and no
    // amount of comparing rows could find it. The Library records it as one
    // file at two present locations, which is the same audio stored twice and
    // is exactly what a person asking about duplicates means.
    var fixture = try Fixture.init("file:orca-duplicate-copy?mode=memory&cache=shared");
    defer fixture.deinit();
    const samples = try Fixture.tone(3, 2, 0.6);
    defer testing.allocator.free(samples);
    const file_id = try fixture.recordMeasured("/music/album/track.flac", samples);
    try fixture.addLocation(file_id, "/music/backup/track.flac");

    var pass = fixture.scan();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 1), result.files_seen);
    try testing.expectEqual(@as(u64, 1), result.exact);
    const details = (try fixture.finding(file_id, .exact_duplicate)).?;
    defer testing.allocator.free(details);
    try testing.expect(std.mem.endsWith(u8, details, "/music/backup/track.flac"));
}

test "two different recordings of the same length are not reported as duplicates" {
    // The failure this pass must not have. Same duration puts them in one
    // another's bucket, so the fingerprint is the only thing standing between
    // a user and a report telling them to delete a track they wanted.
    var fixture = try Fixture.init("file:orca-duplicate-distinct?mode=memory&cache=shared");
    defer fixture.deinit();
    const first_audio = try Fixture.tone(3, 1, 0.6);
    defer testing.allocator.free(first_audio);
    const second_audio = try Fixture.tone(3, 4, 0.6);
    defer testing.allocator.free(second_audio);
    const first = try fixture.recordMeasured("/music/one.flac", first_audio);
    const second = try fixture.recordMeasured("/music/two.flac", second_audio);

    var pass = fixture.scan();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.files_seen);
    try testing.expectEqual(@as(u64, 2), result.unique);
    try testing.expectEqual(@as(u64, 2), result.comparisons);
    try testing.expectEqual(@as(u64, 0), result.exact + result.likely);
    try testing.expectEqual(@as(?[]u8, null), try fixture.finding(first, .likely_duplicate));
    try testing.expectEqual(@as(?[]u8, null), try fixture.finding(second, .likely_duplicate));
}

test "audio that only resembles another file is reported as likely rather than exact" {
    var fixture = try Fixture.init("file:orca-duplicate-likely?mode=memory&cache=shared");
    defer fixture.deinit();
    const master = try Fixture.tone(3, 1, 0.6);
    defer testing.allocator.free(master);
    // Three decibels down: the same recording, re-levelled the way a lossy
    // encoder re-levels it, which moves a minority of the fingerprint's energy
    // bins by one step and leaves the rest of the signature alone.
    const transcoded = try Fixture.tone(3, 1, 0.42);
    defer testing.allocator.free(transcoded);
    const first = try fixture.recordMeasured("/music/one.flac", master);
    _ = try fixture.recordMeasured("/music/one.mp3", transcoded);

    var pass = fixture.scan();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.likely);
    try testing.expectEqual(@as(u64, 0), result.exact);
    try testing.expectEqual(@as(?[]u8, null), try fixture.finding(first, .exact_duplicate));
    const details = (try fixture.finding(first, .likely_duplicate)).?;
    defer testing.allocator.free(details);
    try testing.expect(std.mem.indexOf(u8, details, "/music/one.mp3") != null);
    try testing.expect(std.mem.indexOf(u8, details, "% match") != null);
}

test "a file outside the duration window is never compared with one inside it" {
    var fixture = try Fixture.init("file:orca-duplicate-window?mode=memory&cache=shared");
    defer fixture.deinit();
    const short = try Fixture.tone(3, 1, 0.6);
    defer testing.allocator.free(short);
    const long = try Fixture.tone(5, 1, 0.6);
    defer testing.allocator.free(long);
    _ = try fixture.recordMeasured("/music/short.flac", short);
    _ = try fixture.recordMeasured("/music/long.flac", long);

    var pass = fixture.scan();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 0), result.comparisons);
    try testing.expectEqual(@as(u64, 2), result.unique);
}

test "a library nothing has analyzed reports what it could not compare" {
    // Reporting "no duplicates" here would be a lie of omission: a file with
    // no decoded-audio hash cannot be compared with anything, and most of a
    // library has none until the analysis pass has reached it.
    var fixture = try Fixture.init("file:orca-duplicate-unmeasured?mode=memory&cache=shared");
    defer fixture.deinit();
    _ = try fixture.recordUnmeasured("/music/one.flac", 3000);
    _ = try fixture.recordUnmeasured("/music/two.flac", 3000);

    var pass = fixture.scan();
    const result = try pass.run();
    try testing.expectEqual(@as(u64, 2), result.files_seen);
    try testing.expectEqual(@as(u64, 2), result.uncomparable);
    try testing.expectEqual(@as(u64, 0), result.unique);
    try testing.expectEqual(@as(u64, 0), result.exact + result.likely);
    try testing.expectEqual(@as(u64, 0), try fixture.library.health_issues.count());
}

test "running the duplicate scan twice records the same findings, not twice as many" {
    var fixture = try Fixture.init("file:orca-duplicate-idempotent?mode=memory&cache=shared");
    defer fixture.deinit();
    const samples = try Fixture.tone(3, 1, 0.6);
    defer testing.allocator.free(samples);
    _ = try fixture.recordMeasured("/music/one.flac", samples);
    _ = try fixture.recordMeasured("/music/two.wav", samples);

    var pass = fixture.scan();
    const first = try pass.run();
    const after_first = try fixture.library.health_issues.count();
    const second = try pass.run();
    try testing.expectEqual(first.exact, second.exact);
    try testing.expectEqual(@as(u64, 2), after_first);
    try testing.expectEqual(after_first, try fixture.library.health_issues.count());
}

test "a duplicate that has gone away stops being reported" {
    var fixture = try Fixture.init("file:orca-duplicate-retire?mode=memory&cache=shared");
    defer fixture.deinit();
    const samples = try Fixture.tone(3, 1, 0.6);
    defer testing.allocator.free(samples);
    const kept = try fixture.recordMeasured("/music/one.flac", samples);
    const removed = try fixture.recordMeasured("/music/two.wav", samples);

    var pass = fixture.scan();
    _ = try pass.run();
    const before = (try fixture.finding(kept, .exact_duplicate)).?;
    testing.allocator.free(before);

    var delete = try fixture.library.database.prepare("DELETE FROM files WHERE id=?1;");
    defer delete.deinit();
    try delete.bindInt64(1, removed);
    try testing.expectEqual(database.sqlite.Step.done, try delete.step());

    _ = try pass.run();
    try testing.expectEqual(@as(?[]u8, null), try fixture.finding(kept, .exact_duplicate));
}

test "an interrupted duplicate scan commits what it examined and resumes at the rest" {
    var fixture = try Fixture.init("file:orca-duplicate-resume?mode=memory&cache=shared");
    defer fixture.deinit();
    const samples = try Fixture.tone(1, 1, 0.6);
    defer testing.allocator.free(samples);
    for (0..40) |index| {
        const path = try std.fmt.allocPrint(testing.allocator, "/music/copy-{d}.flac", .{index});
        defer testing.allocator.free(path);
        _ = try fixture.recordMeasured(path, samples);
    }

    var token: CancellationToken = .{};
    var interrupted = fixture.scan();
    interrupted.cancellation = &token;
    // One page holds all forty, so the cancellation lands inside it. That is
    // the case worth protecting: files are examined and not yet written at the
    // moment the run gives up, and a run that threw them away would make
    // stopping it cost work it had already done. Exactly where the cancel
    // lands is a thread race and is deliberately not asserted; what must hold
    // is that everything examined was also written.
    interrupted.batch_size = 40;
    const first = try scanCancellingAfter(&interrupted, &token, 2);
    try testing.expect(first.cancelled);
    try testing.expect(first.files_seen >= 2);
    try testing.expect(first.files_seen < 40);
    try testing.expectEqual(@as(u64, 1), first.batches_committed);
    try testing.expectEqual(first.files_seen, try fixture.library.health_issues.count());

    // The second run asks the same question and gets the shorter answer, and
    // the two answers add up to the whole library.
    var resumed = fixture.scan();
    const second = try resumed.run();
    try testing.expect(!second.cancelled);
    try testing.expectEqual(@as(u64, 40), second.files_seen);
    try testing.expectEqual(@as(u64, 40), try fixture.library.health_issues.count());
}

/// Cancels the token once `after` files have been examined, by watching the
/// pass's own progress counter from this thread.
fn scanCancellingAfter(pass: *DuplicateScan, token: *CancellationToken, after: u64) !Result {
    var progress: std.atomic.Value(u64) = .init(0);
    pass.progress = &progress;
    var watcher: CancelWatcher = .{ .progress = &progress, .token = token, .after = after };
    const thread = try std.Thread.spawn(.{}, CancelWatcher.run, .{&watcher});
    defer thread.join();
    return pass.run();
}

const CancelWatcher = struct {
    progress: *std.atomic.Value(u64),
    token: *CancellationToken,
    after: u64,

    fn run(self: *CancelWatcher) void {
        while (self.progress.load(.acquire) < self.after) std.Thread.yield() catch {};
        self.token.cancel();
    }
};
