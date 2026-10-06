//! Sends AcoustID the fingerprints of files whose recording ID Orca chose,
//! through an accepted match or an edit, so others can identify the same
//! recording. Tagged IDs are never sent, and a file is sent once per ID.

const std = @import("std");
const analysis = @import("../analysis/root.zig");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const scanner = @import("scanner.zig");

pub const CancellationToken = scanner.CancellationToken;

const acoustid = providers.acoustid;

pub const Outcome = enum {
    completed,
    cancelled,
    needs_client_key,
    invalid_client_key,
    needs_user_key,
    invalid_user_key,
    unavailable,
    busy,
    credential_unavailable,
};

pub const Result = struct {
    files_examined: u64 = 0,
    /// Files AcoustID accepted a submission for.
    submitted: u64 = 0,
    /// Of those, the ones sent with metadata instead of the recording ID.
    sent_as_metadata: u64 = 0,
    fingerprinted: u64 = 0,
    fingerprint_cache_hits: u64 = 0,
    fingerprint_failures: u64 = 0,
    /// Files in batches AcoustID refused; they stay unsent.
    rejected: u64 = 0,
    requests: u64 = 0,
    outcome: Outcome = .completed,
};

const Pending = struct {
    file_id: i64,
    recording_mbid: []u8,
    as_metadata: bool,
};

pub const AcoustIdSubmission = struct {
    allocator: std.mem.Allocator,
    submissions: *database.AcoustIdSubmissionRepository,
    acoustid: *acoustid.AcoustId,
    fingerprinter: analysis.chromaprint.Fingerprinter,
    /// Holds the user's key under `acoustid.credential_service` and
    /// `acoustid.user_key_account`, read before each request and never kept.
    credentials: ?providers.credentials.Store,
    cancellation: ?*const CancellationToken = null,
    progress: ?*std.atomic.Value(u64) = null,
    batch_size: u32 = 64,

    batch: acoustid.SubmissionBatch = undefined,
    pending: std.ArrayList(Pending) = .empty,

    pub fn run(self: *AcoustIdSubmission) !Result {
        var result: Result = .{};
        if (self.batch_size == 0) return error.InvalidBatchSize;
        {
            const key = self.userKey() catch |err| switch (err) {
                error.CredentialUnreadable => return finish(&result, .credential_unavailable),
                else => return err,
            } orelse return finish(&result, .needs_user_key);
            providers.credentials.wipeAndFree(self.allocator, key);
        }
        self.batch = .init(self.allocator);
        defer self.batch.deinit();
        defer self.pending.deinit(self.allocator);
        defer self.clearPending();

        var cursor: i64 = 0;
        while (true) {
            var page = try self.submissions.submittablePage(self.allocator, cursor, @min(self.batch_size, database.repository.max_page));
            defer page.deinit();
            if (page.items.len == 0) break;
            for (page.items) |item| {
                cursor = item.file_id;
                if (self.isCancelled()) return finish(&result, .cancelled);
                result.files_examined += 1;
                if (self.progress) |counter| counter.store(result.files_examined, .release);
                const fingerprint = self.takeFingerprint(item, &result) catch |err| switch (err) {
                    error.Cancelled => return finish(&result, .cancelled),
                    else => return err,
                } orelse continue;
                defer fingerprint.deinit();
                const submission = submissionItem(item, fingerprint);
                if (!try self.batch.tryAdd(self.allocator, submission)) {
                    if (try self.send(&result)) |stopped| return finish(&result, stopped);
                    if (!try self.batch.tryAdd(self.allocator, submission)) return error.SubmissionTooLarge;
                }
                const mbid = try self.allocator.dupe(u8, item.recording_mbid);
                errdefer self.allocator.free(mbid);
                try self.pending.append(self.allocator, .{
                    .file_id = item.file_id,
                    .recording_mbid = mbid,
                    .as_metadata = submission.recording_mbid == null,
                });
            }
        }
        if (try self.send(&result)) |stopped| return finish(&result, stopped);
        return result;
    }

    fn finish(result: *Result, outcome: Outcome) Result {
        result.outcome = outcome;
        return result.*;
    }

    fn takeFingerprint(
        self: *AcoustIdSubmission,
        item: database.AcoustIdSubmittable,
        result: *Result,
    ) !?analysis.chromaprint.Fingerprint {
        const path = item.path orelse {
            result.fingerprint_failures += 1;
            return null;
        };
        const outcome = self.fingerprinter.fingerprintFile(item.file_id, path) catch |err| switch (err) {
            error.Cancelled, error.OutOfMemory => return err,
            else => {
                result.fingerprint_failures += 1;
                return null;
            },
        };
        result.fingerprinted += 1;
        if (outcome.cache_hit) result.fingerprint_cache_hits += 1;
        return outcome.fingerprint;
    }

    /// Sends the batch, records what AcoustID accepted and empties it. Returns
    /// why the job has to stop, or null to go on.
    fn send(self: *AcoustIdSubmission, result: *Result) !?Outcome {
        if (self.batch.count == 0) return null;
        defer {
            self.batch.clear();
            self.clearPending();
        }
        var attempt: u32 = 0;
        const outcome = while (true) : (attempt += 1) {
            if (self.isCancelled()) return .cancelled;
            const key = self.userKey() catch |err| switch (err) {
                error.CredentialUnreadable => return .credential_unavailable,
                else => return err,
            } orelse return .needs_user_key;
            defer providers.credentials.wipeAndFree(self.allocator, key);
            result.requests += 1;
            break self.acoustid.submit(self.allocator, key, &self.batch) catch |err| switch (err) {
                error.InvalidUserKey, error.InvalidAcoustIdKey => return .invalid_user_key,
                error.InvalidClientKey => return .invalid_client_key,
                error.Canceled => return .cancelled,
                error.NetworkUnavailable, error.Offline => return .unavailable,
                error.ProviderBusy => return .busy,
                error.RateLimited, error.ProviderUnavailable, error.Timeout => switch (network.retry.afterFailure(self.acoustid.gateway, err, attempt, .wait, self)) {
                    .again => continue,
                    .give_up => return .unavailable,
                    .cancelled => return .cancelled,
                },
                else => return err,
            };
        };
        switch (outcome) {
            .rejected => result.rejected += self.batch.count,
            .accepted => |accepted| {
                defer self.allocator.free(accepted);
                const recorded = try self.allocator.alloc(database.AcoustIdSubmission, accepted.len);
                defer self.allocator.free(recorded);
                for (accepted, recorded) |submission, *row| {
                    const pending = self.pending.items[submission.index];
                    row.* = .{
                        .file_id = pending.file_id,
                        .recording_mbid = pending.recording_mbid,
                        .submission_id = submission.submission_id,
                    };
                    if (pending.as_metadata) result.sent_as_metadata += 1;
                }
                try self.submissions.record(recorded);
                result.submitted += accepted.len;
            },
        }
        return null;
    }

    fn userKey(self: *AcoustIdSubmission) !?[]u8 {
        const store = self.credentials orelse return null;
        const stored = store.get(self.allocator, acoustid.credential_service, acoustid.user_key_account) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.CredentialUnreadable,
        };
        const key = stored orelse return null;
        if (key.len == 0) {
            self.allocator.free(key);
            return null;
        }
        return key;
    }

    fn clearPending(self: *AcoustIdSubmission) void {
        for (self.pending.items) |pending| self.allocator.free(pending.recording_mbid);
        self.pending.clearRetainingCapacity();
    }

    pub fn isCancelled(self: *const AcoustIdSubmission) bool {
        if (self.cancellation) |token| if (token.checkpoint()) return true;
        if (self.acoustid.gateway.cancel) |flag| if (flag.load(.acquire)) return true;
        return false;
    }
};

fn submissionItem(item: database.AcoustIdSubmittable, fingerprint: analysis.chromaprint.Fingerprint) acoustid.SubmissionItem {
    const duration_ms = fingerprint.duration_ms;
    return .{
        .duration_s = fingerprint.durationSeconds(),
        .fingerprint = fingerprint.encoded,
        .recording_mbid = if (item.sendsRecordingId(duration_ms)) item.recording_mbid else null,
        .file_format = fileFormat(item.codec),
        .bitrate_kbps = if (duration_ms > 0 and item.size_bytes > 0)
            std.math.cast(u32, @as(u64, @intCast(item.size_bytes)) * 8 / duration_ms)
        else
            null,
        .track = item.title,
        .artist = item.artist,
        .album = item.album,
        .album_artist = item.album_artist,
        .track_number = item.track_number,
        .disc_number = item.disc_number,
        .year = item.year,
    };
}

fn fileFormat(codec: []const u8) []const u8 {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "flac", "FLAC" },
        .{ "mp3", "MP3" },
        .{ "mp2", "MP2" },
        .{ "mp1", "MP1" },
        .{ "aac", "AAC" },
        .{ "alac", "ALAC" },
        .{ "opus", "Opus" },
        .{ "vorbis", "Vorbis" },
        .{ "qoa", "QOA" },
        .{ "pcm", "PCM" },
        .{ "pcm_float", "PCM" },
    };
    for (names) |entry| if (std.mem.eql(u8, entry[0], codec)) return entry[1];
    return "";
}
