const std = @import("std");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const runtime = @import("runtime.zig");

const JobWorker = job_worker.JobWorker;

pub const Filter = database.JobHistoryFilter;
pub const Text = job.BoundedText(256);

/// A finished Job as its Library remembers it.
pub const JobHistoryEntry = struct {
    id: i64,
    kind: job.Kind,
    /// Unix seconds.
    started_at: i64,
    finished_at: i64,
    state: job.State,
    completed_units: u64,
    total_units: ?u64,
    /// Empty when the Job succeeded.
    error_text: Text,
    /// The tag write's group, for `undoTagWrite`.
    undo_group_id: ?u64,
    /// `jobRetry` would start it again.
    retryable: bool,
    /// What the Job did, as "2,847 files · 3 changed · 2 unreadable".
    summary: Text,

    pub fn fromRow(row: database.JobHistoryRow) ?JobHistoryEntry {
        return .{
            .id = row.id,
            .kind = std.meta.stringToEnum(job.Kind, row.kind) orelse return null,
            .started_at = row.started_at,
            .finished_at = row.finished_at,
            .state = std.meta.stringToEnum(job.State, row.state) orelse return null,
            .completed_units = row.completed_units,
            .total_units = row.total_units,
            .error_text = .init(row.error_text orelse ""),
            .undo_group_id = row.undo_group_id,
            .retryable = row.retryable,
            .summary = .init(row.summary),
        };
    }
};

/// What a retry starts again: the host's request, without the runtime state
/// a worker carries.
pub const RetryRequest = union(enum) {
    scan: job_worker.ScanRequest,
    reconcile: job_worker.ReconcileRequest,
    projection,
    property_backfill: job_worker.BackfillRequest,
    analysis: job_worker.AnalysisRequest,
    duplicate_scan: job_worker.DuplicateScanRequest,
    consistency: job_worker.ConsistencyRequest,
    matching: runtime.MatchRequest,
    cover_art: CoverArt,
    acoustid_submission,
    genre_fill: runtime.GenreFillOptions,

    pub const CoverArt = struct { release_id: i64 };

    /// Null for a Job no retry can start: a tag write, whose plan is spent,
    /// and the one-item fetches a page starts for itself.
    pub fn fromRequest(request: job_worker.Request) ?RetryRequest {
        return switch (request) {
            .scan => |scan| .{ .scan = scan },
            .reconcile => |pending| .{ .reconcile = pending.request },
            .projection => .projection,
            .property_backfill => |backfill| .{ .property_backfill = backfill },
            .analysis => |analysis| .{ .analysis = analysis },
            .duplicate_scan => |duplicates| .{ .duplicate_scan = duplicates },
            .consistency => |consistency| .{ .consistency = consistency },
            .metadata_lookup => |matching| matchingRetry(matching),
            .acoustid_submission => .acoustid_submission,
            .release_info => |info| switch (info.target) {
                .missing_genres => |limit| .{ .genre_fill = .{ .limit = limit, .offline = info.offline } },
                .release => null,
            },
            .mutation, .lyrics, .artist_info => null,
        };
    }

    pub fn encode(self: RetryRequest, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{ .emit_null_optional_fields = false });
    }

    pub fn decode(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(RetryRequest) {
        return std.json.parseFromSlice(RetryRequest, allocator, text, .{ .ignore_unknown_fields = true });
    }
};

fn matchingRetry(matching: job_worker.MatchingRequest) ?RetryRequest {
    const setup = matching.setup;
    if (!matching.lookups) return switch (setup.scope) {
        .release => |release_id| if (matching.cover_art and matching.cover_art_task == .front)
            .{ .cover_art = .{ .release_id = release_id } }
        else
            null,
        .library, .track => null,
    };
    return .{ .matching = .{
        .batch_size = matching.batch_size,
        .limit = matching.limit,
        .mode = setup.mode,
        .track_id = switch (setup.scope) {
            .track => |track_id| track_id,
            .library, .release => null,
        },
        .release_id = switch (setup.scope) {
            .release => |release_id| release_id,
            .library, .track => null,
        },
        .fingerprints = setup.acoustid != null,
        .accept_minimum_confidence = matching.accept_minimum_confidence,
        .cover_art = matching.cover_art,
    } };
}

/// Why a joined worker's Job did not succeed, or null when it did.
pub fn errorText(worker: *const JobWorker, state: job.State, buffer: []u8) ?[]const u8 {
    switch (state) {
        .succeeded => return null,
        .cancelled => return "cancelled",
        else => {},
    }
    if (worker.tagWriteFailure()) |failure| return spaced(@tagName(failure.reason), buffer);
    switch (worker.request) {
        .metadata_lookup => switch (worker.matchStats().busy) {
            .musicbrainz => return "MusicBrainz busy",
            .acoustid => return "AcoustID busy",
            .none => {},
        },
        .acoustid_submission => {
            const outcome = worker.submissionStats().outcome;
            if (outcome != .completed) return spaced(@tagName(outcome), buffer);
        },
        else => {},
    }
    return "failed";
}

fn spaced(name: []const u8, buffer: []u8) []const u8 {
    const length = @min(name.len, buffer.len);
    for (name[0..length], buffer[0..length]) |byte, *out| out.* = if (byte == '_') ' ' else byte;
    return buffer[0..length];
}

/// What a joined worker did, in the words the Activity history shows.
pub fn summary(worker: *const JobWorker, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writeSummary(worker, &writer) catch {};
    return writer.buffered();
}

fn writeSummary(worker: *const JobWorker, writer: *std.Io.Writer) !void {
    var parts: Parts = .{ .writer = writer };
    switch (worker.request) {
        .projection => {
            const stats = worker.scanStats();
            try parts.count(stats.tracks_written, "track", "tracks");
            try parts.count(stats.releases_written, "release", "releases");
        },
        .scan, .reconcile, .mutation => {
            const stats = worker.scanStats();
            try parts.count(stats.files_seen, "file", "files");
            try parts.optional(stats.changed, "changed");
            try parts.optional(stats.marked_missing, "missing");
            try parts.optional(stats.errors, "unreadable");
            if (stats.volume_changed) try parts.text("drive not mounted");
        },
        .property_backfill => {
            const stats = worker.scanStats();
            try parts.count(stats.files_seen, "file", "files");
            try parts.optional(stats.changed, "repaired");
            try parts.optional(stats.errors, "unreadable");
        },
        .analysis => {
            const stats = worker.scanStats();
            try parts.count(stats.files_seen, "file", "files");
            try parts.optional(stats.changed, "measured");
            try parts.optional(stats.errors, "corrupt");
        },
        .duplicate_scan => {
            const stats = worker.scanStats();
            try parts.count(stats.files_seen, "file", "files");
            try parts.optional(stats.tracks_written, "exact duplicates");
            try parts.optional(stats.changed -| stats.tracks_written -| stats.releases_written, "identical-audio duplicates");
            try parts.optional(stats.releases_written, "likely duplicates");
            try parts.optional(stats.unsupported, "not yet analyzed");
        },
        .consistency => {
            const stats = worker.scanStats();
            try parts.count(stats.files_seen, "release", "releases");
            try parts.optional(stats.changed, "metadata issues");
        },
        .metadata_lookup => |matching| {
            const stats = worker.matchStats();
            if (matching.lookups) try parts.count(stats.tracks_examined, "track", "tracks");
            try parts.optional(stats.matched, "matched");
            try parts.optional(stats.confirmed, "confirmed");
            try parts.optional(stats.verified, "verified");
            try parts.optional(stats.disagreed, "disagreed");
            try parts.optional(stats.accepted, "accepted");
            switch (matching.cover_art_task) {
                .front => if (stats.cover_art == .fetched) try parts.text("cover fetched"),
                .candidates => {
                    try parts.count(stats.cover_art_candidates_examined, "candidate", "candidates");
                    try parts.optional(stats.cover_art_candidates_unmeasured, "without a size");
                },
                .use => if (stats.cover_art == .fetched) try parts.text("cover used"),
            }
        },
        .acoustid_submission => {
            const stats = worker.submissionStats();
            try parts.count(stats.files_examined, "file", "files");
            try parts.optional(stats.submitted, "submitted");
        },
        .release_info => try parts.count(worker.progress.load(.acquire), "release", "releases"),
        .lyrics, .artist_info => {},
    }
}

const Parts = struct {
    writer: *std.Io.Writer,
    written: bool = false,

    fn separate(self: *Parts) !void {
        if (self.written) try self.writer.writeAll(" · ");
        self.written = true;
    }

    fn text(self: *Parts, value: []const u8) !void {
        try self.separate();
        try self.writer.writeAll(value);
    }

    fn count(self: *Parts, value: u64, singular: []const u8, plural: []const u8) !void {
        try self.separate();
        try writeGrouped(self.writer, value);
        try self.writer.print(" {s}", .{if (value == 1) singular else plural});
    }

    fn optional(self: *Parts, value: u64, label: []const u8) !void {
        if (value == 0) return;
        try self.separate();
        try writeGrouped(self.writer, value);
        try self.writer.print(" {s}", .{label});
    }
};

fn writeGrouped(writer: *std.Io.Writer, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    for (text, 0..) |digit, index| {
        if (index != 0 and (text.len - index) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

test "a retry request survives its JSON round trip" {
    const subtrees = [_][]const u8{ "A", "B/C" };
    const cases = [_]RetryRequest{
        .{ .scan = .{ .root_id = 4, .batch_size = 64 } },
        .{ .reconcile = .{ .root_id = 2, .scope = .{ .subtrees = &subtrees } } },
        .projection,
        .{ .analysis = .{ .batch_size = 16, .threads = 3 } },
        .{ .matching = .{ .release_id = 9, .mode = .reidentify, .fingerprints = false } },
        .{ .cover_art = .{ .release_id = 12 } },
        .acoustid_submission,
        .{ .genre_fill = .{ .limit = 20, .offline = true } },
    };
    for (cases) |request| {
        const text = try request.encode(std.testing.allocator);
        defer std.testing.allocator.free(text);
        const parsed = try RetryRequest.decode(std.testing.allocator, text);
        defer parsed.deinit();
        const again = try parsed.value.encode(std.testing.allocator);
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualStrings(text, again);
    }
    const parsed = try RetryRequest.decode(std.testing.allocator, "{\"reconcile\":{\"root_id\":2,\"scope\":{\"subtrees\":[\"A\",\"B/C\"]}}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("B/C", parsed.value.reconcile.scope.subtrees[1]);
}

test "counts in a summary are grouped by thousands" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeGrouped(&writer, 2847);
    try writer.writeAll(" ");
    try writeGrouped(&writer, 999);
    try writer.writeAll(" ");
    try writeGrouped(&writer, 1234567);
    try std.testing.expectEqualStrings("2,847 999 1,234,567", writer.buffered());
}
