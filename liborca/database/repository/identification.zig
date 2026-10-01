const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");

const duplicateNullableColumn = columns.duplicateNullableColumn;
const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const effectiveRecordingMbid = @import("tracks.zig").effectiveRecordingMbid;
const orderTerms = @import("tracks.zig").orderTerms;
const track_play_file = @import("tracks.zig").track_play_file;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const ProposalState = enum(u8) { pending, accepted, dismissed };

pub const IdentificationProposalInput = struct {
    file_id: i64,
    provider: []const u8,
    provider_id: []const u8,
    confidence: f32,
    payload: []const u8,
};

pub const IdentificationProposal = struct {
    allocator: std.mem.Allocator,
    id: i64,
    provider: []u8,
    provider_id: []u8,
    confidence: f32,
    payload: []u8,

    pub fn deinit(self: IdentificationProposal) void {
        self.allocator.free(self.provider);
        self.allocator.free(self.provider_id);
        self.allocator.free(self.payload);
    }
};

/// What a provider said about a candidate, stored as a proposal's JSON
/// payload. Every field has a default so older payloads still parse.
pub const ProposalPayload = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    track_number: ?u32 = null,
    release_mbid: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    mb_score: ?u8 = null,
    /// AcoustID's own score for the fingerprint match, 0 to 1.
    acoustid_score: ?f32 = null,
    /// Orca's confidence from each provider's evidence alone.
    musicbrainz_confidence: ?f32 = null,
    acoustid_confidence: ?f32 = null,

    pub fn parse(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) error{ InvalidProposalPayload, OutOfMemory }!std.json.Parsed(ProposalPayload) {
        return std.json.parseFromSlice(ProposalPayload, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidProposalPayload,
        };
    }

    pub fn encode(self: ProposalPayload, allocator: std.mem.Allocator) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(allocator);
        errdefer writer.deinit();
        try std.json.Stringify.value(self, .{ .emit_null_optional_fields = false }, &writer.writer);
        var list = writer.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// Independent evidence from each provider combined: the chance that
    /// neither is right, taken away from one. Two providers agreeing is more
    /// confident than either alone.
    pub fn combinedConfidence(self: ProposalPayload) f32 {
        var doubt: f32 = 1;
        inline for (.{ self.musicbrainz_confidence, self.acoustid_confidence }) |confidence| {
            if (confidence) |value| doubt *= 1 - std.math.clamp(value, 0, 1);
        }
        return 1 - doubt;
    }
};

pub const IdentificationProvider = enum {
    musicbrainz,
    acoustid,

    pub fn text(self: IdentificationProvider) []const u8 {
        return @tagName(self);
    }
};

/// The providers that found a proposal, stored in
/// `identification_proposals.provider` as `musicbrainz`, `acoustid` or
/// `musicbrainz+acoustid`.
pub const ProviderSet = struct {
    musicbrainz: bool = false,
    acoustid: bool = false,

    pub fn text(self: ProviderSet) []const u8 {
        if (self.musicbrainz and self.acoustid) return "musicbrainz+acoustid";
        if (self.musicbrainz) return "musicbrainz";
        if (self.acoustid) return "acoustid";
        return "";
    }

    pub fn parse(stored: []const u8) ProviderSet {
        var set: ProviderSet = .{};
        var names = std.mem.tokenizeScalar(u8, stored, '+');
        while (names.next()) |name| {
            if (std.mem.eql(u8, name, "musicbrainz")) set.musicbrainz = true;
            if (std.mem.eql(u8, name, "acoustid")) set.acoustid = true;
        }
        return set;
    }

    pub fn with(self: ProviderSet, other: ProviderSet) ProviderSet {
        return .{
            .musicbrainz = self.musicbrainz or other.musicbrainz,
            .acoustid = self.acoustid or other.acoustid,
        };
    }

    pub fn isEmpty(self: ProviderSet) bool {
        return !self.musicbrainz and !self.acoustid;
    }
};

/// The AcoustID fingerprint similarity at which a proposal counts as the
/// file's own audio.
const fingerprint_minimum: f32 = 0.9;

/// A confidence as the Matches page shows it, in whole percent.
fn confidencePercent(confidence: f32) u32 {
    return @intFromFloat(@floor(std.math.clamp(confidence, 0, 1) * 100));
}

fn validMinimumConfidence(minimum_confidence: f32) bool {
    return std.math.isFinite(minimum_confidence) and minimum_confidence > 0 and minimum_confidence <= 1;
}

/// A pending proposal whose recording id and payload read back.
const ConfidentCandidate = struct {
    id: i64,
    recording_mbid: []const u8,
    confidence: f32,
    found_by: ProviderSet,
    payload: ProposalPayload,

    fn fingerprintBacked(self: ConfidentCandidate) bool {
        const score = self.payload.acoustid_score orelse return false;
        return self.found_by.acoustid and score >= fingerprint_minimum;
    }
};

/// What the library knows of the song a file holds.
const SongFacts = struct {
    track_number: ?u32 = null,
    duration_ms: ?u64 = null,
};

/// The proposal bulk acceptance takes for one file, or null. When a proposal
/// at least `minimum_confidence` is backed by the file's fingerprint, the best
/// such one by `outranks`; otherwise the most confident proposal, only when it
/// reaches `minimum_confidence` and shows a higher percent than every other.
fn chooseConfident(candidates: []const ConfidentCandidate, song: SongFacts, minimum_confidence: f32) ?i64 {
    var fingerprinted: ?ConfidentCandidate = null;
    for (candidates) |candidate| {
        if (candidate.confidence < minimum_confidence or !candidate.fingerprintBacked()) continue;
        if (fingerprinted == null or outranks(candidate, fingerprinted.?, song)) fingerprinted = candidate;
    }
    if (fingerprinted) |winner| return winner.id;

    var best: ?ConfidentCandidate = null;
    var best_shared = false;
    for (candidates) |candidate| {
        const percent = confidencePercent(candidate.confidence);
        if (best) |current| {
            const current_percent = confidencePercent(current.confidence);
            if (percent < current_percent) continue;
            if (percent == current_percent) {
                best_shared = true;
                continue;
            }
        }
        best = candidate;
        best_shared = false;
    }
    const winner = best orelse return null;
    if (best_shared or winner.confidence < minimum_confidence) return null;
    return winner.id;
}

fn outranks(a: ConfidentCandidate, b: ConfidentCandidate, song: SongFacts) bool {
    const percent = std.math.order(confidencePercent(a.confidence), confidencePercent(b.confidence));
    if (percent != .eq) return percent == .gt;
    if (song.track_number) |number| {
        const a_position = a.payload.track_number == number;
        const b_position = b.payload.track_number == number;
        if (a_position != b_position) return a_position;
    }
    if (a.found_by.musicbrainz != b.found_by.musicbrainz) return a.found_by.musicbrainz;
    const a_score: i16 = a.payload.mb_score orelse -1;
    const b_score: i16 = b.payload.mb_score orelse -1;
    if (a_score != b_score) return a_score > b_score;
    if (song.duration_ms) |duration| {
        const a_distance = durationDistance(a.payload.duration_ms, duration);
        const b_distance = durationDistance(b.payload.duration_ms, duration);
        if (a_distance != b_distance) return a_distance < b_distance;
    }
    return std.mem.order(u8, a.recording_mbid, b.recording_mbid) == .lt;
}

fn durationDistance(proposed: ?u64, song_duration_ms: u64) u64 {
    const duration = proposed orelse return std.math.maxInt(u64);
    return @max(duration, song_duration_ms) - @min(duration, song_duration_ms);
}

/// What one search found for one recording: which providers found it, and
/// what they said, with each finder's confidence filled in.
pub const ProposalEvidence = struct {
    recording_mbid: []const u8,
    found_by: ProviderSet,
    payload: ProposalPayload,
};

/// An existing proposal with new evidence folded in. MusicBrainz describes the
/// recording whenever it found it; AcoustID only when MusicBrainz has not.
/// A payload written before per-provider confidences existed lends its row's
/// confidence to the one provider it names.
pub fn mergeProposalPayload(
    existing: ProposalPayload,
    existing_providers: ProviderSet,
    existing_confidence: f32,
    evidence: ProposalEvidence,
) ProposalPayload {
    var merged = existing;
    if (merged.musicbrainz_confidence == null and existing_providers.musicbrainz and !existing_providers.acoustid)
        merged.musicbrainz_confidence = existing_confidence;
    if (merged.acoustid_confidence == null and existing_providers.acoustid and !existing_providers.musicbrainz)
        merged.acoustid_confidence = existing_confidence;
    const found = evidence.payload;
    if (evidence.found_by.musicbrainz or !existing_providers.musicbrainz) {
        merged.title = found.title;
        merged.artist = found.artist;
        merged.album = found.album;
        merged.track_number = found.track_number;
        merged.release_mbid = found.release_mbid;
        merged.duration_ms = found.duration_ms;
        merged.mb_score = found.mb_score;
    }
    if (evidence.found_by.musicbrainz) merged.musicbrainz_confidence = found.musicbrainz_confidence;
    if (evidence.found_by.acoustid) {
        merged.acoustid_score = found.acoustid_score;
        merged.acoustid_confidence = found.acoustid_confidence;
    }
    return merged;
}

pub const MatchProposal = struct {
    id: i64,
    provider: []const u8,
    recording_mbid: []const u8,
    confidence: f32,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: ?u32,
    release_mbid: ?[]const u8,
    duration_ms: ?u64,
    musicbrainz_score: ?u8,
    acoustid_score: ?f32,
};

pub const MatchProposalPage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []MatchProposal,

    pub fn deinit(self: MatchProposalPage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

const AcceptanceReview = enum { reviewed, bulk };

pub const ProposalAcceptance = struct {
    file_id: i64,
    values_written: u32,
};

pub const MatchCandidate = struct {
    track_id: i64,
    file_id: i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    duration_ms: ?i64,
    /// Where the file is, or null when no location of it is present.
    path: ?[]u8,
    needs_musicbrainz: bool,
    needs_acoustid: bool,

    fn deinit(self: MatchCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
        if (self.path) |value| allocator.free(value);
    }
};

pub const MatchCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []MatchCandidate,

    pub fn deinit(self: MatchCandidatePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// Which Tracks a matching pass considers.
pub const MatchScope = union(enum) {
    library,
    track: i64,
    /// The Tracks of one Release.
    release: i64,

    fn lowerBound(self: MatchScope, cursor: i64) i64 {
        return switch (self) {
            .library, .release => cursor,
            .track => |track_id| @max(cursor, track_id - 1),
        };
    }

    fn upperBound(self: MatchScope) i64 {
        return switch (self) {
            .library, .release => std.math.maxInt(i64),
            .track => |track_id| track_id,
        };
    }

    fn pageSql(self: MatchScope) [:0]const u8 {
        return if (self == .release) unidentified_release_page_sql else unidentified_page_sql;
    }

    fn countSql(self: MatchScope) [:0]const u8 {
        return if (self == .release) unidentified_release_count_sql else unidentified_count_sql;
    }

    fn bindRelease(self: MatchScope, statement: sqlite.Statement) !void {
        switch (self) {
            .release => |release_id| try statement.bindInt64(5, release_id),
            .library, .track => {},
        }
    }
};

/// A Track with pending proposals, as the review list shows it: the Track's
/// own tags beside its best proposal.
pub const MatchReviewItem = struct {
    track_id: i64,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_ms: ?i64,
    proposal_count: u32,
    best: MatchProposal,
};

pub const MatchReviewPage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []MatchReviewItem,

    pub fn deinit(self: MatchReviewPage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const IdentificationProposalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn put(self: *IdentificationProposalRepository, input: IdentificationProposalInput) !ProposalState {
        if (input.file_id == 0 or input.provider.len == 0 or input.provider_id.len == 0 or
            input.payload.len == 0 or !std.math.isFinite(input.confidence) or
            input.confidence < 0 or input.confidence > 1) return error.InvalidIdentificationProposal;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO identification_proposals(
            \\    file_id, provider, provider_id, confidence, payload, state, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 0, unixepoch())
            \\ON CONFLICT(file_id, provider, provider_id) DO UPDATE SET
            \\    confidence=excluded.confidence, payload=excluded.payload,
            \\    updated_at=excluded.updated_at
            \\RETURNING state;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindText(2, input.provider);
        try statement.bindText(3, input.provider_id);
        try statement.bindDouble(4, input.confidence);
        try statement.bindBlob(5, input.payload);
        if (try statement.step() != .row) return error.SqlFailed;
        const state = std.enums.fromInt(ProposalState, statement.columnInt64(0)) orelse
            return error.InvalidStoredProposalState;
        if (try statement.step() != .done) return error.SqlFailed;
        return state;
    }

    pub fn pending(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        limit: u32,
    ) ![]IdentificationProposal {
        var statement = try self.db.prepare(
            \\SELECT id, provider, provider_id, confidence, payload
            \\FROM identification_proposals WHERE file_id=?1 AND state=0
            \\ORDER BY confidence DESC, id LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, limit);
        var proposals: std.ArrayList(IdentificationProposal) = .empty;
        errdefer {
            for (proposals.items) |proposal| proposal.deinit();
            proposals.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const provider = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(provider);
            const provider_id = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(provider_id);
            const payload = try allocator.dupe(u8, statement.columnBlob(4));
            errdefer allocator.free(payload);
            try proposals.append(allocator, .{
                .allocator = allocator,
                .id = statement.columnInt64(0),
                .provider = provider,
                .provider_id = provider_id,
                .confidence = @floatCast(statement.columnDouble(3)),
                .payload = payload,
            });
        }
        return proposals.toOwnedSlice(allocator);
    }

    pub fn acceptProposal(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
    ) !ProposalAcceptance {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const acceptance = try self.acceptLocked(allocator, proposal_id, .reviewed);
        try self.db.exec("COMMIT;");
        return acceptance;
    }

    /// Nothing is written before the proposal has been read and its payload
    /// parsed, so a refusal leaves the open transaction as it found it.
    fn acceptLocked(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
        review: AcceptanceReview,
    ) !ProposalAcceptance {
        const acceptable = try self.readAcceptable(allocator, proposal_id);
        defer allocator.free(acceptable.recording_mbid);
        const file_id = acceptable.file_id;
        const recording_mbid = acceptable.recording_mbid;

        var store = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, 0, unixepoch())
            \\ON CONFLICT(file_id, field) DO UPDATE SET value=excluded.value,
            \\    provenance=excluded.provenance, updated_at=excluded.updated_at
            \\WHERE orca_metadata_values.locked=0;
        );
        defer store.deinit();
        try store.bindInt64(1, file_id);
        try store.bindInt64(2, @intFromEnum(metadata.Field.musicbrainz_recording_id));
        try store.bindText(3, recording_mbid);
        try store.bindInt64(4, @intFromEnum(metadata.Provenance.provider));
        if (try store.step() != .done) return error.SqlFailed;
        const values_written: u32 = @intCast(self.db.changes());

        var settle = try self.db.prepare(
            \\UPDATE identification_proposals
            \\SET state = CASE WHEN id=?1 THEN ?3 ELSE ?4 END,
            \\    accepted_in_bulk = CASE WHEN id=?1 THEN ?6 ELSE accepted_in_bulk END, updated_at=unixepoch()
            \\WHERE file_id=?2 AND state=?5;
        );
        defer settle.deinit();
        try settle.bindInt64(1, proposal_id);
        try settle.bindInt64(2, file_id);
        try settle.bindInt64(3, @intFromEnum(ProposalState.accepted));
        try settle.bindInt64(4, @intFromEnum(ProposalState.dismissed));
        try settle.bindInt64(5, @intFromEnum(ProposalState.pending));
        try settle.bindInt64(6, @intFromBool(review == .bulk));
        if (try settle.step() != .done) return error.SqlFailed;
        return .{ .file_id = file_id, .values_written = values_written };
    }

    /// A pending proposal whose recording id and payload read back. The caller
    /// frees `recording_mbid`.
    fn readAcceptable(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
    ) !struct { file_id: i64, recording_mbid: []u8 } {
        var select = try self.db.prepare(
            "SELECT file_id, provider_id, payload, state FROM identification_proposals WHERE id=?1;",
        );
        defer select.deinit();
        try select.bindInt64(1, proposal_id);
        if (try select.step() != .row) return error.UnknownIdentificationProposal;
        if (select.columnInt64(3) != @intFromEnum(ProposalState.pending)) return error.StaleIdentificationProposal;
        const recording_mbid = try allocator.dupe(u8, select.columnText(1));
        errdefer allocator.free(recording_mbid);
        if (!metadata.isMusicBrainzId(recording_mbid)) return error.InvalidProposalPayload;
        const payload = try ProposalPayload.parse(allocator, select.columnBlob(2));
        payload.deinit();
        return .{ .file_id = select.columnInt64(0), .recording_mbid = recording_mbid };
    }

    pub fn dismiss(self: *IdentificationProposalRepository, proposal_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var update = try self.db.prepare(
            "UPDATE identification_proposals SET state=?2, updated_at=unixepoch() WHERE id=?1 AND state=?3;",
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindInt64(2, @intFromEnum(ProposalState.dismissed));
        try update.bindInt64(3, @intFromEnum(ProposalState.pending));
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 1) return;
        var exists = try self.db.prepare("SELECT 1 FROM identification_proposals WHERE id=?1;");
        defer exists.deinit();
        try exists.bindInt64(1, proposal_id);
        return if (try exists.step() == .row) error.StaleIdentificationProposal else error.UnknownIdentificationProposal;
    }

    pub fn acceptConfident(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
    ) !u64 {
        return self.acceptConfidentWhere(allocator, minimum_confidence, null);
    }

    /// `acceptConfident` for the files of one Release's Tracks only.
    pub fn acceptConfidentInRelease(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
        release_id: i64,
    ) !u64 {
        return self.acceptConfidentWhere(allocator, minimum_confidence, release_id);
    }

    fn acceptConfidentWhere(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
        release_id: ?i64,
    ) !u64 {
        if (!validMinimumConfidence(minimum_confidence)) return error.InvalidMinimumConfidence;
        var accepted: u64 = 0;
        var cursor: i64 = 0;
        var batch: [max_page]i64 = undefined;
        while (true) {
            const selection = try self.confidentBatch(allocator, minimum_confidence, cursor, release_id, &batch);
            cursor = selection.last_file_id orelse return accepted;
            if (selection.chosen.len == 0) continue;
            self.write_lane.acquire();
            defer self.write_lane.release();
            try self.db.exec("BEGIN IMMEDIATE;");
            errdefer self.db.exec("ROLLBACK;") catch {};
            for (selection.chosen) |proposal_id| {
                _ = self.acceptLocked(allocator, proposal_id, .bulk) catch |err| switch (err) {
                    error.InvalidProposalPayload, error.StaleIdentificationProposal => continue,
                    else => return err,
                };
                accepted += 1;
            }
            try self.db.exec("COMMIT;");
        }
    }

    /// The next page of files after `cursor` with a pending proposal at least
    /// `minimum_confidence`, and the proposal `chooseConfident` picks for each
    /// file that has one.
    fn confidentBatch(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
        cursor: i64,
        release_id: ?i64,
        batch: *[max_page]i64,
    ) !struct { chosen: []i64, last_file_id: ?i64 } {
        var files: [max_page]i64 = undefined;
        var file_count: usize = 0;
        {
            var statement = try self.db.prepare(if (release_id == null) confident_files_sql else confident_release_files_sql);
            defer statement.deinit();
            if (release_id) |id| try statement.bindInt64(5, id);
            try statement.bindDouble(1, minimum_confidence);
            try statement.bindInt64(2, cursor);
            try statement.bindInt64(3, files.len);
            try statement.bindInt64(4, @intFromEnum(ProposalState.pending));
            while (try statement.step() == .row) : (file_count += 1) files[file_count] = statement.columnInt64(0);
        }
        var chosen_count: usize = 0;
        for (files[0..file_count]) |file_id| {
            if (try self.chooseConfidentForFile(allocator, file_id, minimum_confidence)) |proposal_id| {
                batch[chosen_count] = proposal_id;
                chosen_count += 1;
            }
        }
        return .{
            .chosen = batch[0..chosen_count],
            .last_file_id = if (file_count == 0) null else files[file_count - 1],
        };
    }

    fn chooseConfidentForFile(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        minimum_confidence: f32,
    ) !?i64 {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const owned = arena.allocator();
        const proposals = try self.pending(owned, file_id, max_page);
        var candidates: std.ArrayList(ConfidentCandidate) = .empty;
        for (proposals) |proposal| {
            if (!metadata.isMusicBrainzId(proposal.provider_id)) continue;
            const payload = ProposalPayload.parse(owned, proposal.payload) catch |err| switch (err) {
                error.InvalidProposalPayload => continue,
                error.OutOfMemory => return err,
            };
            try candidates.append(owned, .{
                .id = proposal.id,
                .recording_mbid = proposal.provider_id,
                .confidence = proposal.confidence,
                .found_by = ProviderSet.parse(proposal.provider),
                .payload = payload.value,
            });
        }
        return chooseConfident(candidates.items, try self.songFacts(file_id), minimum_confidence);
    }

    /// The track number and duration of the lowest-numbered Track that plays
    /// this file.
    fn songFacts(self: *IdentificationProposalRepository, file_id: i64) !SongFacts {
        var statement = try self.db.prepare(
            "SELECT track_number, duration_ms FROM tracks WHERE " ++ track_play_file ++ " = ?1\n" ++
                "ORDER BY tracks.id LIMIT 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return .{};
        return .{
            .track_number = if (optionalInt64(statement, 0)) |value| std.math.cast(u32, value) else null,
            .duration_ms = if (optionalInt64(statement, 1)) |value| std.math.cast(u64, value) else null,
        };
    }

    /// How many proposals `acceptConfident` would accept now: the same
    /// selection.
    pub fn confidentCount(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
    ) !u64 {
        if (!validMinimumConfidence(minimum_confidence)) return error.InvalidMinimumConfidence;
        var acceptable: u64 = 0;
        var cursor: i64 = 0;
        var batch: [max_page]i64 = undefined;
        while (true) {
            const selection = try self.confidentBatch(allocator, minimum_confidence, cursor, null, &batch);
            cursor = selection.last_file_id orelse return acceptable;
            acceptable += selection.chosen.len;
        }
    }

    pub fn pendingForTrack(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
        limit: u32,
    ) !MatchProposalPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT id, provider, provider_id, confidence, payload FROM identification_proposals\n" ++
                "WHERE file_id = (SELECT " ++ track_play_file ++ " FROM tracks WHERE tracks.id = ?1)\n" ++
                "  AND state = ?3\n" ++
                "ORDER BY confidence DESC, id LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, @intFromEnum(ProposalState.pending));

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: MatchProposalPage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(MatchProposal) = .empty;
        while (try statement.step() == .row) try items.append(owned, try readMatchProposal(owned, statement, 0));
        return .{ .arena = arena, .items = items.items };
    }

    /// Tracks whose play file has a pending proposal, by artist, album and
    /// position, each with its best proposal.
    pub fn reviewPage(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !MatchReviewPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(review_page_sql);
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        try statement.bindInt64(3, @intFromEnum(ProposalState.pending));

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: MatchReviewPage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(MatchReviewItem) = .empty;
        while (try statement.step() == .row) {
            try items.append(owned, .{
                .track_id = statement.columnInt64(0),
                .title = try owned.dupe(u8, statement.columnText(1)),
                .artist = try owned.dupe(u8, statement.columnText(2)),
                .album = try owned.dupe(u8, statement.columnText(3)),
                .duration_ms = optionalInt64(statement, 4),
                .proposal_count = @intCast(statement.columnInt64(5)),
                .best = try readMatchProposal(owned, statement, 6),
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    pub fn reviewCount(self: *const IdentificationProposalRepository) !u64 {
        var statement = try self.db.prepare(review_count_sql);
        defer statement.deinit();
        try statement.bindInt64(3, @intFromEnum(ProposalState.pending));
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Stores what one search of a file found and records the providers that
    /// answered it, in one transaction, so a file is never marked searched
    /// without its proposals. A proposal for a recording the file already has
    /// one for is updated in place and keeps its state, so a dismissed or
    /// accepted one stays so. Returns how many of the proposals are pending.
    pub fn recordSearch(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        answered: ProviderSet,
        evidence: []const ProposalEvidence,
    ) !u32 {
        for (evidence) |item| {
            if (!metadata.isMusicBrainzId(item.recording_mbid) or item.found_by.isEmpty())
                return error.InvalidIdentificationProposal;
        }
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var pending_count: u32 = 0;
        for (evidence) |*item| {
            if (try self.mergeLocked(allocator, file_id, item) == .pending) pending_count += 1;
        }
        inline for (.{ IdentificationProvider.musicbrainz, IdentificationProvider.acoustid }) |provider| {
            if (@field(answered, @tagName(provider))) try self.markSearchedLocked(file_id, provider);
        }
        try self.db.exec("COMMIT;");
        return pending_count;
    }

    fn mergeLocked(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        evidence: *const ProposalEvidence,
    ) !ProposalState {
        var select = try self.db.prepare(
            \\SELECT id, provider, confidence, payload, state FROM identification_proposals
            \\WHERE file_id=?1 AND provider_id=?2 ORDER BY id LIMIT 1;
        );
        defer select.deinit();
        try select.bindInt64(1, file_id);
        try select.bindText(2, evidence.recording_mbid);
        if (try select.step() != .row) {
            const payload = try evidence.payload.encode(allocator);
            defer allocator.free(payload);
            var insert = try self.db.prepare(
                \\INSERT INTO identification_proposals(
                \\    file_id, provider, provider_id, confidence, payload, state, updated_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, unixepoch());
            );
            defer insert.deinit();
            try insert.bindInt64(1, file_id);
            try insert.bindText(2, evidence.found_by.text());
            try insert.bindText(3, evidence.recording_mbid);
            try insert.bindDouble(4, evidence.payload.combinedConfidence());
            try insert.bindBlob(5, payload);
            try insert.bindInt64(6, @intFromEnum(ProposalState.pending));
            if (try insert.step() != .done) return error.SqlFailed;
            return .pending;
        }
        const proposal_id = select.columnInt64(0);
        const existing_providers = ProviderSet.parse(select.columnText(1));
        const existing_confidence: f32 = @floatCast(select.columnDouble(2));
        const state = std.enums.fromInt(ProposalState, select.columnInt64(4)) orelse
            return error.InvalidStoredProposalState;
        const parsed = ProposalPayload.parse(allocator, select.columnBlob(3)) catch |err| switch (err) {
            error.InvalidProposalPayload => null,
            error.OutOfMemory => return err,
        };
        defer if (parsed) |value| value.deinit();
        const merged = mergeProposalPayload(
            if (parsed) |value| value.value else .{},
            existing_providers,
            existing_confidence,
            evidence.*,
        );
        const payload = try merged.encode(allocator);
        defer allocator.free(payload);
        const providers = existing_providers.with(evidence.found_by);
        var update = try self.db.prepare(
            \\UPDATE identification_proposals
            \\SET provider=?2, confidence=?3, payload=?4, updated_at=unixepoch() WHERE id=?1;
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindText(2, providers.text());
        try update.bindDouble(3, merged.combinedConfidence());
        try update.bindBlob(4, payload);
        if (try update.step() != .done) return error.SqlFailed;
        return state;
    }

    fn markSearchedLocked(self: *IdentificationProposalRepository, file_id: i64, provider: IdentificationProvider) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO identification_searches(file_id, provider, searched_at)
            \\VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(file_id, provider) DO UPDATE SET searched_at=excluded.searched_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindText(2, provider.text());
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Tracks a matching job still has to search: those some provider in
    /// scope has not answered for. MusicBrainz is always in scope; AcoustID
    /// only when `acoustid` is set.
    pub fn unidentifiedPage(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        scope: MatchScope,
        acoustid: bool,
        cursor: i64,
        limit: u32,
    ) !MatchCandidatePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(scope.pageSql());
        defer statement.deinit();
        try statement.bindInt64(1, scope.lowerBound(cursor));
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, @intFromBool(acoustid));
        try statement.bindInt64(4, scope.upperBound());
        try scope.bindRelease(statement);
        var items: std.ArrayList(MatchCandidate) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const title = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(title);
            const artist = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(artist);
            const album = try allocator.dupe(u8, statement.columnText(4));
            errdefer allocator.free(album);
            const path = try duplicateNullableColumn(allocator, statement, 6);
            errdefer if (path) |value| allocator.free(value);
            try items.append(allocator, .{
                .track_id = statement.columnInt64(0),
                .file_id = statement.columnInt64(1),
                .title = title,
                .artist = artist,
                .album = album,
                .duration_ms = optionalInt64(statement, 5),
                .path = path,
                .needs_musicbrainz = statement.columnInt64(7) != 0,
                .needs_acoustid = statement.columnInt64(8) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    pub fn unidentifiedCount(
        self: *const IdentificationProposalRepository,
        scope: MatchScope,
        acoustid: bool,
        limit: ?u32,
    ) !u64 {
        var statement = try self.db.prepare(scope.countSql());
        defer statement.deinit();
        try statement.bindInt64(1, scope.lowerBound(0));
        try statement.bindInt64(2, if (limit) |bound| bound else -1);
        try statement.bindInt64(3, @intFromBool(acoustid));
        try statement.bindInt64(4, scope.upperBound());
        try scope.bindRelease(statement);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// Reads `id, provider, provider_id, confidence, payload` starting at `first`.
/// A payload that does not parse leaves the provider's fields empty.
fn readMatchProposal(owned: std.mem.Allocator, statement: sqlite.Statement, first: c_int) !MatchProposal {
    const payload = ProposalPayload.parse(owned, statement.columnBlob(first + 4)) catch |err| switch (err) {
        error.InvalidProposalPayload => null,
        error.OutOfMemory => return err,
    };
    const said: ProposalPayload = if (payload) |parsed| parsed.value else .{};
    return .{
        .id = statement.columnInt64(first),
        .provider = try owned.dupe(u8, statement.columnText(first + 1)),
        .recording_mbid = try owned.dupe(u8, statement.columnText(first + 2)),
        .confidence = @floatCast(statement.columnDouble(first + 3)),
        .title = said.title,
        .artist = said.artist,
        .album = said.album,
        .track_number = said.track_number,
        .release_mbid = said.release_mbid,
        .duration_ms = said.duration_ms,
        .musicbrainz_score = said.mb_score,
        .acoustid_score = said.acoustid_score,
    };
}

/// Files after id ?2 with a pending proposal (state ?4) at least ?1, by id,
/// and with `in_release` only the play files of Release ?5's Tracks.
fn confidentFilesSql(comptime in_release: bool) [:0]const u8 {
    return "SELECT DISTINCT file_id FROM identification_proposals\n" ++
        "WHERE state = ?4 AND confidence >= ?1 AND file_id > ?2\n" ++
        (if (in_release)
            "  AND file_id IN (SELECT " ++ track_play_file ++ " FROM tracks WHERE tracks.release_id = ?5)\n"
        else
            "") ++
        "ORDER BY file_id LIMIT ?3;";
}

const confident_files_sql = confidentFilesSql(false);
const confident_release_files_sql = confidentFilesSql(true);

/// The best pending proposal (state ?3) for the Track in scope as `tracks`, in
/// the order `pendingForTrack` lists them.
const best_pending_proposal =
    "(SELECT id FROM identification_proposals\n" ++
    "    WHERE file_id = " ++ track_play_file ++ " AND state = ?3\n" ++
    "    ORDER BY confidence DESC, id LIMIT 1)";

pub const review_page_sql =
    "SELECT tracks.id, tracks.title, tracks.artist, tracks.album, tracks.duration_ms,\n" ++
    "       (SELECT count(*) FROM identification_proposals AS pending\n" ++
    "        WHERE pending.file_id = best.file_id AND pending.state = ?3),\n" ++
    "       best.id, best.provider, best.provider_id, best.confidence, best.payload\n" ++
    "FROM tracks JOIN identification_proposals AS best ON best.id = " ++ best_pending_proposal ++ "\n" ++
    "ORDER BY " ++ orderTerms(.artist, .ascending) ++ "\nLIMIT ?1 OFFSET ?2;";

pub const review_count_sql =
    "SELECT count(*) FROM tracks WHERE " ++ best_pending_proposal ++ " IS NOT NULL;";

fn searched(comptime provider: IdentificationProvider) []const u8 {
    return "EXISTS (SELECT 1 FROM identification_searches\n" ++
        "    WHERE identification_searches.file_id = track.file_id\n" ++
        "      AND identification_searches.provider = '" ++ provider.text() ++ "')";
}

const needs_musicbrainz = "NOT " ++ searched(.musicbrainz);
/// ?3 is whether AcoustID is in scope.
const needs_acoustid = "(?3 AND NOT " ++ searched(.acoustid) ++ ")";

/// Tracks with ids in (?1, ?4], and with `in_release` of Release ?5 only,
/// whose play file has no recording id and has not been answered for by
/// MusicBrainz, or by AcoustID when ?3 is set. The matching job's page and
/// its count share it so they agree.
fn unidentifiedTracks(comptime in_release: bool) []const u8 {
    return "(SELECT tracks.id, " ++ track_play_file ++ " AS file_id,\n" ++
        "        tracks.title, tracks.artist, tracks.album, tracks.duration_ms\n" ++
        "    FROM tracks WHERE " ++ (if (in_release) "tracks.release_id = ?5 AND " else "") ++
        "tracks.id > ?1 AND tracks.id <= ?4) AS track\n" ++
        "WHERE track.file_id IS NOT NULL\n" ++
        "  AND " ++ effectiveRecordingMbid("track.file_id") ++ " IS NULL\n" ++
        "  AND (" ++ needs_musicbrainz ++ " OR " ++ needs_acoustid ++ ")";
}

fn unidentifiedPageSql(comptime in_release: bool) [:0]const u8 {
    return "SELECT track.id, track.file_id, track.title, track.artist, track.album, track.duration_ms,\n" ++
        "       (SELECT locations.uri FROM locations\n" ++
        "        WHERE locations.file_id = track.file_id AND locations.state = 'present'\n" ++
        "        ORDER BY locations.id LIMIT 1),\n" ++
        "       " ++ needs_musicbrainz ++ ", " ++ needs_acoustid ++ "\n" ++
        "FROM " ++ unidentifiedTracks(in_release) ++ "\nORDER BY track.id LIMIT ?2;";
}

fn unidentifiedCountSql(comptime in_release: bool) [:0]const u8 {
    return "SELECT count(*) FROM (SELECT 1 FROM " ++ unidentifiedTracks(in_release) ++ " LIMIT ?2);";
}

pub const unidentified_tracks = unidentifiedTracks(false);
pub const unidentified_page_sql = unidentifiedPageSql(false);
pub const unidentified_count_sql = unidentifiedCountSql(false);
pub const unidentified_release_page_sql = unidentifiedPageSql(true);
pub const unidentified_release_count_sql = unidentifiedCountSql(true);

const testing = std.testing;
const mbid_a = "aaaaaaaa-0000-4000-8000-000000000000";
const mbid_b = "bbbbbbbb-0000-4000-8000-000000000000";
const fingerprinted_by_both: ProviderSet = .{ .musicbrainz = true, .acoustid = true };

fn fingerprintedCandidate(id: i64, recording_mbid: []const u8, confidence: f32) ConfidentCandidate {
    return .{
        .id = id,
        .recording_mbid = recording_mbid,
        .confidence = confidence,
        .found_by = fingerprinted_by_both,
        .payload = .{ .acoustid_score = 0.95 },
    };
}

fn textCandidate(id: i64, recording_mbid: []const u8, confidence: f32) ConfidentCandidate {
    return .{
        .id = id,
        .recording_mbid = recording_mbid,
        .confidence = confidence,
        .found_by = .{ .musicbrainz = true },
        .payload = .{ .mb_score = 100 },
    };
}

test "a fingerprint-backed proposal is chosen over a more confident text-only rival" {
    const candidates = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.97), fingerprintedCandidate(2, mbid_b, 0.85) };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&candidates, .{}, 0.8));
}

test "fingerprint backing needs AcoustID among the finders and a fingerprint score of at least 0.9" {
    var weak = fingerprintedCandidate(2, mbid_b, 0.85);
    weak.payload.acoustid_score = 0.89;
    var unscored = fingerprintedCandidate(2, mbid_b, 0.85);
    unscored.payload.acoustid_score = null;
    var musicbrainz_only = fingerprintedCandidate(2, mbid_b, 0.85);
    musicbrainz_only.found_by = .{ .musicbrainz = true };
    for ([_]ConfidentCandidate{ weak, unscored, musicbrainz_only }) |rival| {
        const candidates = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.97), rival };
        try testing.expectEqual(@as(?i64, 1), chooseConfident(&candidates, .{}, 0.8));
    }
    var exact = fingerprintedCandidate(2, mbid_b, 0.85);
    exact.payload.acoustid_score = fingerprint_minimum;
    const candidates = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.97), exact };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&candidates, .{}, 0.8));
}

test "a fingerprint-backed proposal below the threshold leaves the choice to the confidence rule" {
    const candidates = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.97), fingerprintedCandidate(2, mbid_b, 0.7) };
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&candidates, .{}, 0.8));
}

test "without fingerprint backing the best proposal is taken only when its percent is above every other's" {
    const clear = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.95), textCandidate(2, mbid_b, 0.92) };
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&clear, .{}, 0.9));
    const tied = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.951), textCandidate(2, mbid_b, 0.959) };
    try testing.expectEqual(@as(?i64, null), chooseConfident(&tied, .{}, 0.9));
    const tied_below = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.95), textCandidate(2, mbid_b, 0.85), textCandidate(3, mbid_b, 0.85) };
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&tied_below, .{}, 0.9));
    const below_threshold = [_]ConfidentCandidate{textCandidate(1, mbid_a, 0.85)};
    try testing.expectEqual(@as(?i64, null), chooseConfident(&below_threshold, .{}, 0.9));
    try testing.expectEqual(@as(?i64, null), chooseConfident(&.{}, .{}, 0.9));
}

test "a choice without fingerprint backing holds as the threshold rises until the threshold passes it" {
    const candidates = [_]ConfidentCandidate{ textCandidate(1, mbid_a, 0.95), textCandidate(2, mbid_b, 0.92) };
    for ([_]f32{ 0.8, 0.92, 0.95 }) |minimum| try testing.expectEqual(@as(?i64, 1), chooseConfident(&candidates, .{}, minimum));
    try testing.expectEqual(@as(?i64, null), chooseConfident(&candidates, .{}, 0.96));
}

test "fingerprint-backed proposals are ranked by displayed percent first" {
    const candidates = [_]ConfidentCandidate{ fingerprintedCandidate(1, mbid_a, 0.91), fingerprintedCandidate(2, mbid_b, 0.92) };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&candidates, .{ .track_number = 3 }, 0.8));
}

test "fingerprint-backed proposals of equal percent prefer the song's own track number" {
    var on_track = fingerprintedCandidate(2, mbid_b, 0.912);
    on_track.payload.track_number = 3;
    var other_track = fingerprintedCandidate(1, mbid_a, 0.918);
    other_track.payload.track_number = 4;
    other_track.payload.mb_score = 100;
    const candidates = [_]ConfidentCandidate{ other_track, on_track };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&candidates, .{ .track_number = 3 }, 0.8));
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&candidates, .{}, 0.8));
}

test "fingerprint-backed proposals of equal percent and position prefer one MusicBrainz found too" {
    var acoustid_only = fingerprintedCandidate(1, mbid_a, 0.91);
    acoustid_only.found_by = .{ .acoustid = true };
    acoustid_only.payload.mb_score = 100;
    const candidates = [_]ConfidentCandidate{ acoustid_only, fingerprintedCandidate(2, mbid_b, 0.91) };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&candidates, .{}, 0.8));
}

test "fingerprint-backed proposals otherwise equal prefer the higher MusicBrainz score, an unknown one lowest" {
    var higher = fingerprintedCandidate(2, mbid_b, 0.91);
    higher.payload.mb_score = 90;
    var lower = fingerprintedCandidate(1, mbid_a, 0.91);
    lower.payload.mb_score = 0;
    lower.payload.duration_ms = 200_000;
    const scored = [_]ConfidentCandidate{ lower, higher };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&scored, .{ .duration_ms = 200_000 }, 0.8));
    var zero = fingerprintedCandidate(4, mbid_b, 0.91);
    zero.payload.mb_score = 0;
    const unscored = [_]ConfidentCandidate{ fingerprintedCandidate(3, mbid_a, 0.91), zero };
    try testing.expectEqual(@as(?i64, 4), chooseConfident(&unscored, .{}, 0.8));
}

test "fingerprint-backed proposals otherwise equal prefer the closer duration, an unknown one last" {
    var close = fingerprintedCandidate(2, mbid_b, 0.91);
    close.payload.duration_ms = 201_000;
    var far = fingerprintedCandidate(1, mbid_a, 0.91);
    far.payload.duration_ms = 195_000;
    const known = [_]ConfidentCandidate{ far, close };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&known, .{ .duration_ms = 200_000 }, 0.8));
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&known, .{}, 0.8));
    const unknown = [_]ConfidentCandidate{ fingerprintedCandidate(1, mbid_a, 0.91), close };
    try testing.expectEqual(@as(?i64, 2), chooseConfident(&unknown, .{ .duration_ms = 200_000 }, 0.8));
}

test "fingerprint-backed proposals equal in every other way go to the lowest recording ID, in any order" {
    const forward = [_]ConfidentCandidate{ fingerprintedCandidate(1, mbid_a, 0.91), fingerprintedCandidate(2, mbid_b, 0.91) };
    const backward = [_]ConfidentCandidate{ fingerprintedCandidate(2, mbid_b, 0.91), fingerprintedCandidate(1, mbid_a, 0.91) };
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&forward, .{}, 0.8));
    try testing.expectEqual(@as(?i64, 1), chooseConfident(&backward, .{}, 0.8));
}
