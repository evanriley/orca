const std = @import("std");
const analysis = @import("../analysis/root.zig");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const scanner = @import("scanner.zig");

pub const CancellationToken = scanner.CancellationToken;

const acoustid = providers.acoustid;
const ReleaseLookup = providers.musicbrainz.ReleaseLookup;

const initial_backoff_ms: u64 = 60_000;
const maximum_attempts = 3;
const cancel_poll_ms: u64 = 100;

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

pub const Result = struct {
    tracks_seen: u64 = 0,
    matched: u64 = 0,
    unmatched: u64 = 0,
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
    musicbrainz: *providers.musicbrainz.MusicBrainz,
    /// Null leaves AcoustID out; `acoustid_use` says why.
    acoustid: ?*acoustid.AcoustId = null,
    acoustid_use: AcoustIdUse = .off,
    fingerprinter: ?analysis.chromaprint.Fingerprinter = null,
    cancellation: ?*const CancellationToken = null,
    progress: ?*Progress = null,
    batch_size: usize = 64,
    limit: ?u32 = null,
    scope: database.MatchScope = .library,
    last_release: ?ReleaseLookup = null,
    unusable_releases: std.StringHashMapUnmanaged(void) = .empty,

    pub fn run(self: *LibraryMatching) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        defer self.forgetReleases();
        const acoustid_service = self.acoustid;
        var result: Result = .{ .acoustid = if (acoustid_service != null) .searched else self.acoustid_use };
        const page_limit: u32 = @intCast(@min(self.batch_size, @as(usize, database.repository.max_page)));
        var cursor: i64 = 0;
        walk: while (true) {
            var page = try self.proposals.unidentifiedPage(self.allocator, self.scope, self.acoustid != null, cursor, page_limit);
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
        if (!stopped) switch (self.scope) {
            .release => |release_id| if (self.isCancelled()) {
                _ = self.stop(&result, .cancelled);
            } else switch (try self.alignRelease(release_id)) {
                .done => {},
                .cancelled => _ = self.stop(&result, .cancelled),
                .unavailable => _ = self.stop(&result, .unavailable),
                .busy => _ = self.stop(&result, .musicbrainz_busy),
            },
            .library, .track => {},
        };
        result.requests_answered = self.musicbrainz.requests_answered;
        result.cache_hits = self.musicbrainz.cache_hits;
        if (acoustid_service) |service| {
            result.acoustid_requests = service.requests_answered;
            result.acoustid_cache_hits = service.cache_hits;
        }
        return result;
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
                switch (try self.enrich(evidence.items, candidate.tagged_track_number)) {
                    .done => {},
                    .cancelled => return self.stop(result, .cancelled),
                    .unavailable => return self.stop(result, .unavailable),
                    .busy => return self.stop(result, .musicbrainz_busy),
                }
                const stored = try self.proposals.recordSearch(self.allocator, candidate.file_id, answered, evidence.items);
                result.proposals_stored += stored;
                if (stored == 0) result.unmatched += 1 else result.matched += 1;
            }
            result.tracks_seen += 1;
            self.publish(result);
        }
        return true;
    }

    /// Fills in what the release of the most confident MusicBrainz
    /// proposal says, on every proposal naming that release.
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
            const named = item.payload.release_mbid orelse continue;
            if (!std.mem.eql(u8, named, release.id())) continue;
            const enrichment = try release.enrichment(item.recording_mbid, tagged_track_number) orelse continue;
            item.payload.enrich(release.id(), enrichment);
        }
        return .done;
    }

    /// Match Album's second phase. Each file votes once for every release
    /// its stored proposals list; the winner is looked up, and every proposal
    /// listing it is pointed at it with what it says.
    fn alignRelease(self: *LibraryMatching, release_id: i64) !ReleaseStep {
        const list = try self.proposals.releaseProposals(self.allocator, release_id);
        defer list.deinit();
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const payloads = try scratch.alloc(?database.ProposalPayload, list.items.len);
        var tally: database.repository.MbidTally = .{};
        defer tally.deinit(self.allocator);
        var file_votes: std.ArrayList([36]u8) = .empty;
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
        }
        for (file_votes.items) |mbid| try tally.add(self.allocator, mbid);
        const winner = tally.winner(list.tag) orelse return .done;
        const release = switch (try self.lookUpRelease(&winner)) {
            .found => |lookup| lookup,
            .unusable => return .done,
            .cancelled => return .cancelled,
            .unavailable => return .unavailable,
            .busy => return .busy,
        };
        for (list.items, payloads) |item, slot| {
            var payload = slot orelse continue;
            if (!payload.listsRelease(&winner)) continue;
            const enrichment = try release.enrichment(item.recording_mbid, item.tagged_track_number) orelse continue;
            payload.enrich(release.id(), enrichment);
            const encoded = try payload.encode(scratch);
            if (std.mem.eql(u8, encoded, item.payload)) continue;
            try self.proposals.updatePayload(item.id, encoded);
        }
        return .done;
    }

    /// A release, from this run's memory when it asked already. Transient
    /// failures are waited out and retried as searches are.
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
                error.RateLimited, error.ProviderUnavailable, error.Timeout => {
                    if (attempt + 1 >= maximum_attempts) return .unavailable;
                    if (!self.backOff(self.musicbrainz.gateway, attempt)) return .cancelled;
                    continue;
                },
                else => return err,
            };
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
        const fingerprinter = self.fingerprinter orelse return null;
        const path = candidate.path orelse {
            result.fingerprint_failures += 1;
            return null;
        };
        const outcome = fingerprinter.fingerprintFile(candidate.file_id, path) catch |err| switch (err) {
            error.Cancelled, error.OutOfMemory => return err,
            else => {
                result.fingerprint_failures += 1;
                return null;
            },
        };
        result.fingerprinted += 1;
        if (outcome.cache_hit) result.fingerprint_cache_hits += 1;
        if (self.progress) |progress| progress.fingerprinted.store(result.fingerprinted, .release);
        return outcome.fingerprint;
    }

    fn lookUp(
        self: *LibraryMatching,
        group: []const database.MatchCandidate,
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
                error.RateLimited, error.ProviderUnavailable, error.Timeout => {
                    if (attempt + 1 >= maximum_attempts) return .unavailable;
                    if (!self.backOff(service.gateway, attempt)) return .cancelled;
                    continue;
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
                error.RateLimited, error.ProviderUnavailable, error.Timeout => {
                    if (attempt + 1 >= maximum_attempts) return .unavailable;
                    if (!self.backOff(self.musicbrainz.gateway, attempt)) return .cancelled;
                    continue;
                },
                else => return err,
            };
            return .{ .answered = list };
        }
    }

    /// False when cancelled while waiting.
    fn backOff(self: *LibraryMatching, gateway: *network.Gateway, attempt: u32) bool {
        const backoff_ms = network.client.jittered(gateway.random, initial_backoff_ms << @intCast(attempt));
        var until = gateway.clock.nowMs() +| @as(i64, @intCast(backoff_ms));
        if (gateway.blockedUntilMs()) |blocked| until = @max(until, blocked);
        while (true) {
            if (self.isCancelled()) return false;
            const now = gateway.clock.nowMs();
            if (now >= until) return true;
            gateway.clock.sleepMs(@min(cancel_poll_ms, @as(u64, @intCast(until - now)))) catch return false;
        }
    }

    fn publish(self: *LibraryMatching, result: *const Result) void {
        const progress = self.progress orelse return;
        progress.tracks_seen.store(result.tracks_seen, .release);
        progress.matched.store(result.matched, .release);
    }

    fn isCancelled(self: *const LibraryMatching) bool {
        if (self.cancellation) |token| if (token.isCancelled()) return true;
        if (self.musicbrainz.gateway.cancel) |flag| if (flag.load(.acquire)) return true;
        return false;
    }
};

fn addVote(allocator: std.mem.Allocator, votes: *std.ArrayList([36]u8), mbid: []const u8) !void {
    if (!metadata.isMusicBrainzId(mbid)) return;
    for (votes.items) |vote| if (std.mem.eql(u8, &vote, mbid)) return;
    try votes.append(allocator, mbid[0..36].*);
}

fn queryFor(candidate: database.MatchCandidate) providers.Query {
    return .{
        .title = if (candidate.title.len == 0) null else candidate.title,
        .artist = if (candidate.artist.len == 0) null else candidate.artist,
        .album = if (candidate.album.len == 0) null else candidate.album,
        .duration_ms = if (candidate.duration_ms) |milliseconds| std.math.cast(u64, milliseconds) else null,
    };
}
