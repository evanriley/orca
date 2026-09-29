const std = @import("std");
const database = @import("../database/root.zig");
const providers = @import("../providers/root.zig");
const scanner = @import("scanner.zig");

pub const CancellationToken = scanner.CancellationToken;

const initial_backoff_ms: u64 = 60_000;
const maximum_attempts = 3;
const cancel_poll_ms: u64 = 100;

pub const Result = struct {
    tracks_seen: u64 = 0,
    matched: u64 = 0,
    unmatched: u64 = 0,
    insufficient: u64 = 0,
    refused: u64 = 0,
    proposals_stored: u64 = 0,
    requests_answered: u64 = 0,
    cache_hits: u64 = 0,
    cancelled: bool = false,
    unavailable: bool = false,
};

const Outcome = union(enum) {
    stored: u32,
    insufficient,
    refused,
    cancelled,
    unavailable,
};

pub const LibraryMatching = struct {
    allocator: std.mem.Allocator,
    proposals: *database.IdentificationProposalRepository,
    musicbrainz: *providers.musicbrainz.MusicBrainz,
    cancellation: ?*const CancellationToken = null,
    progress: ?*std.atomic.Value(u64) = null,
    batch_size: usize = 64,
    limit: ?u32 = null,

    pub fn run(self: *LibraryMatching) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        var result: Result = .{};
        const page_limit: u32 = @intCast(@min(self.batch_size, @as(usize, database.repository.max_page)));
        var cursor: i64 = 0;
        walk: while (true) {
            var page = try self.proposals.unidentifiedPage(self.allocator, cursor, page_limit);
            defer page.deinit();
            if (page.items.len == 0) break;
            for (page.items) |candidate| {
                if (self.limit) |limit| if (result.tracks_seen >= limit) break :walk;
                if (self.isCancelled()) {
                    result.cancelled = true;
                    break :walk;
                }
                cursor = candidate.track_id;
                switch (try self.search(candidate)) {
                    .stored => |count| {
                        if (count == 0) result.unmatched += 1 else result.matched += 1;
                        result.proposals_stored += count;
                    },
                    .insufficient => result.insufficient += 1,
                    .refused => result.refused += 1,
                    .cancelled => {
                        result.cancelled = true;
                        break :walk;
                    },
                    .unavailable => {
                        result.unavailable = true;
                        break :walk;
                    },
                }
                result.tracks_seen += 1;
                if (self.progress) |counter| counter.store(result.tracks_seen, .release);
            }
        }
        result.requests_answered = self.musicbrainz.requests_answered;
        result.cache_hits = self.musicbrainz.cache_hits;
        return result;
    }

    fn search(self: *LibraryMatching, candidate: database.MatchCandidate) !Outcome {
        const query: providers.Query = .{
            .title = candidate.title,
            .artist = candidate.artist,
            .album = if (candidate.album.len == 0) null else candidate.album,
            .duration_ms = if (candidate.duration_ms) |milliseconds| std.math.cast(u64, milliseconds) else null,
        };
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const stored = providers.workflow.identify(
                self.allocator,
                self.proposals,
                self.musicbrainz.provider(),
                candidate.file_id,
                query,
            ) catch |err| switch (err) {
                error.InsufficientIdentificationEvidence => return .insufficient,
                error.ProviderRejectedRequest, error.InvalidProviderResponse => return .refused,
                error.Canceled => return .cancelled,
                error.NetworkUnavailable, error.Offline => return .unavailable,
                error.RateLimited, error.ProviderUnavailable, error.Timeout => {
                    if (attempt + 1 >= maximum_attempts) return .unavailable;
                    if (!self.backOff(attempt)) return .cancelled;
                    continue;
                },
                else => return err,
            };
            return .{ .stored = stored };
        }
    }

    /// False when cancelled while waiting.
    fn backOff(self: *LibraryMatching, attempt: u32) bool {
        const gateway = self.musicbrainz.gateway;
        const backoff_ms = initial_backoff_ms << @intCast(attempt);
        var until = gateway.clock.nowMs() +| @as(i64, @intCast(backoff_ms));
        if (gateway.blockedUntilMs()) |blocked| until = @max(until, blocked);
        while (true) {
            if (self.isCancelled()) return false;
            const now = gateway.clock.nowMs();
            if (now >= until) return true;
            gateway.clock.sleepMs(@min(cancel_poll_ms, @as(u64, @intCast(until - now)))) catch return false;
        }
    }

    fn isCancelled(self: *const LibraryMatching) bool {
        if (self.cancellation) |token| if (token.isCancelled()) return true;
        if (self.musicbrainz.gateway.cancel) |flag| if (flag.load(.acquire)) return true;
        return false;
    }
};
