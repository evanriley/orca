const std = @import("std");
const analysis = @import("../analysis/root.zig");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const scanner = @import("scanner.zig");
const CurrentItem = scanner.CurrentItem;
const BoundedText = @import("../core/job.zig").BoundedText;

pub const CancellationToken = scanner.CancellationToken;

const acoustid = providers.acoustid;
const ReleaseLookup = providers.musicbrainz.ReleaseLookup;

/// Whether AcoustID took part in a matching pass, and why not.
pub const AcoustIdUse = enum(u8) {
    searched,
    /// The request asked for no fingerprints.
    off,
    no_client_key,
    /// AcoustID refused the application key; the pass went on without it.
    invalid_client_key,
};

/// The service another Orca process was talking to when the pass needed it.
pub const BusyService = enum(u8) {
    none,
    musicbrainz,
    acoustid,
};

pub const Mode = enum {
    /// Tracks with no recording id that a provider in scope has not
    /// answered for.
    search,
    /// Every Track in scope again, whatever it is identified as. The
    /// recording it is identified as is confirmed, never proposed.
    reidentify,
    /// Each file's recording id in effect checked against what AcoustID
    /// hears in its fingerprint; MusicBrainz is not searched.
    verify,

    /// Null for `.verify`, which selects files by their verification.
    pub fn selection(self: Mode) ?database.MatchSelection {
        return switch (self) {
            .search => .unidentified,
            .reidentify => .every,
            .verify => null,
        };
    }
};

/// The score at which AcoustID hearing the recording id in effect confirms it.
pub const verify_agree_minimum: f32 = 0.5;
/// The score at which AcoustID hearing another recording disputes it.
pub const verify_disagree_minimum: f32 = 0.9;

/// What AcoustID hearing `heard` says about `recording_mbid`.
pub fn classify(recording_mbid: []const u8, heard: []const database.HeardRecording) database.VerificationOutcome {
    var disputed = false;
    for (heard) |recording| {
        if (std.ascii.eqlIgnoreCase(recording.mbid, recording_mbid)) {
            if (recording.score >= verify_agree_minimum) return .agrees;
        } else if (recording.score >= verify_disagree_minimum) disputed = true;
    }
    return if (disputed) .disagrees else .unconfirmed;
}

pub const Result = struct {
    tracks_seen: u64 = 0,
    matched: u64 = 0,
    unmatched: u64 = 0,
    /// Tracks found again as the recording they are identified as.
    confirmed: u64 = 0,
    insufficient: u64 = 0,
    refused: u64 = 0,
    proposals_stored: u64 = 0,
    requests_answered: u64 = 0,
    cache_hits: u64 = 0,
    fingerprinted: u64 = 0,
    fingerprint_cache_hits: u64 = 0,
    fingerprint_failures: u64 = 0,
    acoustid_requests: u64 = 0,
    acoustid_cache_hits: u64 = 0,
    /// Fingerprints AcoustID refused or left unanswered.
    acoustid_refused: u64 = 0,
    /// Files a verification stored an outcome for.
    verified: u64 = 0,
    agreed: u64 = 0,
    disagreed: u64 = 0,
    unconfirmed: u64 = 0,
    /// Files a verification passed over for having no quick hash.
    skipped: u64 = 0,
    correction_groups: u64 = 0,
    acoustid: AcoustIdUse = .off,
    cancelled: bool = false,
    unavailable: bool = false,
    busy: BusyService = .none,
};

/// Live counters a host may read while the pass runs.
pub const Progress = struct {
    tracks_seen: std.atomic.Value(u64) = .init(0),
    matched: std.atomic.Value(u64) = .init(0),
    fingerprinted: std.atomic.Value(u64) = .init(0),
    verified: std.atomic.Value(u64) = .init(0),
    /// Releases the library-scope step for the releases Tracks' release IDs
    /// name has handled, looked up or not, of `tagged_releases_total`, which is 0
    /// until that step starts; both equal the total once it finishes.
    tagged_releases: std.atomic.Value(u64) = .init(0),
    tagged_releases_total: std.atomic.Value(u64) = .init(0),
};

const SearchOutcome = union(enum) {
    answered: providers.CandidateList,
    insufficient,
    refused,
    cancelled,
    unavailable,
    busy,
};

const ReleaseStep = enum { done, cancelled, unavailable, busy };

const ReleaseOutcome = union(enum) {
    found: *const ReleaseLookup,
    /// Refused, not found, or not a release: proposals stay as found.
    unusable,
    cancelled,
    unavailable,
    busy,
};

const Fingerprinted = union(enum) {
    taken: analysis.chromaprint.Fingerprint,
    /// No present location, or no file there.
    missing,
    failed,
};

/// What a verification learned about one file of its unit.
const FileCheck = struct {
    lookup: ?providers.CandidateList = null,
    heard: []const database.HeardRecording = &.{},
    outcome: ?database.VerificationOutcome = null,
};

const LookupOutcome = union(enum) {
    answered,
    /// How many queries AcoustID refused.
    refused: u64,
    cancelled,
    unavailable,
    busy,
    invalid_client_key,
};

pub const LibraryMatching = struct {
    allocator: std.mem.Allocator,
    proposals: *database.IdentificationProposalRepository,
    /// Every release a lookup answers is snapshotted here.
    tracklists: *database.ReleaseTracklistRepository,
    /// Needed by `.verify`.
    verifications: ?*const database.RecordingVerificationRepository = null,
    musicbrainz: *providers.musicbrainz.MusicBrainz,
    /// Null leaves AcoustID out; `acoustid_use` says why.
    acoustid: ?*acoustid.AcoustId = null,
    acoustid_use: AcoustIdUse = .off,
    fingerprinter: ?analysis.chromaprint.Fingerprinter = null,
    cancellation: ?*const CancellationToken = null,
    progress: ?*Progress = null,
    current_item: ?*CurrentItem = null,
    batch_size: usize = 64,
    limit: ?u32 = null,
    scope: database.MatchScope = .library,
    mode: Mode = .search,
    last_release: ?ReleaseLookup = null,
    unusable_releases: std.StringHashMapUnmanaged(void) = .empty,

    pub fn run(self: *LibraryMatching) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        defer self.forgetReleases();
        const acoustid_service = self.acoustid;
        var result: Result = .{ .acoustid = if (acoustid_service != null) .searched else self.acoustid_use };
        const page_limit: u32 = @intCast(@min(self.batch_size, @as(usize, database.repository.max_page)));
        const selection = self.mode.selection() orelse {
            try self.verify(&result, page_limit);
            return self.finish(result, acoustid_service);
        };
        var cursor: i64 = 0;
        walk: while (true) {
            var page = try self.proposals.unidentifiedPage(
                self.allocator,
                self.scope,
                selection,
                self.acoustid != null,
                cursor,
                page_limit,
            );
            defer page.deinit();
            if (page.items.len == 0) break;
            var start: usize = 0;
            while (start < page.items.len) {
                var end = @min(start + acoustid.max_lookup_queries, page.items.len);
                if (self.limit) |limit| {
                    if (result.tracks_seen >= limit) break :walk;
                    end = @min(end, start + @as(usize, @intCast(limit - result.tracks_seen)));
                }
                if (self.isCancelled()) {
                    result.cancelled = true;
                    break :walk;
                }
                const group = page.items[start..end];
                cursor = group[group.len - 1].track_id;
                start = end;
                if (!try self.matchGroup(group, &result)) break :walk;
            }
        }
        const stopped = result.cancelled or result.unavailable or result.busy != .none;
        const limited = if (self.limit) |limit| result.tracks_seen >= limit else false;
        if (!stopped) switch (self.scope) {
            .release => |release_id| if (self.isCancelled()) {
                _ = self.stop(&result, .cancelled);
            } else switch (try self.alignRelease(release_id)) {
                .done => {},
                .cancelled => _ = self.stop(&result, .cancelled),
                .unavailable => _ = self.stop(&result, .unavailable),
                .busy => _ = self.stop(&result, .musicbrainz_busy),
            },
            .library => if (!limited) try self.snapshotTaggedReleases(&result),
            .track => {},
        };
        return self.finish(result, acoustid_service);
    }

    fn finish(self: *const LibraryMatching, finished: Result, acoustid_service: ?*acoustid.AcoustId) Result {
        var result = finished;
        result.requests_answered = self.musicbrainz.requests_answered;
        result.cache_hits = self.musicbrainz.cache_hits;
        if (acoustid_service) |service| {
            result.acoustid_requests = service.requests_answered;
            result.acoustid_cache_hits = service.cache_hits;
        }
        return result;
    }

    /// Verifies the scope one unit at a time: a Release's files together, so
    /// the corrections it disputes can form one album group, and Tracks with
    /// no Release a page at a time. Stops without AcoustID, which
    /// `result.acoustid` then says.
    fn verify(self: *LibraryMatching, result: *Result, page_limit: u32) !void {
        if (self.acoustid == null) return;
        const verifications = self.verifications orelse return error.VerificationUnavailable;
        if (self.fingerprinter == null) return error.VerificationUnavailable;
        switch (self.scope) {
            .track => |track_id| {
                var page = try verifications.unitPage(self.allocator, .{ .track = track_id }, 0, 1);
                defer page.deinit();
                _ = try self.verifyUnit(page.items, null, result);
            },
            .release => |release_id| _ = try self.verifyRelease(verifications, release_id, result),
            .library => {
                var cursor: i64 = 0;
                var buffer: [64]i64 = undefined;
                while (true) {
                    const releases = try verifications.releasesToVerify(cursor, &buffer);
                    if (releases.len == 0) break;
                    for (releases) |release_id| {
                        cursor = release_id;
                        if (!try self.verifyRelease(verifications, release_id, result)) return;
                    }
                }
                var track_cursor: i64 = 0;
                while (true) {
                    var page = try verifications.unitPage(self.allocator, .loose, track_cursor, page_limit);
                    defer page.deinit();
                    if (page.items.len == 0) return;
                    track_cursor = page.items[page.items.len - 1].track_id;
                    if (!try self.verifyUnit(page.items, null, result)) return;
                }
            },
        }
    }

    /// False when the pass has to stop.
    fn verifyRelease(
        self: *LibraryMatching,
        verifications: *const database.RecordingVerificationRepository,
        release_id: i64,
        result: *Result,
    ) !bool {
        var tag_buffer: [36]u8 = undefined;
        const tag = if (try verifications.isLargeRelease(release_id)) null else try verifications.releaseTag(release_id, &tag_buffer);
        var cursor: i64 = 0;
        while (true) {
            var page = try verifications.unitPage(self.allocator, .{ .release = release_id }, cursor, database.repository.max_page);
            defer page.deinit();
            if (page.items.len == 0) return true;
            cursor = page.items[page.items.len - 1].track_id;
            if (!try self.verifyUnit(page.items, tag, result)) return false;
        }
    }

    /// Verifies one unit's files and commits what it found in one
    /// transaction, or nothing when it stops. With the unit's tagged release
    /// ID, the files whose strongest recording heard is on that release
    /// propose it as one album group. False when the pass has to stop.
    fn verifyUnit(
        self: *LibraryMatching,
        unit: []const database.VerifiableFile,
        unit_release: ?[]const u8,
        result: *Result,
    ) !bool {
        var files = unit;
        var release_mbid = unit_release;
        if (self.limit) |limit| {
            if (result.tracks_seen >= limit) return false;
            const remaining: usize = @intCast(limit - result.tracks_seen);
            if (files.len > remaining) {
                files = files[0..remaining];
                release_mbid = null;
            }
        }
        if (files.len == 0) return true;
        if (self.isCancelled()) return self.stop(result, .cancelled);

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const checks = try scratch.alloc(FileCheck, files.len);
        @memset(checks, .{});
        defer for (checks) |check| if (check.lookup) |list| list.deinit();

        var to_look_up: std.ArrayList(usize) = .empty;
        var skipped: u64 = 0;
        for (files, checks, 0..) |file, *check, index| {
            if (file.quick_hash == null) {
                skipped += 1;
                continue;
            }
            if (file.heard_before) |before| if (classify(file.recording_mbid, before) == .agrees) {
                check.* = .{ .heard = before, .outcome = .agrees };
                continue;
            };
            try to_look_up.append(scratch, index);
        }
        var start: usize = 0;
        while (start < to_look_up.items.len) {
            const end = @min(start + acoustid.max_lookup_queries, to_look_up.items.len);
            if (!try self.verifyBatch(files, checks, to_look_up.items[start..end], scratch, result)) return false;
            start = end;
        }

        var release: ?*const ReleaseLookup = null;
        if (release_mbid) |mbid| if (disputesProposable(files, checks)) {
            release = switch (try self.lookUpRelease(mbid)) {
                .found => |lookup| lookup,
                .unusable => null,
                .cancelled => return self.stop(result, .cancelled),
                .unavailable => return self.stop(result, .unavailable),
                .busy => return self.stop(result, .musicbrainz_busy),
            };
        };

        var records: std.ArrayList(database.VerifiedFile) = .empty;
        var tally: Result = .{};
        for (files, checks) |file, check| {
            const outcome = check.outcome orelse continue;
            var record: database.VerifiedFile = .{ .verification = .{
                .file_id = file.file_id,
                .quick_hash = file.quick_hash,
                .recording_mbid = file.recording_mbid,
                .outcome = outcome,
                .heard = check.heard,
            } };
            switch (outcome) {
                .agrees => tally.agreed += 1,
                .disagrees => tally.disagreed += 1,
                .unconfirmed => tally.unconfirmed += 1,
                .no_fingerprint => {},
            }
            if (outcome == .disagrees and !file.user_locked) {
                const evidence = try correctionEvidence(scratch, file, check.lookup.?.items);
                record.evidence = evidence;
                if (release) |lookup| record.grouped = try joinGroup(lookup, evidence, check.heard[0]);
            }
            try records.append(scratch, record);
        }
        if (self.isCancelled()) return self.stop(result, .cancelled);
        const recorded = try self.proposals.recordVerifications(self.allocator, records.items);
        result.verified += records.items.len;
        result.agreed += tally.agreed;
        result.disagreed += tally.disagreed;
        result.unconfirmed += tally.unconfirmed;
        result.skipped += skipped;
        result.proposals_stored += recorded.pending;
        if (recorded.group != null) result.correction_groups += 1;
        result.tracks_seen += files.len;
        self.publish(result);
        return true;
    }

    /// Fingerprints up to `max_lookup_queries` files of a unit and looks them
    /// up on AcoustID together. False when the pass has to stop.
    fn verifyBatch(
        self: *LibraryMatching,
        files: []const database.VerifiableFile,
        checks: []FileCheck,
        batch: []const usize,
        scratch: std.mem.Allocator,
        result: *Result,
    ) !bool {
        var group: [acoustid.max_lookup_queries]database.VerifiableFile = undefined;
        var fingerprints: [acoustid.max_lookup_queries]?analysis.chromaprint.Fingerprint = @splat(null);
        defer for (fingerprints[0..batch.len]) |fingerprint| if (fingerprint) |value| value.deinit();
        var lookups: [acoustid.max_lookup_queries]?providers.CandidateList = @splat(null);
        for (batch, 0..) |index, slot| {
            if (self.isCancelled()) return self.stop(result, .cancelled);
            group[slot] = files[index];
            switch (self.fingerprintOf(files[index].file_id, files[index].path, result) catch |err| switch (err) {
                error.Cancelled => return self.stop(result, .cancelled),
                else => return err,
            }) {
                .taken => |fingerprint| fingerprints[slot] = fingerprint,
                .missing => {},
                .failed => checks[index].outcome = .no_fingerprint,
            }
        }
        switch (try self.lookUp(group[0..batch.len], &fingerprints, &lookups)) {
            .answered => {},
            .refused => |queries| result.acoustid_refused += queries,
            .cancelled => return self.stop(result, .cancelled),
            .unavailable => return self.stop(result, .unavailable),
            .busy => return self.stop(result, .acoustid_busy),
            .invalid_client_key => {
                result.acoustid = .invalid_client_key;
                return false;
            },
        }
        for (batch, lookups[0..batch.len]) |index, lookup| checks[index].lookup = lookup;
        for (batch) |index| {
            const list = checks[index].lookup orelse continue;
            checks[index].heard = try heardFrom(scratch, list.items, files[index].recording_mbid);
            checks[index].outcome = classify(files[index].recording_mbid, checks[index].heard);
        }
        return true;
    }

    /// False when the pass has to stop: cancelled or a service unreachable.
    /// A Track is marked searched only by the providers that answered for it.
    fn matchGroup(self: *LibraryMatching, group: []const database.MatchCandidate, result: *Result) !bool {
        var fingerprints: [acoustid.max_lookup_queries]?analysis.chromaprint.Fingerprint = @splat(null);
        defer for (fingerprints[0..group.len]) |fingerprint| if (fingerprint) |value| value.deinit();
        var lookups: [acoustid.max_lookup_queries]?providers.CandidateList = @splat(null);
        defer for (lookups[0..group.len]) |lookup| if (lookup) |list| list.deinit();

        if (self.acoustid != null) {
            for (group, fingerprints[0..group.len]) |candidate, *fingerprint| {
                if (!candidate.needs_acoustid) continue;
                if (self.isCancelled()) return self.stop(result, .cancelled);
                fingerprint.* = self.takeFingerprint(candidate, result) catch |err| switch (err) {
                    error.Cancelled => return self.stop(result, .cancelled),
                    else => return err,
                };
            }
            switch (try self.lookUp(group, &fingerprints, &lookups)) {
                .answered => {},
                .refused => |queries| result.acoustid_refused += queries,
                .cancelled => return self.stop(result, .cancelled),
                .unavailable => return self.stop(result, .unavailable),
                .busy => return self.stop(result, .acoustid_busy),
                .invalid_client_key => {
                    result.acoustid = .invalid_client_key;
                    self.acoustid = null;
                },
            }
        }

        for (group, lookups[0..group.len]) |candidate, lookup| {
            if (self.isCancelled()) return self.stop(result, .cancelled);
            const query = queryFor(candidate);
            var answered: database.ProviderSet = .{ .acoustid = lookup != null };
            var musicbrainz: ?providers.CandidateList = null;
            defer if (musicbrainz) |list| list.deinit();
            if (candidate.needs_musicbrainz) switch (try self.searchMusicBrainz(query)) {
                .answered => |list| {
                    musicbrainz = list;
                    answered.musicbrainz = true;
                },
                .insufficient => if (lookup == null) {
                    result.insufficient += 1;
                },
                .refused => if (lookup == null) {
                    result.refused += 1;
                },
                .cancelled => return self.stop(result, .cancelled),
                .unavailable => return self.stop(result, .unavailable),
                .busy => return self.stop(result, .musicbrainz_busy),
            };
            if (!answered.isEmpty()) {
                const evidence = try providers.workflow.collect(
                    self.allocator,
                    query,
                    if (musicbrainz) |list| list.items else &.{},
                    if (lookup) |list| list.items else &.{},
                );
                defer evidence.deinit();
                const kept = withoutRecording(evidence.items, candidate.recording_mbid);
                const confirmed = kept.len < evidence.items.len;
                if (confirmed) result.confirmed += 1;
                switch (try self.enrich(kept, candidate.tagged_track_number)) {
                    .done => {},
                    .cancelled => return self.stop(result, .cancelled),
                    .unavailable => return self.stop(result, .unavailable),
                    .busy => return self.stop(result, .musicbrainz_busy),
                }
                const stored = try self.proposals.recordSearch(self.allocator, candidate.file_id, answered, kept);
                result.proposals_stored += stored;
                if (stored != 0) {
                    result.matched += 1;
                } else if (!confirmed) {
                    result.unmatched += 1;
                }
            }
            result.tracks_seen += 1;
            self.publish(result);
        }
        return true;
    }

    /// Fills in what the release of the most confident MusicBrainz
    /// proposal says, on every proposal naming that release or no release
    /// whose recording it holds.
    fn enrich(self: *LibraryMatching, items: []database.ProposalEvidence, tagged_track_number: ?u32) !ReleaseStep {
        var best: ?*const database.ProposalEvidence = null;
        for (items) |*item| {
            if (!item.found_by.musicbrainz) continue;
            const release_mbid = item.payload.release_mbid orelse continue;
            if (!metadata.isMusicBrainzId(release_mbid)) continue;
            if (best == null or item.payload.combinedConfidence() > best.?.payload.combinedConfidence()) best = item;
        }
        const chosen = best orelse return .done;
        const release = switch (try self.lookUpRelease(chosen.payload.release_mbid.?)) {
            .found => |lookup| lookup,
            .unusable => return .done,
            .cancelled => return .cancelled,
            .unavailable => return .unavailable,
            .busy => return .busy,
        };
        for (items) |*item| {
            if (item.payload.release_mbid) |named| if (!std.mem.eql(u8, named, release.id())) continue;
            const enrichment = try release.enrichment(item.recording_mbid, tagged_track_number) orelse continue;
            item.payload.enrich(release.id(), enrichment);
        }
        return .done;
    }

    /// Match Album's second phase. Each file votes once for every release
    /// its stored proposals list; the winner is looked up, and every proposal
    /// whose recording it holds is pointed at it with what it says. Then
    /// every release its Tracks' release IDs name and the Release's best
    /// candidate are snapshotted when they have no current snapshot.
    fn alignRelease(self: *LibraryMatching, release_id: i64) !ReleaseStep {
        const step = try self.voteRelease(release_id);
        if (step != .done) return step;
        return self.snapshotBestCandidate(release_id);
    }

    fn voteRelease(self: *LibraryMatching, release_id: i64) !ReleaseStep {
        const list = try self.proposals.releaseProposals(self.allocator, release_id);
        defer list.deinit();
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const payloads = try scratch.alloc(?database.ProposalPayload, list.items.len);
        var tally: database.repository.MbidTally = .{};
        defer tally.deinit(self.allocator);
        var file_votes: std.ArrayList([36]u8) = .empty;
        var facts: std.ArrayList(database.ReleaseFact) = .empty;
        var voting_file: ?i64 = null;
        for (list.items, payloads) |item, *slot| {
            slot.* = null;
            if (voting_file != item.file_id) {
                for (file_votes.items) |mbid| try tally.add(self.allocator, mbid);
                file_votes.clearRetainingCapacity();
                voting_file = item.file_id;
            }
            const parsed = database.ProposalPayload.parse(scratch, item.payload) catch |err| switch (err) {
                error.InvalidProposalPayload => continue,
                error.OutOfMemory => return err,
            };
            slot.* = parsed.value;
            if (parsed.value.release_mbid) |mbid| try addVote(scratch, &file_votes, mbid);
            for (parsed.value.release_mbids orelse &.{}) |mbid| try addVote(scratch, &file_votes, mbid);
            for (parsed.value.release_facts orelse &.{}) |fact| try addFact(scratch, &facts, fact);
        }
        for (file_votes.items) |mbid| try tally.add(self.allocator, mbid);
        const winner = tally.rankedWinner(list.tag, .{
            .facts = facts.items,
            .album_track_count = list.track_count,
        }) orelse return .done;
        const release = switch (try self.lookUpRelease(&winner)) {
            .found => |lookup| lookup,
            .unusable => return .done,
            .cancelled => return .cancelled,
            .unavailable => return .unavailable,
            .busy => return .busy,
        };
        for (list.items, payloads) |item, slot| {
            var payload = slot orelse continue;
            const enrichment = try release.enrichment(item.recording_mbid, item.tagged_track_number) orelse continue;
            payload.enrich(release.id(), enrichment);
            const encoded = try payload.encode(scratch);
            if (std.mem.eql(u8, encoded, item.payload)) continue;
            try self.proposals.updatePayload(item.id, encoded);
        }
        return .done;
    }

    /// Snapshots every release a Track's release ID in effect names, unless
    /// its Release dismissed it or it has a fresh snapshot, so no Release is
    /// weighed on a release Orca has not read. They are taken in release ID
    /// order a page at a time; each lookup stores a whole snapshot or
    /// nothing.
    fn snapshotTaggedReleases(self: *LibraryMatching, result: *Result) !void {
        var buffer: [64]database.repository.NamedRelease = undefined;
        var cursor: ?[36]u8 = null;
        var handled: u64 = 0;
        if (self.progress) |progress| {
            const total = try self.proposals.namedReleasesToSnapshotCount(self.freshAfter());
            progress.tagged_releases_total.store(total, .release);
        }
        while (true) {
            const page = try self.proposals.namedReleasesToSnapshot(if (cursor) |*last| last else null, self.freshAfter(), &buffer);
            if (page.len == 0) {
                if (self.progress) |progress| {
                    const total = @max(handled, progress.tagged_releases_total.load(.acquire));
                    progress.tagged_releases_total.store(total, .release);
                    progress.tagged_releases.store(total, .release);
                }
                if (self.current_item) |current| current.set("");
                return;
            }
            for (page) |*named| {
                cursor = named.release_mbid;
                if (self.isCancelled()) {
                    _ = self.stop(result, .cancelled);
                    return;
                }
                switch (try self.snapshotNamedRelease(named)) {
                    .done => {
                        handled += 1;
                        if (self.progress) |progress| progress.tagged_releases.store(handled, .release);
                    },
                    .cancelled => {
                        _ = self.stop(result, .cancelled);
                        return;
                    },
                    .unavailable => {
                        _ = self.stop(result, .unavailable);
                        return;
                    },
                    .busy => {
                        _ = self.stop(result, .musicbrainz_busy);
                        return;
                    },
                }
            }
        }
    }

    fn showRelease(self: *const LibraryMatching, view: *const database.ReleaseMatchView) void {
        const current = self.current_item orelse return;
        if (view.album_artist.len == 0) return current.set(view.title);
        var buffer: [CurrentItem.capacity]u8 = undefined;
        current.set(std.fmt.bufPrint(&buffer, "{s} — {s}", .{ view.album_artist, view.title }) catch view.title);
    }

    fn freshAfter(self: *const LibraryMatching) i64 {
        const now_s = @divFloor(self.musicbrainz.wall_clock.nowMs(), 1000);
        return now_s - self.musicbrainz.cache_ttl_seconds;
    }

    /// Snapshots every release a Track's release ID names that Orca has not
    /// read, then the Release's best candidate.
    fn snapshotBestCandidate(self: *LibraryMatching, release_id: i64) !ReleaseStep {
        {
            const view = try self.proposals.releaseMatchView(self.allocator, release_id, false);
            defer view.deinit();
            const candidates = try view.candidates(self.allocator);
            defer self.allocator.free(candidates);
            for (candidates) |candidate| {
                if (!candidate.unread()) break;
                const step = try self.snapshotRelease(candidate.release_mbid);
                if (step != .done) return step;
            }
        }
        const view = try self.proposals.releaseMatchView(self.allocator, release_id, false);
        defer view.deinit();
        const best = try view.best(self.allocator) orelse return .done;
        return self.snapshotRelease(best.release_mbid);
    }

    fn snapshotNamedRelease(self: *LibraryMatching, named: *const database.repository.NamedRelease) !ReleaseStep {
        {
            const view = try self.proposals.releaseMatchView(self.allocator, named.release_id, false);
            defer view.deinit();
            self.showRelease(&view);
        }
        return self.snapshotRelease(&named.release_mbid);
    }

    /// Snapshots the release when it has no fresh snapshot.
    fn snapshotRelease(self: *LibraryMatching, release_mbid: []const u8) !ReleaseStep {
        if (try self.tracklists.fetchedAt(release_mbid)) |fetched_at| {
            if (fetched_at > self.freshAfter()) return .done;
        }
        return switch (try self.lookUpRelease(release_mbid)) {
            .found, .unusable => .done,
            .cancelled => .cancelled,
            .unavailable => .unavailable,
            .busy => .busy,
        };
    }

    /// A release, from this run's memory when it asked already. Transient
    /// failures are waited out and retried as searches are. Each answer
    /// replaces the release's tracklist snapshot.
    fn lookUpRelease(self: *LibraryMatching, release_mbid: []const u8) !ReleaseOutcome {
        if (self.last_release) |*last| {
            if (std.mem.eql(u8, last.id(), release_mbid)) return .{ .found = last };
        }
        if (self.unusable_releases.contains(release_mbid)) return .unusable;
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const lookup = self.musicbrainz.lookUpRelease(self.allocator, release_mbid) catch |err| switch (err) {
                error.ProviderRejectedRequest, error.InvalidProviderResponse, error.InvalidMusicBrainzId => {
                    const key = try self.allocator.dupe(u8, release_mbid);
                    errdefer self.allocator.free(key);
                    try self.unusable_releases.put(self.allocator, key, {});
                    return .unusable;
                },
                error.Canceled => return .cancelled,
                error.NetworkUnavailable, error.Offline => return .unavailable,
                error.ProviderBusy => return .busy,
                error.RateLimited, error.ProviderUnavailable, error.Timeout => switch (network.retry.afterFailure(self.musicbrainz.gateway, err, attempt, .wait, self)) {
                    .again => continue,
                    .give_up => return .unavailable,
                    .cancelled => return .cancelled,
                },
                else => return err,
            };
            errdefer lookup.deinit();
            const fetched_at = @divFloor(self.musicbrainz.wall_clock.nowMs(), 1000);
            if (try lookup.tracklist(fetched_at)) |snapshot| try self.tracklists.replace(&snapshot);
            if (self.last_release) |previous| previous.deinit();
            self.last_release = lookup;
            return .{ .found = &self.last_release.? };
        }
    }

    fn forgetReleases(self: *LibraryMatching) void {
        if (self.last_release) |lookup| lookup.deinit();
        self.last_release = null;
        var keys = self.unusable_releases.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.unusable_releases.deinit(self.allocator);
        self.unusable_releases = .empty;
    }

    fn stop(_: *LibraryMatching, result: *Result, reason: enum { cancelled, unavailable, musicbrainz_busy, acoustid_busy }) bool {
        switch (reason) {
            .cancelled => result.cancelled = true,
            .unavailable => result.unavailable = true,
            .musicbrainz_busy => result.busy = .musicbrainz,
            .acoustid_busy => result.busy = .acoustid,
        }
        return false;
    }

    fn takeFingerprint(self: *LibraryMatching, candidate: database.MatchCandidate, result: *Result) !?analysis.chromaprint.Fingerprint {
        return switch (try self.fingerprintOf(candidate.file_id, candidate.path, result)) {
            .taken => |fingerprint| fingerprint,
            .missing, .failed => null,
        };
    }

    fn fingerprintOf(self: *LibraryMatching, file_id: i64, path: ?[]const u8, result: *Result) !Fingerprinted {
        const fingerprinter = self.fingerprinter orelse return .failed;
        const present = path orelse {
            result.fingerprint_failures += 1;
            return .missing;
        };
        const outcome = fingerprinter.fingerprintFile(file_id, present) catch |err| switch (err) {
            error.Cancelled, error.OutOfMemory => return err,
            error.FileNotFound => {
                result.fingerprint_failures += 1;
                return .missing;
            },
            else => {
                result.fingerprint_failures += 1;
                return .failed;
            },
        };
        result.fingerprinted += 1;
        if (outcome.cache_hit) result.fingerprint_cache_hits += 1;
        if (self.progress) |progress| progress.fingerprinted.store(result.fingerprinted, .release);
        return .{ .taken = outcome.fingerprint };
    }

    /// `group` holds Match or Verifiable files: each its `album`.
    fn lookUp(
        self: *LibraryMatching,
        group: anytype,
        fingerprints: *const [acoustid.max_lookup_queries]?analysis.chromaprint.Fingerprint,
        lookups: *[acoustid.max_lookup_queries]?providers.CandidateList,
    ) !LookupOutcome {
        const service = self.acoustid.?;
        var queries: [acoustid.max_lookup_queries]acoustid.LookupQuery = undefined;
        var positions: [acoustid.max_lookup_queries]usize = undefined;
        var count: usize = 0;
        for (group, fingerprints[0..group.len], 0..) |candidate, fingerprint, index| {
            const value = fingerprint orelse continue;
            queries[count] = .{
                .duration_s = value.durationSeconds(),
                .fingerprint = value.encoded,
                .album = if (candidate.album.len == 0) null else candidate.album,
            };
            positions[count] = index;
            count += 1;
        }
        if (count == 0) return .answered;
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const answers = service.lookup(self.allocator, queries[0..count]) catch |err| switch (err) {
                error.InvalidClientKey => return .invalid_client_key,
                error.ProviderRejectedRequest, error.InvalidProviderResponse => return .{ .refused = count },
                error.Canceled => return .cancelled,
                error.NetworkUnavailable, error.Offline => return .unavailable,
                error.ProviderBusy => return .busy,
                error.RateLimited, error.ProviderUnavailable, error.Timeout => switch (network.retry.afterFailure(service.gateway, err, attempt, .wait, self)) {
                    .again => continue,
                    .give_up => return .unavailable,
                    .cancelled => return .cancelled,
                },
                else => return err,
            };
            defer self.allocator.free(answers.answers);
            var unanswered: u64 = 0;
            for (answers.answers, positions[0..count]) |answer, index| {
                lookups[index] = answer;
                if (answer == null) unanswered += 1;
            }
            return if (unanswered == 0) .answered else .{ .refused = unanswered };
        }
    }

    fn searchMusicBrainz(self: *LibraryMatching, query: providers.Query) !SearchOutcome {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const list = self.musicbrainz.search(self.allocator, query) catch |err| switch (err) {
                error.InsufficientIdentificationEvidence => return .insufficient,
                error.ProviderRejectedRequest, error.InvalidProviderResponse => return .refused,
                error.Canceled => return .cancelled,
                error.NetworkUnavailable, error.Offline => return .unavailable,
                error.ProviderBusy => return .busy,
                error.RateLimited, error.ProviderUnavailable, error.Timeout => switch (network.retry.afterFailure(self.musicbrainz.gateway, err, attempt, .wait, self)) {
                    .again => continue,
                    .give_up => return .unavailable,
                    .cancelled => return .cancelled,
                },
                else => return err,
            };
            return .{ .answered = list };
        }
    }

    fn publish(self: *LibraryMatching, result: *const Result) void {
        const progress = self.progress orelse return;
        progress.tracks_seen.store(result.tracks_seen, .release);
        progress.matched.store(result.matched, .release);
        progress.verified.store(result.verified, .release);
    }

    pub fn isCancelled(self: *const LibraryMatching) bool {
        if (self.cancellation) |token| if (token.checkpoint()) return true;
        if (self.musicbrainz.gateway.cancel) |flag| if (flag.load(.acquire)) return true;
        return false;
    }
};

fn addVote(allocator: std.mem.Allocator, votes: *std.ArrayList([36]u8), mbid: []const u8) !void {
    if (!metadata.isMusicBrainzId(mbid)) return;
    for (votes.items) |vote| if (std.mem.eql(u8, &vote, mbid)) return;
    try votes.append(allocator, mbid[0..36].*);
}

fn addFact(allocator: std.mem.Allocator, facts: *std.ArrayList(database.ReleaseFact), fact: database.ReleaseFact) !void {
    for (facts.items) |known| if (std.mem.eql(u8, known.mbid, fact.mbid)) return;
    try facts.append(allocator, fact);
}

fn withoutRecording(items: []database.ProposalEvidence, recording_mbid: ?[]const u8) []database.ProposalEvidence {
    const confirmed = recording_mbid orelse return items;
    var kept: usize = 0;
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item.recording_mbid, confirmed)) continue;
        items[kept] = item;
        kept += 1;
    }
    return items[0..kept];
}

/// Whether a file of the unit disputes its recording id and may be proposed
/// a correction.
fn disputesProposable(files: []const database.VerifiableFile, checks: []const FileCheck) bool {
    for (files, checks) |file, check| {
        if (check.outcome == .disagrees and !file.user_locked) return true;
    }
    return false;
}

/// The recordings AcoustID heard, strongest first. Strings borrow from
/// `candidates`.
fn heardFrom(
    allocator: std.mem.Allocator,
    candidates: []const providers.Candidate,
    recording_mbid: []const u8,
) ![]const database.HeardRecording {
    const heard = try allocator.alloc(database.HeardRecording, candidates.len);
    var count: usize = 0;
    for (candidates) |candidate| {
        heard[count] = .{ .mbid = candidate.provider_id, .score = candidate.fingerprint_similarity orelse continue };
        count += 1;
    }
    std.mem.sort(database.HeardRecording, heard[0..count], {}, strongerFirst);
    keepStored(heard[0..count], recording_mbid);
    return heard[0..count];
}

fn keepStored(heard: []database.HeardRecording, recording_mbid: []const u8) void {
    const last = database.repository.max_heard - 1;
    if (heard.len <= database.repository.max_heard) return;
    for (heard[database.repository.max_heard..], database.repository.max_heard..) |recording, index| {
        if (!std.ascii.eqlIgnoreCase(recording.mbid, recording_mbid)) continue;
        std.mem.copyBackwards(database.HeardRecording, heard[last + 1 .. index + 1], heard[last..index]);
        heard[last] = recording;
        return;
    }
}

fn strongerFirst(_: void, a: database.HeardRecording, b: database.HeardRecording) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.mbid, b.mbid) == .lt;
}

/// A correction is scored on what the file's Track says besides its title:
/// the title may belong to the recording the file is wrongly identified as.
fn correctionQuery(file: database.VerifiableFile) providers.Query {
    return .{
        .artist = if (file.artist.len == 0) null else file.artist,
        .album = if (file.album.len == 0) null else file.album,
        .duration_ms = if (file.duration_ms) |milliseconds| std.math.cast(u64, milliseconds) else null,
    };
}

/// Proposals for the recordings AcoustID heard at least
/// `verify_disagree_minimum`. Payloads borrow from `candidates`.
fn correctionEvidence(
    allocator: std.mem.Allocator,
    file: database.VerifiableFile,
    candidates: []const providers.Candidate,
) ![]database.ProposalEvidence {
    var strong: std.ArrayList(providers.Candidate) = .empty;
    for (candidates) |candidate| {
        const score = candidate.fingerprint_similarity orelse continue;
        if (score < verify_disagree_minimum or std.ascii.eqlIgnoreCase(candidate.provider_id, file.recording_mbid)) continue;
        try strong.append(allocator, candidate);
    }
    const evidence = try providers.workflow.collect(allocator, correctionQuery(file), &.{}, strong.items);
    return evidence.items;
}

/// Points the proposal for `strongest` at the unit's release when the
/// release holds it, and returns its index.
fn joinGroup(release: *const ReleaseLookup, evidence: []database.ProposalEvidence, strongest: database.HeardRecording) !?usize {
    const index = for (evidence, 0..) |item, position| {
        if (std.mem.eql(u8, item.recording_mbid, strongest.mbid)) break position;
    } else return null;
    const enrichment = try release.enrichment(strongest.mbid, null) orelse return null;
    evidence[index].payload.enrich(release.id(), enrichment);
    return index;
}

fn queryFor(candidate: database.MatchCandidate) providers.Query {
    return .{
        .title = if (candidate.title.len == 0) null else candidate.title,
        .artist = if (candidate.artist.len == 0) null else candidate.artist,
        .album = if (candidate.album.len == 0) null else candidate.album,
        .duration_ms = if (candidate.duration_ms) |milliseconds| std.math.cast(u64, milliseconds) else null,
    };
}

const testing = std.testing;
const in_effect_mbid = "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091";
const heard_mbid = "1d2e3f40-5162-4738-8a9b-0c1d2e3f4a5b";

/// Two texts agree when, case and spacing folded, they are this similar.
pub const text_agreement_minimum: f64 = 0.9;

/// A Track's duration agrees with its recording's within this.
pub const duration_agreement_ms: i64 = 1000;

/// Why a Release is, or is not, a MusicBrainz release.
pub const MatchEvidence = struct {
    /// Tracks whose proposal on the release AcoustID heard at 0.9 or more.
    fingerprints_matched: u32,
    tracks: u32,
    /// At least one Track's duration was compared, and each compared one is
    /// within a second of its recording's.
    durations_within_1s: bool,
    artist_agrees: bool,
    title_agrees: bool,
    /// The dates are the same text, so a year does not agree with a full
    /// date.
    date_agrees: bool,
    note: BoundedText(256),
};

/// A Release value beside the candidate's. `differs` is true when the
/// candidate has a value and it is not the local one; release types compare
/// without case, and covers differ only when the Release has none or both
/// sizes are known and unequal.
pub const ReleaseFieldDiff = struct {
    field: database.ReleaseField,
    local: []const u8,
    candidate: []const u8,
    differs: bool,
};

/// A Track beside its track on the candidate. `candidate_title` is empty
/// and `delta_ms` null for a Track the release does not name.
pub const ReleaseTrackAlignment = struct {
    track_id: i64,
    position: u32,
    local_title: []const u8,
    candidate_title: []const u8,
    /// The Track's artist credit.
    local_artist: []const u8,
    /// The release track's artist credit; empty when `candidate_title` is.
    candidate_artist: []const u8,
    /// Storing the release track's title and artist credit would change
    /// the Track's; what the `track_titles` field counts.
    differs: bool,
    /// The recording's duration less the Track's.
    delta_ms: ?i64,
    fingerprint: bool,
};

pub const ReleaseMatchDiff = struct {
    arena: *std.heap.ArenaAllocator,
    release_mbid: []const u8,
    /// One per `database.ReleaseField`, in its order.
    fields: []ReleaseFieldDiff,
    tracks: []ReleaseTrackAlignment,
    /// Tracks the release names.
    aligned: u32,
    /// The Release's front cover's measured size.
    local_artwork_size: ?database.ArtworkSize = null,
    /// The size of the release's Cover Art Archive front cover, from the
    /// stored cover candidates or the cover fetched from it.
    candidate_artwork_size: ?database.ArtworkSize = null,

    pub fn deinit(self: ReleaseMatchDiff) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// The release a view is compared with: `release_mbid`, else its best
/// candidate.
pub fn comparedRelease(view: *const database.ReleaseMatchView, allocator: std.mem.Allocator, release_mbid: ?[]const u8) ![]const u8 {
    if (release_mbid) |mbid| {
        if (!metadata.isMusicBrainzId(mbid)) return error.InvalidMusicBrainzId;
        return mbid;
    }
    const best = (try view.best(allocator)) orelse return error.NoReleaseCandidate;
    return best.release_mbid;
}

/// The release's values as its Tracks' proposals on it give them.
const CandidateRelease = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    date: []const u8 = "",
    release_type: []const u8 = "",
};

fn candidateRelease(view: *const database.ReleaseMatchView, release_mbid: []const u8) CandidateRelease {
    const described = view.describedCandidate(release_mbid);
    var result: CandidateRelease = .{ .title = described.title, .date = described.date orelse "" };
    for (view.tracks) |*track| {
        const proposal = track.chosen(release_mbid) orelse continue;
        if (!proposal.payload.isEnriched() or !std.mem.eql(u8, proposal.payload.release_mbid.?, release_mbid)) continue;
        if (result.artist.len == 0) if (proposal.payload.release_artist) |artist| {
            result.artist = artist;
        };
        if (result.release_type.len == 0) if (proposal.payload.release_type) |kind| {
            result.release_type = kind;
        };
        if (result.artist.len != 0 and result.release_type.len != 0) break;
    }
    return result;
}

fn textsAgree(allocator: std.mem.Allocator, local: []const u8, candidate: []const u8) !bool {
    if (local.len == 0 or candidate.len == 0) return false;
    const local_key = try database.text_key.normalizeKey(allocator, local);
    defer allocator.free(local_key);
    const candidate_key = try database.text_key.normalizeKey(allocator, candidate);
    defer allocator.free(candidate_key);
    return try providers.scoring.textSimilarity(allocator, local_key, candidate_key) >= text_agreement_minimum;
}

/// What a snapshot of the compared release says, which takes the place of
/// the proposals' release values and durations.
pub const SnapshotEvidence = struct {
    title: []const u8,
    artist: []const u8,
    date: []const u8,
    durations_compared: u32,
    durations_within_1s: u32,
};

pub fn releaseMatchEvidence(
    allocator: std.mem.Allocator,
    view: *const database.ReleaseMatchView,
    release_mbid: []const u8,
    snapshot: ?SnapshotEvidence,
) !MatchEvidence {
    var evidence: MatchEvidence = .{
        .fingerprints_matched = 0,
        .tracks = view.track_count,
        .durations_within_1s = false,
        .artist_agrees = false,
        .title_agrees = false,
        .date_agrees = false,
        .note = .{},
    };
    var compared: u32 = 0;
    var within: u32 = 0;
    for (view.tracks) |*track| {
        const proposal = track.chosen(release_mbid) orelse continue;
        if (proposal.fingerprintBacked()) evidence.fingerprints_matched += 1;
        if (durationDelta(track, proposal)) |delta| {
            compared += 1;
            if (@abs(delta) <= duration_agreement_ms) within += 1;
        }
    }
    var release = candidateRelease(view, release_mbid);
    if (snapshot) |snapshotted| {
        compared = snapshotted.durations_compared;
        within = snapshotted.durations_within_1s;
        release.title = snapshotted.title;
        release.artist = snapshotted.artist;
        release.date = snapshotted.date;
    }
    evidence.durations_within_1s = compared != 0 and within == compared;
    evidence.artist_agrees = try textsAgree(allocator, view.album_artist, release.artist);
    evidence.title_agrees = try textsAgree(allocator, view.title, release.title);
    evidence.date_agrees = view.release_date != null and release.date.len != 0 and
        std.mem.eql(u8, view.release_date.?, release.date);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("{d} of {d} tracks match by fingerprint", .{ evidence.fingerprints_matched, evidence.tracks }) catch {};
    if (compared == 0) {
        writer.writeAll("; no durations to compare") catch {};
    } else if (evidence.durations_within_1s) {
        writer.writeAll("; durations agree within 1 s") catch {};
    } else {
        writer.print("; {d} of {d} durations differ by more than 1 s", .{ compared - within, compared }) catch {};
    }
    const differing = [_]struct { agrees: bool, name: []const u8 }{
        .{ .agrees = evidence.artist_agrees, .name = "artist" },
        .{ .agrees = evidence.title_agrees, .name = "title" },
        .{ .agrees = evidence.date_agrees, .name = "date" },
    };
    var names: [differing.len][]const u8 = undefined;
    var disagreeing: usize = 0;
    for (differing) |each| {
        if (each.agrees) continue;
        names[disagreeing] = each.name;
        disagreeing += 1;
    }
    for (names[0..disagreeing], 0..) |name, index| {
        const separator = if (index == 0) "; the " else if (index + 1 == disagreeing) " and " else ", ";
        writer.print("{s}{s}", .{ separator, name }) catch {};
    }
    if (disagreeing != 0) writer.writeAll(if (disagreeing == 1) " differs" else " differ") catch {};
    if (view.release_date != null and release.date.len != 0 and !evidence.date_agrees) {
        writer.print(" ({s} here, {s} on the release)", .{ view.release_date.?, release.date }) catch {};
    }
    writer.writeAll(".") catch {};
    evidence.note.set(writer.buffered());
    return evidence;
}

fn durationDelta(track: *const database.ReleaseMatchTrack, proposal: *const database.ReleaseMatchProposal) ?i64 {
    const local = track.duration_ms orelse return null;
    const recording = std.math.cast(i64, proposal.payload.duration_ms orelse return null) orelse return null;
    if (local <= 0 or recording <= 0) return null;
    return recording - local;
}

pub fn releaseMatchDiff(
    allocator: std.mem.Allocator,
    view: *const database.ReleaseMatchView,
    release_mbid: []const u8,
) !ReleaseMatchDiff {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    var diff: ReleaseMatchDiff = .{ .arena = arena, .release_mbid = "", .fields = &.{}, .tracks = &.{}, .aligned = 0 };
    errdefer diff.deinit();
    const owned = arena.allocator();
    diff.release_mbid = try owned.dupe(u8, release_mbid);

    const tracks = try owned.alloc(ReleaseTrackAlignment, view.tracks.len);
    var titles_differ: u32 = 0;
    for (view.tracks, tracks, 0..) |*track, *alignment, index| {
        const proposal = track.chosen(release_mbid);
        const payload = if (proposal) |chosen| chosen.payload else null;
        const candidate_title = if (payload) |named| named.track_title orelse named.title else "";
        const candidate_artist = if (payload) |named| named.track_artist orelse named.artist else "";
        alignment.* = .{
            .track_id = track.track_id,
            .position = if (payload) |named| named.track_number orelse fallbackPosition(track, index) else fallbackPosition(track, index),
            .local_title = try owned.dupe(u8, track.title),
            .candidate_title = try owned.dupe(u8, candidate_title),
            .local_artist = try owned.dupe(u8, track.artist),
            .candidate_artist = if (candidate_title.len == 0) "" else try owned.dupe(u8, candidate_artist),
            .differs = false,
            .delta_ms = if (proposal) |chosen| durationDelta(track, chosen) else null,
            .fingerprint = if (proposal) |chosen| chosen.fingerprintBacked() else false,
        };
        if (proposal != null or track.names(release_mbid)) diff.aligned += 1;
        alignment.differs = candidate_title.len != 0 and (!std.mem.eql(u8, candidate_title, track.title) or
            (candidate_artist.len != 0 and !std.mem.eql(u8, candidate_artist, track.artist)));
        if (alignment.differs) titles_differ += 1;
    }
    diff.tracks = tracks;

    const release = candidateRelease(view, release_mbid);
    diff.local_artwork_size = view.artwork_size;
    diff.candidate_artwork_size = coverArtSize(view, release_mbid);
    const fields = try owned.alloc(ReleaseFieldDiff, @typeInfo(database.ReleaseField).@"enum".field_names.len);
    for (fields, 0..) |*field_diff, index| {
        const field: database.ReleaseField = @fromBackingInt(@intCast(index));
        const local: []const u8, const candidate: []const u8 = switch (field) {
            .album => .{ view.title, release.title },
            .album_artist => .{ view.album_artist, release.artist },
            .release_date => .{ view.release_date orelse "", release.date },
            .release_type => .{ view.release_type orelse "", release.release_type },
            .release_id => .{ view.release_mbid orelse "", release_mbid },
            .genre => .{ try std.mem.join(owned, " / ", view.genres), "" },
            .artwork => .{
                try sizedArtwork(owned, localArtwork(view, release_mbid), diff.local_artwork_size),
                try sizedArtwork(owned, if (hasCoverArt(view, release_mbid)) cover_art_archive else "", diff.candidate_artwork_size),
            },
            .track_titles => .{
                try std.fmt.allocPrint(owned, "{d} of {d} differ", .{ titles_differ, view.tracks.len }),
                try std.fmt.allocPrint(owned, "{d} of {d} on the release", .{ diff.aligned, view.tracks.len }),
            },
        };
        field_diff.* = .{
            .field = field,
            .local = try owned.dupe(u8, local),
            .candidate = try owned.dupe(u8, candidate),
            .differs = switch (field) {
                .track_titles => titles_differ != 0,
                .release_type => candidate.len != 0 and !std.ascii.eqlIgnoreCase(local, candidate),
                .artwork => candidate.len != 0 and (local.len == 0 or sizesDiffer(diff.local_artwork_size, diff.candidate_artwork_size)),
                else => candidate.len != 0 and !std.mem.eql(u8, local, candidate),
            },
        };
    }
    diff.fields = fields;
    return diff;
}

const cover_art_archive = "Cover Art Archive";

fn fallbackPosition(track: *const database.ReleaseMatchTrack, index: usize) u32 {
    return track.track_number orelse std.math.cast(u32, index + 1) orelse std.math.maxInt(u32);
}

fn localArtwork(view: *const database.ReleaseMatchView, release_mbid: []const u8) []const u8 {
    return switch (view.artwork orelse return "") {
        .embedded => "embedded",
        .folder => "folder",
        .fetched => if (view.artwork_release_mbid != null and std.mem.eql(u8, view.artwork_release_mbid.?, release_mbid))
            cover_art_archive
        else
            "fetched",
        .chosen => "chosen",
    };
}

fn coverArtSize(view: *const database.ReleaseMatchView, release_mbid: []const u8) ?database.ArtworkSize {
    for (view.cover_art_releases, 0..) |mbid, index| {
        if (!std.mem.eql(u8, mbid, release_mbid)) continue;
        if (index < view.cover_art_sizes.len) if (view.cover_art_sizes[index]) |size| return size;
    }
    if (view.artwork == .fetched) if (view.artwork_release_mbid) |mbid| {
        if (std.mem.eql(u8, mbid, release_mbid)) return view.artwork_size;
    };
    return null;
}

fn sizedArtwork(allocator: std.mem.Allocator, source: []const u8, size: ?database.ArtworkSize) ![]const u8 {
    if (source.len == 0) return "";
    const measured = size orelse return std.fmt.allocPrint(allocator, "{s} · —", .{source});
    return std.fmt.allocPrint(allocator, "{s} · {d} × {d}", .{ source, measured.width, measured.height });
}

fn sizesDiffer(local: ?database.ArtworkSize, candidate: ?database.ArtworkSize) bool {
    const a = local orelse return false;
    const b = candidate orelse return false;
    return a.width != b.width or a.height != b.height;
}

fn hasCoverArt(view: *const database.ReleaseMatchView, release_mbid: []const u8) bool {
    if (view.artwork_release_mbid) |mbid| if (std.mem.eql(u8, mbid, release_mbid)) return true;
    for (view.cover_art_releases) |mbid| if (std.mem.eql(u8, mbid, release_mbid)) return true;
    return false;
}

test "a file agrees when AcoustID hears its recording at 0.5, and disagrees only when another reaches 0.9" {
    try testing.expectEqual(database.VerificationOutcome.agrees, classify(in_effect_mbid, &.{
        .{ .mbid = heard_mbid, .score = 0.97 },
        .{ .mbid = in_effect_mbid, .score = verify_agree_minimum },
    }));
    try testing.expectEqual(database.VerificationOutcome.agrees, classify("0B3C4D5E-6F70-4812-9A3B-4C5D6E7F8091", &.{
        .{ .mbid = in_effect_mbid, .score = 0.6 },
    }));
    try testing.expectEqual(database.VerificationOutcome.disagrees, classify(in_effect_mbid, &.{
        .{ .mbid = heard_mbid, .score = verify_disagree_minimum },
        .{ .mbid = in_effect_mbid, .score = 0.4 },
    }));
    try testing.expectEqual(database.VerificationOutcome.unconfirmed, classify(in_effect_mbid, &.{
        .{ .mbid = heard_mbid, .score = 0.89 },
    }));
    try testing.expectEqual(database.VerificationOutcome.unconfirmed, classify(in_effect_mbid, &.{}));
}

test "a correction's confidence ignores the file's title, which may be the wrong recording's" {
    var candidate = try providers.Candidate.init(testing.allocator, "acoustid", heard_mbid, "Pink Moon", "Nick Drake", "Pink Moon");
    defer candidate.deinit();
    candidate.duration_ms = 125_000;
    candidate.fingerprint_similarity = 0.95;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var confidences: [2]f32 = undefined;
    for ([_][]const u8{ "Northern Sky", "Pink Moon" }, &confidences) |title, *confidence| {
        const file: database.VerifiableFile = .{
            .track_id = 1,
            .file_id = 1,
            .title = title,
            .artist = "Nick Drake",
            .album = "Pink Moon",
            .duration_ms = 125_000,
            .path = null,
            .quick_hash = null,
            .recording_mbid = in_effect_mbid,
            .user_locked = false,
            .heard_before = null,
        };
        const evidence = try correctionEvidence(arena.allocator(), file, &.{candidate});
        try testing.expectEqual(@as(usize, 1), evidence.len);
        confidence.* = evidence[0].payload.combinedConfidence();
    }
    try testing.expectEqual(confidences[0], confidences[1]);
}

test "the recording in effect stays among the stored heard recordings when nine others outrank it" {
    var heard: [database.repository.max_heard + 3]database.HeardRecording = undefined;
    const others = [_][]const u8{
        "a0000000-0000-4000-8000-000000000000", "a1000000-0000-4000-8000-000000000000",
        "a2000000-0000-4000-8000-000000000000", "a3000000-0000-4000-8000-000000000000",
        "a4000000-0000-4000-8000-000000000000", "a5000000-0000-4000-8000-000000000000",
        "a6000000-0000-4000-8000-000000000000", "a7000000-0000-4000-8000-000000000000",
        "a8000000-0000-4000-8000-000000000000", "a9000000-0000-4000-8000-000000000000",
    };
    const tagged = "ffffffff-0000-4000-8000-000000000000";
    for (others, heard[0..others.len]) |mbid, *slot| slot.* = .{ .mbid = mbid, .score = 0.99 };
    heard[others.len] = .{ .mbid = tagged, .score = 0.98 };
    keepStored(&heard, tagged);
    try std.testing.expectEqualStrings(tagged, heard[database.repository.max_heard - 1].mbid);
    try std.testing.expectEqualStrings(others[database.repository.max_heard - 1], heard[database.repository.max_heard].mbid);
    try std.testing.expectEqualStrings(others[others.len - 1], heard[others.len].mbid);
    try std.testing.expectEqual(database.VerificationOutcome.agrees, classify(tagged, heard[0..database.repository.max_heard]));
}
