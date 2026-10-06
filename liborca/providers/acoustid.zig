const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/model.zig");
const network = @import("../network/root.zig");
const model = @import("model.zig");
const scoring = @import("scoring.zig");
const url_encoding = @import("url.zig");

pub const service = "acoustid";
pub const minimum_interval_ms: u64 = 334;
pub const default_server = "https://api.acoustid.org";
/// Where a `CredentialStore` holds AcoustID keys: `client-key` overrides the
/// application key a host sets, and `user-key` is the user's own key, needed
/// only to submit.
pub const credential_service = "org.acoustid";
pub const client_key_account = "client-key";
pub const user_key_account = "user-key";

pub const max_lookup_queries = 20;
pub const max_submission_items = 50;
/// Below the service's 1 MiB request limit, so a batch is never refused for
/// its size.
pub const max_submission_body_bytes = 900 * 1024;
const submission_header_reserve = 1024;
pub const max_key_bytes = 256;

pub const LookupQuery = struct {
    duration_s: u32,
    fingerprint: []const u8,
    /// Chooses which of a recording's release groups names the album.
    album: ?[]const u8 = null,
};

/// One answer per query, in the order asked. Null where AcoustID did not
/// answer for a query.
pub const LookupAnswers = struct {
    allocator: std.mem.Allocator,
    answers: []?model.CandidateList,

    pub fn deinit(self: LookupAnswers) void {
        for (self.answers) |answer| if (answer) |list| list.deinit();
        self.allocator.free(self.answers);
    }
};

pub const SubmissionItem = struct {
    duration_s: u32,
    fingerprint: []const u8,
    /// Null sends the metadata below instead.
    recording_mbid: ?[]const u8,
    file_format: []const u8 = "",
    bitrate_kbps: ?u32 = null,
    track: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    album_artist: []const u8 = "",
    track_number: ?i64 = null,
    disc_number: ?i64 = null,
    year: ?u32 = null,
};

pub const AcceptedSubmission = struct {
    index: usize,
    submission_id: i64,
};

pub const SubmitOutcome = union(enum) {
    /// The items AcoustID took, by their index in the batch.
    accepted: []AcceptedSubmission,
    /// The service refused the batch with this status.
    rejected: u16,
};

/// Item parameters for one submission request, measured as they are added so
/// a request never exceeds `max_submission_items` or the body limit.
pub const SubmissionBatch = struct {
    body: std.Io.Writer.Allocating,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SubmissionBatch {
        return .{ .body = .init(allocator) };
    }

    pub fn deinit(self: *SubmissionBatch) void {
        self.body.deinit();
    }

    pub fn clear(self: *SubmissionBatch) void {
        self.body.clearRetainingCapacity();
        self.count = 0;
    }

    /// False when the item does not fit, in which case nothing is added.
    pub fn tryAdd(self: *SubmissionBatch, allocator: std.mem.Allocator, item: SubmissionItem) !bool {
        if (self.count >= max_submission_items) return false;
        var encoded = std.Io.Writer.Allocating.init(allocator);
        defer encoded.deinit();
        try writeSubmissionItem(&encoded.writer, self.count, item);
        if (submission_header_reserve + self.body.written().len + encoded.written().len > max_submission_body_bytes) {
            if (self.count == 0) return error.SubmissionTooLarge;
            return false;
        }
        try self.body.writer.writeAll(encoded.written());
        self.count += 1;
        return true;
    }
};

pub const AcoustId = struct {
    gateway: *network.Gateway,
    cache: *database.ProviderCacheRepository,
    /// Unix time in milliseconds: cache entries outlive the process.
    wall_clock: network.client.Clock,
    server: []const u8 = default_server,
    client_key: []const u8,
    cache_ttl_seconds: i64 = 90 * 24 * 60 * 60,
    refusal_ttl_seconds: i64 = 7 * 24 * 60 * 60,
    offline: bool = false,
    requests_answered: u64 = 0,
    cache_hits: u64 = 0,

    /// Answers each query from the cache, or asks AcoustID about the rest in
    /// one request. A batch AcoustID refuses is asked again one query per
    /// request, and only a single query's refusal is cached. At most
    /// `max_lookup_queries` queries.
    pub fn lookup(self: *AcoustId, allocator: std.mem.Allocator, queries: []const LookupQuery) !LookupAnswers {
        if (queries.len > max_lookup_queries) return error.TooManyQueries;
        try validateKey(self.client_key);
        const answers = try allocator.alloc(?model.CandidateList, queries.len);
        @memset(answers, null);
        var result: LookupAnswers = .{ .allocator = allocator, .answers = answers };
        errdefer result.deinit();
        const keys = try allocator.alloc([]u8, queries.len);
        var keys_made: usize = 0;
        defer {
            for (keys[0..keys_made]) |key| allocator.free(key);
            allocator.free(keys);
        }
        for (queries, keys) |query, *key| {
            if (query.duration_s == 0 or query.fingerprint.len == 0) return error.InvalidLookupQuery;
            key.* = try cacheKey(allocator, query);
            keys_made += 1;
        }
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        var misses: std.ArrayList(usize) = .empty;
        defer misses.deinit(allocator);
        for (queries, keys, answers, 0..) |query, key, *answer, index| {
            if (try self.cache.get(allocator, service, key, now_s, false)) |cached| {
                defer cached.deinit();
                if (cached.status == 200) answer.* = try decodeCached(allocator, cached.body, query.album);
                self.cache_hits += 1;
            } else try misses.append(allocator, index);
        }
        if (misses.items.len == 0) return result;
        if (try self.ask(allocator, queries, keys, misses.items, answers, now_s) == .answered) return result;
        if (misses.items.len == 1) return error.ProviderRejectedRequest;
        for (misses.items) |index| _ = try self.ask(allocator, queries, keys, &.{index}, answers, now_s);
        return result;
    }

    fn ask(
        self: *AcoustId,
        allocator: std.mem.Allocator,
        queries: []const LookupQuery,
        keys: []const []u8,
        misses: []const usize,
        answers: []?model.CandidateList,
        now_s: i64,
    ) !enum { answered, refused } {
        const body = try self.lookupBody(allocator, queries, misses);
        defer allocator.free(body);
        const response = self.post(allocator, "/v2/lookup", body) catch |err| switch (err) {
            error.RateLimited, error.NetworkUnavailable, error.Timeout, error.Offline => {
                if (try self.stale(allocator, queries, keys, misses, answers, now_s)) return .answered;
                return err;
            },
            else => return err,
        };
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 408 or response.status >= 500) {
            if (try self.stale(allocator, queries, keys, misses, answers, now_s)) return .answered;
            return error.ProviderUnavailable;
        }
        if (response.status != 200) {
            const refused = refusal(allocator, response.body);
            if (refused != error.ProviderRejectedRequest or !network.client.isPermanentRejection(response.status))
                return refused;
            if (misses.len == 1)
                try self.cache.put(service, keys[misses[0]], response.status, response.body, now_s + self.refusal_ttl_seconds);
            return .refused;
        }

        var parsed = try Parsed.init(allocator, response.body);
        defer parsed.deinit();
        for (parsed.value.fingerprints) |entry| {
            const position = std.math.cast(usize, entry.index orelse continue) orelse continue;
            if (position >= misses.len) continue;
            const index = misses[position];
            if (answers[index] != null) continue;
            const normalized = try parsed.normalize(allocator, entry.results);
            defer allocator.free(normalized);
            try self.cache.put(service, keys[index], 200, normalized, now_s + self.cache_ttl_seconds);
            answers[index] = try decodeCached(allocator, normalized, queries[index].album);
        }
        return .answered;
    }

    /// Sends one batch as the user whose key is `user_key`. A key AcoustID does
    /// not accept is `error.InvalidUserKey` or `error.InvalidClientKey`.
    pub fn submit(
        self: *AcoustId,
        allocator: std.mem.Allocator,
        user_key: []const u8,
        batch: *SubmissionBatch,
    ) !SubmitOutcome {
        try validateKey(self.client_key);
        try validateKey(user_key);
        if (batch.count == 0) return .{ .accepted = &.{} };
        var body = std.Io.Writer.Allocating.init(allocator);
        defer {
            std.crypto.secureZero(u8, body.writer.buffer);
            body.deinit();
        }
        try self.writeHeader(&body.writer);
        try body.writer.writeAll("&user=");
        try url_encoding.writeEncoded(&body.writer, user_key);
        try body.writer.writeAll(batch.body.written());
        const response = try self.post(allocator, "/v2/submit", body.written());
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 401 or response.status == 403) return error.InvalidUserKey;
        if (response.status == 408 or response.status >= 500) return error.ProviderUnavailable;
        if (response.status != 200) return switch (refusal(allocator, response.body)) {
            error.ProviderRejectedRequest => .{ .rejected = response.status },
            else => |err| err,
        };
        return .{ .accepted = try parseSubmissions(allocator, response.body, batch.count) };
    }

    fn post(self: *AcoustId, allocator: std.mem.Allocator, path: []const u8, form: []const u8) !network.client.Response {
        if (self.offline) return error.Offline;
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, self.server, "/"), path });
        defer allocator.free(url);
        const compressed = try gzip(allocator, form);
        defer {
            std.crypto.secureZero(u8, compressed);
            allocator.free(compressed);
        }
        return self.gateway.execute(allocator, .post, url, compressed, &.{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "content-encoding", .value = "gzip" },
        });
    }

    fn writeHeader(self: *const AcoustId, writer: *std.Io.Writer) !void {
        try writer.writeAll("client=");
        try url_encoding.writeEncoded(writer, self.client_key);
        try writer.writeAll("&clientversion=");
        try url_encoding.writeEncoded(writer, self.gateway.config.identity.version);
        try writer.writeAll("&format=json");
    }

    fn lookupBody(self: *const AcoustId, allocator: std.mem.Allocator, queries: []const LookupQuery, misses: []const usize) ![]u8 {
        var body = std.Io.Writer.Allocating.init(allocator);
        errdefer body.deinit();
        try self.writeHeader(&body.writer);
        try body.writer.writeAll("&meta=recordings+releasegroups+compress&batch=1");
        for (misses, 0..) |index, position| {
            try body.writer.print("&duration.{d}={d}&fingerprint.{d}=", .{ position, queries[index].duration_s, position });
            try url_encoding.writeEncoded(&body.writer, queries[index].fingerprint);
        }
        var list = body.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn stale(
        self: *AcoustId,
        allocator: std.mem.Allocator,
        queries: []const LookupQuery,
        keys: []const []u8,
        misses: []const usize,
        answers: []?model.CandidateList,
        now_s: i64,
    ) !bool {
        for (misses) |index| {
            const entry = try self.cache.get(allocator, service, keys[index], now_s, true) orelse return false;
            defer entry.deinit();
            if (entry.status != 200) return false;
        }
        for (misses) |index| {
            const entry = (try self.cache.get(allocator, service, keys[index], now_s, true)).?;
            defer entry.deinit();
            answers[index] = try decodeCached(allocator, entry.body, queries[index].album);
        }
        return true;
    }
};

fn validateKey(key: []const u8) !void {
    if (key.len == 0 or key.len > max_key_bytes) return error.InvalidAcoustIdKey;
}

fn cacheKey(allocator: std.mem.Allocator, query: LookupQuery) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(query.fingerprint, &digest, .{});
    return std.fmt.allocPrint(allocator, "lookup:{d}:{x}", .{ query.duration_s, &digest });
}

fn refusal(allocator: std.mem.Allocator, body: []const u8) error{ InvalidClientKey, InvalidUserKey, ProviderRejectedRequest } {
    const Refusal = struct {
        @"error": ?struct { code: i64 = 0 } = null,
    };
    const parsed = std.json.parseFromSlice(Refusal, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return error.ProviderRejectedRequest;
    defer parsed.deinit();
    const code = if (parsed.value.@"error") |details| details.code else 0;
    return switch (code) {
        4 => error.InvalidClientKey,
        6 => error.InvalidUserKey,
        else => error.ProviderRejectedRequest,
    };
}

const Artist = struct {
    id: []const u8 = "",
    name: ?[]const u8 = null,
    joinphrase: []const u8 = "",
};

const ReleaseGroup = struct {
    id: []const u8 = "",
    title: ?[]const u8 = null,
    type: ?[]const u8 = null,
};

const Recording = struct {
    id: []const u8 = "",
    title: ?[]const u8 = null,
    duration: ?f64 = null,
    artists: ?[]const Artist = null,
    releasegroups: ?[]const ReleaseGroup = null,
};

const Result = struct {
    score: f64 = 0,
    recordings: []const Recording = &.{},
};

const Entry = struct {
    index: ?i64 = null,
    results: []const Result = &.{},
};

const Envelope = struct {
    status: []const u8 = "",
    fingerprints: []const Entry = &.{},
};

const Normalized = struct {
    id: []const u8,
    score: f64,
    title: []const u8 = "",
    artist: []const u8 = "",
    duration_ms: ?u64 = null,
    albums: []const []const u8 = &.{},
};

/// A parsed lookup answer. With `compress`, AcoustID may name an artist,
/// release group or recording in full once and by id alone elsewhere, so
/// names are resolved across the whole answer.
const Parsed = struct {
    parsed: std.json.Parsed(Envelope),
    value: Envelope,
    artist_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    group_titles: std.StringHashMapUnmanaged([]const u8) = .empty,
    recordings: std.StringHashMapUnmanaged(Recording) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, body: []const u8) !Parsed {
        const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        var self: Parsed = .{ .parsed = parsed, .value = parsed.value, .allocator = allocator };
        errdefer self.deinit();
        if (!std.mem.eql(u8, parsed.value.status, "ok")) return error.InvalidProviderResponse;
        for (parsed.value.fingerprints) |entry| for (entry.results) |result| for (result.recordings) |recording| {
            if (recording.title != null or recording.artists != null or recording.duration != null) {
                const slot = try self.recordings.getOrPut(allocator, recording.id);
                if (!slot.found_existing) slot.value_ptr.* = recording;
            }
            for (recording.artists orelse &.{}) |artist| if (artist.name) |name|
                try self.artist_names.put(allocator, artist.id, name);
            for (recording.releasegroups orelse &.{}) |group| if (group.title) |title|
                try self.group_titles.put(allocator, group.id, title);
        };
        return self;
    }

    fn deinit(self: *Parsed) void {
        self.artist_names.deinit(self.allocator);
        self.group_titles.deinit(self.allocator);
        self.recordings.deinit(self.allocator);
        self.parsed.deinit();
    }

    fn normalize(self: *const Parsed, allocator: std.mem.Allocator, results: []const Result) ![]u8 {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var kept: std.ArrayList(Normalized) = .empty;
        for (results) |result| for (result.recordings) |listed| {
            if (!metadata.isMusicBrainzId(listed.id)) continue;
            const recording = if (listed.title == null and listed.artists == null)
                self.recordings.get(listed.id) orelse listed
            else
                listed;
            const score = std.math.clamp(result.score, 0, 1);
            const existing = for (kept.items) |*item| {
                if (std.mem.eql(u8, item.id, listed.id)) break item;
            } else null;
            if (existing) |item| {
                item.score = @max(item.score, score);
                continue;
            }
            try kept.append(scratch, .{
                .id = listed.id,
                .score = score,
                .title = recording.title orelse "",
                .artist = try self.joinArtists(scratch, recording.artists orelse &.{}),
                .duration_ms = if (recording.duration) |seconds|
                    if (seconds > 0) @as(u64, @intFromFloat(@round(seconds * 1000))) else null
                else
                    null,
                .albums = try self.albumTitles(scratch, recording.releasegroups orelse &.{}),
            });
        };
        var encoded = std.Io.Writer.Allocating.init(allocator);
        errdefer encoded.deinit();
        try std.json.Stringify.value(kept.items, .{}, &encoded.writer);
        var list = encoded.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn joinArtists(self: *const Parsed, allocator: std.mem.Allocator, artists: []const Artist) ![]const u8 {
        var joined: std.ArrayList(u8) = .empty;
        for (artists, 0..) |artist, index| {
            const name = artist.name orelse self.artist_names.get(artist.id) orelse continue;
            if (index > 0 and joined.items.len > 0 and artists[index - 1].joinphrase.len == 0)
                try joined.appendSlice(allocator, "; ");
            try joined.appendSlice(allocator, name);
            try joined.appendSlice(allocator, artist.joinphrase);
        }
        return joined.items;
    }

    fn albumTitles(self: *const Parsed, allocator: std.mem.Allocator, groups: []const ReleaseGroup) ![]const []const u8 {
        var titles: std.ArrayList([]const u8) = .empty;
        for ([_]bool{ true, false }) |albums_first| for (groups) |group| {
            const is_album = if (group.type) |kind| std.mem.eql(u8, kind, "Album") else false;
            if (is_album != albums_first) continue;
            const title = group.title orelse self.group_titles.get(group.id) orelse continue;
            for (titles.items) |seen| {
                if (std.mem.eql(u8, seen, title)) break;
            } else try titles.append(allocator, title);
        };
        return titles.items;
    }
};

fn decodeCached(allocator: std.mem.Allocator, body: []const u8, album: ?[]const u8) !model.CandidateList {
    const parsed = std.json.parseFromSlice([]const Normalized, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderResponse,
    };
    defer parsed.deinit();
    var candidates: std.ArrayList(model.Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit();
        candidates.deinit(allocator);
    }
    for (parsed.value) |item| {
        var candidate = try model.Candidate.init(
            allocator,
            service,
            item.id,
            item.title,
            item.artist,
            try closestAlbum(allocator, item.albums, album),
        );
        errdefer candidate.deinit();
        candidate.duration_ms = item.duration_ms;
        candidate.fingerprint_similarity = @floatCast(item.score);
        try candidates.append(allocator, candidate);
    }
    return .{ .allocator = allocator, .items = try candidates.toOwnedSlice(allocator) };
}

fn closestAlbum(allocator: std.mem.Allocator, albums: []const []const u8, wanted: ?[]const u8) ![]const u8 {
    if (albums.len == 0) return "";
    const target = wanted orelse return albums[0];
    if (target.len == 0) return albums[0];
    var best = albums[0];
    var best_similarity: f64 = -1;
    for (albums) |title| {
        const similarity = try scoring.textSimilarity(allocator, target, title);
        if (similarity > best_similarity) {
            best = title;
            best_similarity = similarity;
        }
    }
    return best;
}

fn writeSubmissionItem(writer: *std.Io.Writer, index: usize, item: SubmissionItem) !void {
    if (item.duration_s == 0 or item.fingerprint.len == 0) return error.InvalidSubmission;
    try writer.print("&duration.{d}={d}&fingerprint.{d}=", .{ index, item.duration_s, index });
    try url_encoding.writeEncoded(writer, item.fingerprint);
    if (item.file_format.len > 0) try writeField(writer, "fileformat", index, item.file_format);
    if (item.bitrate_kbps) |bitrate| try writer.print("&bitrate.{d}={d}", .{ index, bitrate });
    if (item.recording_mbid) |mbid| {
        if (!metadata.isMusicBrainzId(mbid)) return error.InvalidSubmission;
        return writeField(writer, "mbid", index, mbid);
    }
    if (item.track.len == 0 and item.artist.len == 0) return error.InvalidSubmission;
    try writeField(writer, "track", index, item.track);
    try writeField(writer, "artist", index, item.artist);
    try writeField(writer, "album", index, item.album);
    try writeField(writer, "albumartist", index, item.album_artist);
    if (item.track_number) |number| if (number > 0) try writer.print("&trackno.{d}={d}", .{ index, number });
    if (item.disc_number) |number| if (number > 0) try writer.print("&discno.{d}={d}", .{ index, number });
    if (item.year) |year| try writer.print("&year.{d}={d}", .{ index, year });
}

fn writeField(writer: *std.Io.Writer, name: []const u8, index: usize, value: []const u8) !void {
    if (value.len == 0) return;
    try writer.print("&{s}.{d}=", .{ name, index });
    try url_encoding.writeEncoded(writer, value);
}

fn parseSubmissions(allocator: std.mem.Allocator, body: []const u8, count: usize) ![]AcceptedSubmission {
    const Submission = struct {
        id: ?i64 = null,
        index: ?std.json.Value = null,
    };
    const Answer = struct {
        status: []const u8 = "",
        submissions: []const Submission = &.{},
    };
    const parsed = std.json.parseFromSlice(Answer, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderResponse,
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.status, "ok")) return error.InvalidProviderResponse;
    var accepted: std.ArrayList(AcceptedSubmission) = .empty;
    errdefer accepted.deinit(allocator);
    for (parsed.value.submissions) |submission| {
        const id = submission.id orelse continue;
        const index: usize = switch (submission.index orelse continue) {
            .integer => |value| std.math.cast(usize, value) orelse continue,
            .string => |text| std.fmt.parseUnsigned(usize, text, 10) catch continue,
            else => continue,
        };
        if (index >= count) continue;
        try accepted.append(allocator, .{ .index = index, .submission_id = id });
    }
    return accepted.toOwnedSlice(allocator);
}

pub fn gzip(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, @max(64, bytes.len / 2));
    errdefer output.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    const compressor = try allocator.create(std.compress.flate.Compress);
    defer allocator.destroy(compressor);
    compressor.* = try .init(&output.writer, window, .gzip, .default);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

const testing = std.testing;

test "a gzipped body decompresses to the form it was made from" {
    const form = comptime form: {
        const repeated = "&fingerprint.0=AQADtMmSJEm";
        var bytes: []const u8 = "client=key&format=json";
        for (0..200) |_| bytes = bytes ++ repeated;
        break :form bytes;
    };
    const compressed = try gzip(testing.allocator, form);
    defer testing.allocator.free(compressed);
    try testing.expect(compressed.len < form.len / 4);
    const restored = try network.testing.gunzip(testing.allocator, compressed);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(form, restored);
}

const first_recording = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
const second_recording = "9a2c1f6e-3b4d-4e5f-8a7b-6c5d4e3f2a1b";

const lookup_answer =
    \\{"status":"ok","fingerprints":[
    \\ {"index":0,"results":[
    \\  {"id":"t1","score":0.97,"recordings":[
    \\   {"id":"8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a","title":"Northern Sky","duration":224.4,
    \\    "artists":[{"id":"a1","name":"Nick Drake"}],
    \\    "releasegroups":[{"id":"g2","title":"Fruit Tree","type":"Compilation"},{"id":"g1","title":"Bryter Layter","type":"Album"}]},
    \\   {"id":"9a2c1f6e-3b4d-4e5f-8a7b-6c5d4e3f2a1b"},
    \\   {"title":"user metadata without an id"}]},
    \\  {"id":"t2","score":0.5,"recordings":[{"id":"8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"}]}]},
    \\ {"index":1,"results":[
    \\  {"id":"t3","score":0.9,"recordings":[
    \\   {"id":"8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a","artists":[{"id":"a1"},{"id":"a2","name":"John Cale"}],
    \\    "releasegroups":[{"id":"g1"}]}]}]}]}
;

const invalid_fingerprint = "{\"status\":\"error\",\"error\":{\"code\":3,\"message\":\"invalid fingerprint\"}}";

const Rig = struct {
    library: database.LibraryDatabase,
    net: network.testing.TestGateway,
    refused_fingerprint: ?[]const u8,
    adapter: AcoustId,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.net.init(.{ .config = .{ .identity = network.testing.test_identity, .minimum_interval_ms = 0 }, .now_ms = 1_800_000_000_000 });
        self.refused_fingerprint = null;
        self.respond(200, lookup_answer);
        self.net.transport.responder = .{ .context = self, .respond_fn = refuseFingerprint };
        self.adapter = .{
            .gateway = &self.net.gateway,
            .cache = &self.library.provider_cache,
            .wall_clock = self.net.clock.wallClock(),
            .server = "http://127.0.0.1:5001/",
            .client_key = "app key",
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }

    fn respond(self: *Rig, status: u16, body: []const u8) void {
        self.net.transport.otherwise = .{ .respond = .{ .status = status, .body = body } };
    }

    fn refuseFingerprint(context: *anyopaque, exchange: network.testing.Exchange, scripted: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *Rig = @ptrCast(@alignCast(context));
        const reply = scripted orelse self.net.transport.otherwise;
        if (reply == .fail) return reply;
        if (self.refused_fingerprint) |refused| if (std.mem.indexOf(u8, exchange.form, refused) != null)
            return .{ .respond = .{ .status = 400, .body = invalid_fingerprint } };
        return reply;
    }
};

test "a batched lookup asks once for every query, keys results by index and resolves compressed names" {
    var rig: Rig = undefined;
    try rig.init("file:orca-acoustid-batch?mode=memory&cache=shared");
    defer rig.deinit();
    const queries = [_]LookupQuery{
        .{ .duration_s = 224, .fingerprint = "AQAD first", .album = "Bryter Layter" },
        .{ .duration_s = 225, .fingerprint = "AQAD second" },
    };

    const answers = try rig.adapter.lookup(testing.allocator, &queries);
    defer answers.deinit();

    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
    try testing.expectEqualStrings("http://127.0.0.1:5001/v2/lookup", rig.net.transport.lastUrl());
    try testing.expectEqualStrings(
        "client=app%20key&clientversion=" ++ network.testing.test_identity.version ++
            "&format=json&meta=recordings+releasegroups+compress&batch=1" ++
            "&duration.0=224&fingerprint.0=AQAD%20first&duration.1=225&fingerprint.1=AQAD%20second",
        rig.net.transport.lastForm(),
    );
    const first = answers.answers[0].?;
    try testing.expectEqual(@as(usize, 2), first.items.len);
    try testing.expectEqualStrings(first_recording, first.items[0].provider_id);
    try testing.expectEqualStrings("acoustid", first.items[0].provider);
    try testing.expectEqualStrings("Northern Sky", first.items[0].title);
    try testing.expectEqualStrings("Nick Drake", first.items[0].artist);
    try testing.expectEqualStrings("Bryter Layter", first.items[0].album);
    try testing.expectEqual(@as(?u64, 224_400), first.items[0].duration_ms);
    try testing.expectApproxEqAbs(@as(f32, 0.97), first.items[0].fingerprint_similarity.?, 0.0001);
    try testing.expectEqualStrings(second_recording, first.items[1].provider_id);
    try testing.expectEqualStrings("", first.items[1].title);
    const second = answers.answers[1].?;
    try testing.expectEqual(@as(usize, 1), second.items.len);
    try testing.expectEqualStrings("Nick Drake; John Cale", second.items[0].artist);
    try testing.expectEqualStrings("Bryter Layter", second.items[0].album);
}

test "answers are cached per query, so asking again sends nothing and a new query is asked alone" {
    var rig: Rig = undefined;
    try rig.init("file:orca-acoustid-cache?mode=memory&cache=shared");
    defer rig.deinit();
    const first = try rig.adapter.lookup(testing.allocator, &.{
        .{ .duration_s = 224, .fingerprint = "AQAD first" },
        .{ .duration_s = 225, .fingerprint = "AQAD second" },
    });
    first.deinit();

    const again = try rig.adapter.lookup(testing.allocator, &.{
        .{ .duration_s = 225, .fingerprint = "AQAD second" },
        .{ .duration_s = 224, .fingerprint = "AQAD first" },
    });
    defer again.deinit();
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 2), rig.adapter.cache_hits);
    try testing.expectEqualStrings("Nick Drake; John Cale", again.answers[0].?.items[0].artist);

    rig.respond(200, "{\"status\":\"ok\",\"fingerprints\":[{\"index\":0,\"results\":[]}]}");
    const mixed = try rig.adapter.lookup(testing.allocator, &.{
        .{ .duration_s = 224, .fingerprint = "AQAD first" },
        .{ .duration_s = 300, .fingerprint = "AQAD third" },
    });
    defer mixed.deinit();
    try testing.expectEqual(@as(u32, 2), rig.net.transport.requestCount());
    try testing.expect(std.mem.endsWith(u8, rig.net.transport.lastForm(), "&duration.0=300&fingerprint.0=AQAD%20third"));
    try testing.expectEqual(@as(usize, 0), mixed.answers[1].?.items.len);
}

test "a refused key is told apart from a refused query and an outage, and only the refused query is cached" {
    var rig: Rig = undefined;
    try rig.init("file:orca-acoustid-refusals?mode=memory&cache=shared");
    defer rig.deinit();
    const query = [_]LookupQuery{.{ .duration_s = 224, .fingerprint = "AQAD first" }};

    rig.respond(400, "{\"status\":\"error\",\"error\":{\"code\":4,\"message\":\"invalid API key\"}}");
    try testing.expectError(error.InvalidClientKey, rig.adapter.lookup(testing.allocator, &query));
    rig.respond(401, "{\"status\":\"error\"}");
    try testing.expectError(error.ProviderRejectedRequest, rig.adapter.lookup(testing.allocator, &query));
    rig.respond(503, "{\"status\":\"error\"}");
    try testing.expectError(error.ProviderUnavailable, rig.adapter.lookup(testing.allocator, &query));
    rig.net.transport.otherwise = .{ .fail = error.ConnectionRefused };
    try testing.expectError(error.NetworkUnavailable, rig.adapter.lookup(testing.allocator, &query));
    try testing.expectEqual(@as(u32, 4), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 0), rig.adapter.cache_hits);

    rig.respond(400, invalid_fingerprint);
    try testing.expectError(error.ProviderRejectedRequest, rig.adapter.lookup(testing.allocator, &query));
    rig.respond(200, lookup_answer);
    const refused = try rig.adapter.lookup(testing.allocator, &query);
    defer refused.deinit();
    try testing.expect(refused.answers[0] == null);
    try testing.expectEqual(@as(u32, 5), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 1), rig.adapter.cache_hits);

    rig.net.clock.advance(rig.adapter.refusal_ttl_seconds * 1000);
    rig.respond(503, lookup_answer);
    try testing.expectError(error.ProviderUnavailable, rig.adapter.lookup(testing.allocator, &query));
    rig.respond(200, lookup_answer);
    const answered = try rig.adapter.lookup(testing.allocator, &query);
    defer answered.deinit();
    try testing.expect(answered.answers[0] != null);
    try testing.expectEqual(@as(u32, 7), rig.net.transport.requestCount());
}

test "a refused batch is asked again one fingerprint at a time, so only the bad fingerprint's refusal is cached" {
    var rig: Rig = undefined;
    try rig.init("file:orca-acoustid-refused-batch?mode=memory&cache=shared");
    defer rig.deinit();
    rig.refused_fingerprint = "AQADbad";
    const queries = [_]LookupQuery{
        .{ .duration_s = 224, .fingerprint = "AQADfirst" },
        .{ .duration_s = 225, .fingerprint = "AQADbad" },
        .{ .duration_s = 226, .fingerprint = "AQADthird" },
    };

    const first = try rig.adapter.lookup(testing.allocator, &queries);
    defer first.deinit();

    try testing.expectEqual(@as(u32, 4), rig.net.transport.requestCount());
    try testing.expect(first.answers[0] != null);
    try testing.expect(first.answers[1] == null);
    try testing.expect(first.answers[2] != null);
    var refusals = try rig.library.database.prepare("SELECT count(*) FROM provider_cache WHERE provider = 'acoustid' AND status = 400;");
    defer refusals.deinit();
    try testing.expect(try refusals.step() == .row);
    try testing.expectEqual(@as(i64, 1), refusals.columnInt64(0));

    const again = try rig.adapter.lookup(testing.allocator, &queries);
    defer again.deinit();

    try testing.expectEqual(@as(u32, 4), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 3), rig.adapter.cache_hits);
    try testing.expect(again.answers[0] != null);
    try testing.expect(again.answers[1] == null);
    try testing.expect(again.answers[2] != null);
}

test "a submission sends each item's fields under its index and returns what AcoustID took" {
    var rig: Rig = undefined;
    try rig.init("file:orca-acoustid-submit?mode=memory&cache=shared");
    defer rig.deinit();
    var batch: SubmissionBatch = .init(testing.allocator);
    defer batch.deinit();
    try testing.expect(try batch.tryAdd(testing.allocator, .{
        .duration_s = 224,
        .fingerprint = "AQAD one",
        .recording_mbid = first_recording,
        .file_format = "FLAC",
        .bitrate_kbps = 900,
    }));
    try testing.expect(try batch.tryAdd(testing.allocator, .{
        .duration_s = 300,
        .fingerprint = "AQAD two",
        .recording_mbid = null,
        .track = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .track_number = 7,
        .year = 1971,
    }));
    rig.respond(200, "{\"status\":\"ok\",\"submissions\":[{\"id\":501,\"status\":\"pending\",\"index\":\"0\"},{\"id\":502,\"status\":\"pending\",\"index\":\"1\"}]}");

    const outcome = try rig.adapter.submit(testing.allocator, "user key", &batch);
    defer testing.allocator.free(outcome.accepted);

    try testing.expectEqualStrings("http://127.0.0.1:5001/v2/submit", rig.net.transport.lastUrl());
    try testing.expectEqualStrings(
        "client=app%20key&clientversion=" ++ network.testing.test_identity.version ++ "&format=json&user=user%20key" ++
            "&duration.0=224&fingerprint.0=AQAD%20one&fileformat.0=FLAC&bitrate.0=900" ++
            "&mbid.0=8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a" ++
            "&duration.1=300&fingerprint.1=AQAD%20two&track.1=Northern%20Sky&artist.1=Nick%20Drake" ++
            "&album.1=Bryter%20Layter&trackno.1=7&year.1=1971",
        rig.net.transport.lastForm(),
    );
    try testing.expectEqual(@as(usize, 2), outcome.accepted.len);
    try testing.expectEqual(@as(i64, 502), outcome.accepted[1].submission_id);
    try testing.expectEqual(@as(usize, 1), outcome.accepted[1].index);

    rig.respond(400, "{\"status\":\"error\",\"error\":{\"code\":6,\"message\":\"invalid user API key\"}}");
    try testing.expectError(error.InvalidUserKey, rig.adapter.submit(testing.allocator, "user key", &batch));
    rig.respond(401, "{\"status\":\"error\",\"error\":{\"code\":6,\"message\":\"invalid user API key\"}}");
    try testing.expectError(error.InvalidUserKey, rig.adapter.submit(testing.allocator, "user key", &batch));
    rig.respond(400, "{\"status\":\"error\",\"error\":{\"code\":8,\"message\":\"invalid duration\"}}");
    const rejected = try rig.adapter.submit(testing.allocator, "user key", &batch);
    try testing.expectEqual(@as(u16, 400), rejected.rejected);
}

test "a batch stops at fifty items and before its body would pass the limit" {
    var batch: SubmissionBatch = .init(testing.allocator);
    defer batch.deinit();
    for (0..max_submission_items) |_| try testing.expect(try batch.tryAdd(testing.allocator, .{
        .duration_s = 1,
        .fingerprint = "AQAD",
        .recording_mbid = first_recording,
    }));
    try testing.expect(!try batch.tryAdd(testing.allocator, .{ .duration_s = 1, .fingerprint = "AQAD", .recording_mbid = first_recording }));

    batch.clear();
    const fingerprint = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(fingerprint);
    @memset(fingerprint, 'A');
    try testing.expect(try batch.tryAdd(testing.allocator, .{ .duration_s = 1, .fingerprint = fingerprint, .recording_mbid = first_recording }));
    try testing.expect(try batch.tryAdd(testing.allocator, .{ .duration_s = 1, .fingerprint = fingerprint, .recording_mbid = first_recording }));
    try testing.expect(!try batch.tryAdd(testing.allocator, .{ .duration_s = 1, .fingerprint = fingerprint, .recording_mbid = first_recording }));
    try testing.expectEqual(@as(usize, 2), batch.count);
    try testing.expect(submission_header_reserve + batch.body.written().len <= max_submission_body_bytes);
}
