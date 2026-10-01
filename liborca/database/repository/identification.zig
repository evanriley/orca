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
const track_file_ids_sql = @import("tracks.zig").track_file_ids_sql;
const file_track_ids_sql = @import("tracks.zig").file_track_ids_sql;
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
    release_mbids: ?[]const []const u8 = null,
    /// What the release `release_mbid` names says, filled in by a release
    /// lookup. `track_number` and `disc_number` are then positions on it.
    track_title: ?[]const u8 = null,
    track_artist: ?[]const u8 = null,
    release_title: ?[]const u8 = null,
    release_artist: ?[]const u8 = null,
    release_artist_mbid: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    release_group_mbid: ?[]const u8 = null,
    release_track_mbid: ?[]const u8 = null,
    disc_number: ?u32 = null,

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

    pub fn isEnriched(self: ProposalPayload) bool {
        return self.release_mbid != null and self.release_track_mbid != null;
    }

    pub fn listsRelease(self: ProposalPayload, release_mbid: []const u8) bool {
        if (self.release_mbid) |named| if (std.mem.eql(u8, named, release_mbid)) return true;
        for (self.release_mbids orelse &.{}) |listed| if (std.mem.eql(u8, listed, release_mbid)) return true;
        return false;
    }

    /// Points the payload at `release_mbid` with what that release says
    /// about the recording's track. Strings are borrowed from `enrichment`.
    pub fn enrich(self: *ProposalPayload, release_mbid: []const u8, enrichment: ReleaseEnrichment) void {
        self.release_mbid = release_mbid;
        self.track_title = enrichment.track_title;
        self.track_artist = enrichment.track_artist;
        self.release_title = enrichment.release_title;
        self.release_artist = enrichment.release_artist;
        self.release_artist_mbid = enrichment.release_artist_mbid;
        self.release_date = enrichment.release_date;
        self.release_group_mbid = enrichment.release_group_mbid;
        self.release_track_mbid = enrichment.release_track_mbid;
        if (enrichment.track_number) |number| self.track_number = number;
        self.disc_number = enrichment.disc_number;
    }

    fn clearEnrichment(self: *ProposalPayload) void {
        self.track_title = null;
        self.track_artist = null;
        self.release_title = null;
        self.release_artist = null;
        self.release_artist_mbid = null;
        self.release_date = null;
        self.release_group_mbid = null;
        self.release_track_mbid = null;
        self.disc_number = null;
    }

    fn copyEnrichment(self: *ProposalPayload, from: ProposalPayload) void {
        self.track_title = from.track_title;
        self.track_artist = from.track_artist;
        self.release_title = from.release_title;
        self.release_artist = from.release_artist;
        self.release_artist_mbid = from.release_artist_mbid;
        self.release_date = from.release_date;
        self.release_group_mbid = from.release_group_mbid;
        self.release_track_mbid = from.release_track_mbid;
        self.disc_number = from.disc_number;
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

pub const ReleaseEnrichment = struct {
    track_title: ?[]const u8 = null,
    track_artist: ?[]const u8 = null,
    release_title: ?[]const u8 = null,
    release_artist: ?[]const u8 = null,
    /// Set only when the release's credit names exactly one artist.
    release_artist_mbid: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    release_group_mbid: ?[]const u8 = null,
    release_track_mbid: []const u8,
    track_number: ?u32 = null,
    disc_number: ?u32 = null,
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

const max_release_proposals = max_page * 16;

fn containsMbid(mbids: []const [36]u8, mbid: *const [36]u8) bool {
    for (mbids) |each| if (std.mem.eql(u8, &each, mbid)) return true;
    return false;
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
        const release_changed = !optionalTextEqual(merged.release_mbid, found.release_mbid);
        merged.title = found.title;
        merged.artist = found.artist;
        merged.album = found.album;
        merged.track_number = found.track_number;
        merged.release_mbid = found.release_mbid;
        merged.release_mbids = found.release_mbids;
        merged.duration_ms = found.duration_ms;
        merged.mb_score = found.mb_score;
        if (found.isEnriched()) {
            merged.copyEnrichment(found);
        } else if (release_changed) {
            merged.clearEnrichment();
        } else if (existing.isEnriched()) {
            merged.track_number = existing.track_number;
        }
    }
    if (evidence.found_by.musicbrainz) merged.musicbrainz_confidence = found.musicbrainz_confidence;
    if (evidence.found_by.acoustid) {
        merged.acoustid_score = found.acoustid_score;
        merged.acoustid_confidence = found.acoustid_confidence;
    }
    return merged;
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
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
    track_title: ?[]const u8,
    track_artist: ?[]const u8,
    release_title: ?[]const u8,
    release_artist: ?[]const u8,
    release_date: ?[]const u8,
    release_group_mbid: ?[]const u8,
    release_track_mbid: ?[]const u8,
    disc_number: ?u32,
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
    /// Every value stored, on any file, the Release's other files included.
    values_written: u32,
};

/// What bulk acceptance did. Caller-owned: release with `deinit`.
pub const ConfidentAcceptance = struct {
    allocator: std.mem.Allocator,
    accepted: u64,
    values_written: u64,
    /// The files accepted or given a value, each once.
    file_ids: []i64,

    pub fn deinit(self: ConfidentAcceptance) void {
        self.allocator.free(self.file_ids);
    }
};

pub const ReleaseProposal = struct {
    id: i64,
    file_id: i64,
    recording_mbid: []const u8,
    payload: []const u8,
    /// The track number the file's own tag states.
    tagged_track_number: ?u32,
};

pub const ReleaseProposalList = struct {
    arena: *std.heap.ArenaAllocator,
    /// The Release's tagged MusicBrainz release ID, or empty.
    tag: []const u8,
    items: []ReleaseProposal,

    pub fn deinit(self: ReleaseProposalList) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const various_artists_mbid = "89ad4ac3-39f7-470e-963a-56509c546377";

pub const max_value_bytes = 4096;

/// Stores unlocked `provider` values. A value equal to the stored one is
/// left as it is, so it keeps its `written_at` and is not counted.
const ProviderValueWriter = struct {
    db: sqlite.Database,
    statement: sqlite.Statement,
    allocator: std.mem.Allocator,
    written: ?*std.ArrayList(i64),
    values_written: u32 = 0,

    fn init(db: sqlite.Database, allocator: std.mem.Allocator, written: ?*std.ArrayList(i64)) !ProviderValueWriter {
        return .{
            .db = db,
            .statement = try db.prepare(
                \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
                \\VALUES (?1, ?2, ?3, ?4, 0, unixepoch())
                \\ON CONFLICT(file_id, field) DO UPDATE SET value=excluded.value,
                \\    provenance=excluded.provenance, updated_at=excluded.updated_at,
                \\    written_at=CASE WHEN orca_metadata_values.value=excluded.value
                \\        THEN orca_metadata_values.written_at END
                \\WHERE orca_metadata_values.locked=0
                \\  AND (orca_metadata_values.value IS NOT excluded.value
                \\       OR orca_metadata_values.provenance IS NOT excluded.provenance);
            ),
            .allocator = allocator,
            .written = written,
        };
    }

    fn deinit(self: *ProviderValueWriter) void {
        self.statement.deinit();
    }

    fn text(self: *ProviderValueWriter, file_id: i64, field: metadata.Field, value: ?[]const u8) !void {
        const clean = cleanValue(value orelse return) orelse return;
        if (isMusicBrainzIdField(field) and !metadata.isMusicBrainzId(clean)) return;
        try self.statement.bindInt64(1, file_id);
        try self.statement.bindInt64(2, @intFromEnum(field));
        try self.statement.bindText(3, clean);
        try self.statement.bindInt64(4, @intFromEnum(metadata.Provenance.provider));
        if (try self.statement.step() != .done) return error.SqlFailed;
        const changed = self.db.changes() != 0;
        try self.statement.reset();
        if (!changed) return;
        self.values_written += 1;
        if (self.written) |files| try appendUnique(files, self.allocator, file_id);
    }

    fn number(self: *ProviderValueWriter, file_id: i64, field: metadata.Field, value: ?u32) !void {
        var buffer: [16]u8 = undefined;
        const present = value orelse return;
        if (present == 0) return;
        try self.text(file_id, field, std.fmt.bufPrint(&buffer, "{d}", .{present}) catch unreachable);
    }
};

fn isMusicBrainzIdField(field: metadata.Field) bool {
    return switch (field) {
        .musicbrainz_recording_id,
        .musicbrainz_release_id,
        .musicbrainz_release_group_id,
        .musicbrainz_release_track_id,
        .musicbrainz_album_artist_id,
        => true,
        .title, .artist, .album, .track_number, .album_artist, .disc_number, .date, .compilation => false,
    };
}

fn cleanValue(value: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
    if (value.len <= max_value_bytes) return value;
    var end: usize = max_value_bytes;
    while (end > 0 and (value[end] & 0xC0) == 0x80) end -= 1;
    return value[0..end];
}

fn appendUnique(list: *std.ArrayList(i64), allocator: std.mem.Allocator, id: i64) !void {
    if (std.mem.indexOfScalar(i64, list.items, id) == null) try list.append(allocator, id);
}

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
    /// The track number the file's own tag states.
    tagged_track_number: ?u32 = null,

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
        return self.acceptProposalInto(allocator, proposal_id, null);
    }

    pub fn acceptProposalInto(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
        written: ?*std.ArrayList(i64),
    ) !ProposalAcceptance {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var touched: std.ArrayList(i64) = .empty;
        defer touched.deinit(allocator);
        const acceptance = try self.acceptLocked(allocator, proposal_id, .reviewed, written, &touched);
        try self.db.exec("COMMIT;");
        return acceptance;
    }

    /// Stores the recording ID on the proposal's file and the title and
    /// artist on every file of its Track, and adds the Track's Release to
    /// `touched`. A reviewed accept then applies the Release's consensus; a
    /// bulk one leaves that to its caller, once per Release. Nothing is
    /// written before the proposal has been read and its payload parsed, so
    /// a refusal leaves the open transaction as it found it.
    fn acceptLocked(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
        review: AcceptanceReview,
        written: ?*std.ArrayList(i64),
        touched: *std.ArrayList(i64),
    ) !ProposalAcceptance {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const acceptable = try self.readAcceptable(scratch, proposal_id);
        const file_id = acceptable.file_id;
        const payload = acceptable.payload;

        var writer = try ProviderValueWriter.init(self.db, allocator, written);
        defer writer.deinit();
        try writer.text(file_id, .musicbrainz_recording_id, acceptable.recording_mbid);
        const track_ids = try self.idsFor(scratch, file_track_ids_sql, file_id);
        const track_files = try self.filesOfTracks(scratch, track_ids, file_id);
        for (track_files) |track_file| {
            try writer.text(track_file, .title, payload.track_title orelse payload.title);
            try writer.text(track_file, .artist, payload.track_artist orelse payload.artist);
        }
        const first_touched = touched.items.len;
        try self.appendReleasesOf(allocator, track_ids, touched);

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
        if (written) |files| try appendUnique(files, allocator, file_id);

        var values_written = writer.values_written;
        if (review == .reviewed) {
            for (touched.items[first_touched..]) |release_id|
                values_written += try self.applyReleaseConsensusLocked(allocator, release_id, written);
        }
        return .{ .file_id = file_id, .values_written = values_written };
    }

    /// A pending proposal whose recording id and payload read back, owned
    /// by `allocator`.
    fn readAcceptable(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
    ) !struct { file_id: i64, recording_mbid: []u8, payload: ProposalPayload } {
        var select = try self.db.prepare(
            "SELECT file_id, provider_id, payload, state FROM identification_proposals WHERE id=?1;",
        );
        defer select.deinit();
        try select.bindInt64(1, proposal_id);
        if (try select.step() != .row) return error.UnknownIdentificationProposal;
        if (select.columnInt64(3) != @intFromEnum(ProposalState.pending)) return error.StaleIdentificationProposal;
        const recording_mbid = try allocator.dupe(u8, select.columnText(1));
        if (!metadata.isMusicBrainzId(recording_mbid)) return error.InvalidProposalPayload;
        const payload = try ProposalPayload.parse(allocator, select.columnBlob(2));
        return .{ .file_id = select.columnInt64(0), .recording_mbid = recording_mbid, .payload = payload.value };
    }

    fn idsFor(self: *const IdentificationProposalRepository, allocator: std.mem.Allocator, sql: [:0]const u8, id: i64) ![]i64 {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, id);
        try statement.bindInt64(2, max_page);
        var ids: std.ArrayList(i64) = .empty;
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.items;
    }

    fn filesOfTracks(self: *const IdentificationProposalRepository, allocator: std.mem.Allocator, track_ids: []const i64, file_id: i64) ![]i64 {
        var files: std.ArrayList(i64) = .empty;
        try files.append(allocator, file_id);
        for (track_ids) |track_id| {
            for (try self.idsFor(allocator, track_file_ids_sql, track_id)) |each| try appendUnique(&files, allocator, each);
        }
        return files.items;
    }

    fn appendReleasesOf(self: *const IdentificationProposalRepository, allocator: std.mem.Allocator, track_ids: []const i64, releases: *std.ArrayList(i64)) !void {
        var statement = try self.db.prepare("SELECT release_id FROM tracks WHERE id=?1 AND release_id IS NOT NULL;");
        defer statement.deinit();
        for (track_ids) |track_id| {
            try statement.bindInt64(1, track_id);
            if (try statement.step() == .row) try appendUnique(releases, allocator, statement.columnInt64(0));
            try statement.reset();
        }
    }

    /// When every Track of the Release has a play file naming the same
    /// MusicBrainz release, by an accepted proposal enriched for it or by
    /// its tag, stores what that release says on every file of each Track
    /// accepted for it. Returns how many values were stored.
    pub fn applyReleaseConsensus(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
        written: ?*std.ArrayList(i64),
    ) !u32 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const values_written = try self.applyReleaseConsensusLocked(allocator, release_id, written);
        try self.db.exec("COMMIT;");
        return values_written;
    }

    fn applyReleaseConsensusLocked(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
        written: ?*std.ArrayList(i64),
    ) !u32 {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const ReleaseTrack = struct { id: i64, play_file: i64, named: std.ArrayList([36]u8) = .empty };
        var release_tracks: std.ArrayList(ReleaseTrack) = .empty;
        {
            var statement = try self.db.prepare(
                "SELECT tracks.id, " ++ track_play_file ++ " FROM tracks WHERE tracks.release_id = ?1\n" ++
                    "ORDER BY tracks.id LIMIT ?2;",
            );
            defer statement.deinit();
            try statement.bindInt64(1, release_id);
            try statement.bindInt64(2, max_page + 1);
            while (try statement.step() == .row) {
                if (statement.columnIsNull(1)) return 0;
                try release_tracks.append(scratch, .{ .id = statement.columnInt64(0), .play_file = statement.columnInt64(1) });
            }
        }
        if (release_tracks.items.len == 0 or release_tracks.items.len > max_page) return 0;

        var tagged = try self.db.prepare("SELECT musicbrainz_release_id FROM observed_file_tags WHERE file_id=?1;");
        defer tagged.deinit();
        for (release_tracks.items) |*release_track| {
            try tagged.bindInt64(1, release_track.play_file);
            if (try tagged.step() == .row) {
                const tag = tagged.columnText(0);
                if (metadata.isMusicBrainzId(tag)) try release_track.named.append(scratch, tag[0..36].*);
            }
            try tagged.reset();
            const accepted = try self.acceptedEnriched(scratch, release_track.play_file);
            for (accepted) |payload| {
                const mbid = payload.release_mbid.?[0..36].*;
                if (!containsMbid(release_track.named.items, &mbid)) try release_track.named.append(scratch, mbid);
            }
        }
        const agreed = for (release_tracks.items[0].named.items) |candidate| {
            const everywhere = for (release_tracks.items[1..]) |release_track| {
                if (!containsMbid(release_track.named.items, &candidate)) break false;
            } else true;
            if (everywhere) break candidate;
        } else return 0;

        var writer = try ProviderValueWriter.init(self.db, allocator, written);
        defer writer.deinit();
        for (release_tracks.items) |release_track| {
            const accepted = try self.acceptedEnriched(scratch, release_track.play_file);
            const payload = for (accepted) |candidate| {
                if (std.mem.eql(u8, candidate.release_mbid.?, &agreed)) break candidate;
            } else continue;
            for (try self.filesOfTracks(scratch, &.{release_track.id}, release_track.play_file)) |file_id| {
                try writer.text(file_id, .album, payload.release_title);
                try writer.text(file_id, .album_artist, payload.release_artist);
                try writer.text(file_id, .date, payload.release_date);
                try writer.number(file_id, .disc_number, payload.disc_number);
                try writer.number(file_id, .track_number, payload.track_number);
                try writer.text(file_id, .musicbrainz_release_id, &agreed);
                try writer.text(file_id, .musicbrainz_release_group_id, payload.release_group_mbid);
                try writer.text(file_id, .musicbrainz_release_track_id, payload.release_track_mbid);
                try writer.text(file_id, .musicbrainz_album_artist_id, payload.release_artist_mbid);
                if (payload.release_artist_mbid) |artist_mbid| {
                    if (std.mem.eql(u8, artist_mbid, various_artists_mbid)) try writer.text(file_id, .compilation, "1");
                }
            }
        }
        return writer.values_written;
    }

    fn acceptedEnriched(self: *const IdentificationProposalRepository, allocator: std.mem.Allocator, file_id: i64) ![]ProposalPayload {
        var statement = try self.db.prepare(
            "SELECT payload FROM identification_proposals WHERE file_id=?1 AND state=?2 ORDER BY id DESC LIMIT ?3;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(ProposalState.accepted));
        try statement.bindInt64(3, max_page);
        var payloads: std.ArrayList(ProposalPayload) = .empty;
        while (try statement.step() == .row) {
            const parsed = ProposalPayload.parse(allocator, statement.columnBlob(0)) catch |err| switch (err) {
                error.InvalidProposalPayload => continue,
                error.OutOfMemory => return err,
            };
            const payload = parsed.value;
            if (!payload.isEnriched() or !metadata.isMusicBrainzId(payload.release_mbid.?)) continue;
            try payloads.append(allocator, payload);
        }
        return payloads.items;
    }

    pub fn updatePayload(self: *IdentificationProposalRepository, proposal_id: i64, payload: []const u8) !void {
        if (payload.len == 0) return error.InvalidIdentificationProposal;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var update = try self.db.prepare(
            "UPDATE identification_proposals SET payload=?2, updated_at=unixepoch() WHERE id=?1;",
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindBlob(2, payload);
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.UnknownIdentificationProposal;
    }

    /// The proposals that are not dismissed on the play files of a Release's
    /// Tracks, by file. Empty for a Release of more than `max_page` Tracks.
    pub fn releaseProposals(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
    ) !ReleaseProposalList {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        var list: ReleaseProposalList = .{ .arena = arena, .tag = "", .items = &.{} };
        errdefer list.deinit();
        const owned = arena.allocator();
        {
            var statement = try self.db.prepare("SELECT musicbrainz_release_id FROM releases WHERE id=?1;");
            defer statement.deinit();
            try statement.bindInt64(1, release_id);
            if (try statement.step() != .row) return error.UnknownRelease;
            list.tag = try owned.dupe(u8, statement.columnText(0));
        }
        {
            var statement = try self.db.prepare("SELECT count(*) FROM (SELECT 1 FROM tracks WHERE release_id=?1 LIMIT ?2);");
            defer statement.deinit();
            try statement.bindInt64(1, release_id);
            try statement.bindInt64(2, max_page + 1);
            if (try statement.step() != .row) return error.SqlFailed;
            if (statement.columnInt64(0) > max_page) return list;
        }
        var statement = try self.db.prepare(
            "SELECT proposal.id, proposal.file_id, proposal.provider_id, proposal.payload,\n" ++
                "       (SELECT track_number FROM observed_file_tags WHERE observed_file_tags.file_id = proposal.file_id)\n" ++
                "FROM identification_proposals AS proposal\n" ++
                "WHERE proposal.state != ?2 AND proposal.file_id IN\n" ++
                "    (SELECT " ++ track_play_file ++ " FROM tracks WHERE tracks.release_id = ?1)\n" ++
                "ORDER BY proposal.file_id, proposal.id LIMIT ?3;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, @intFromEnum(ProposalState.dismissed));
        try statement.bindInt64(3, max_release_proposals);
        var items: std.ArrayList(ReleaseProposal) = .empty;
        while (try statement.step() == .row) {
            try items.append(owned, .{
                .id = statement.columnInt64(0),
                .file_id = statement.columnInt64(1),
                .recording_mbid = try owned.dupe(u8, statement.columnText(2)),
                .payload = try owned.dupe(u8, statement.columnBlob(3)),
                .tagged_track_number = if (optionalInt64(statement, 4)) |number| std.math.cast(u32, number) else null,
            });
        }
        list.items = items.items;
        return list;
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
    ) !ConfidentAcceptance {
        return self.acceptConfidentWhere(allocator, minimum_confidence, null);
    }

    /// `acceptConfident` for the files of one Release's Tracks only.
    pub fn acceptConfidentInRelease(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
        release_id: i64,
    ) !ConfidentAcceptance {
        return self.acceptConfidentWhere(allocator, minimum_confidence, release_id);
    }

    fn acceptConfidentWhere(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
        release_id: ?i64,
    ) !ConfidentAcceptance {
        if (!validMinimumConfidence(minimum_confidence)) return error.InvalidMinimumConfidence;
        var accepted: u64 = 0;
        var values_written: u64 = 0;
        var files: std.ArrayList(i64) = .empty;
        errdefer files.deinit(allocator);
        var touched: std.ArrayList(i64) = .empty;
        defer touched.deinit(allocator);
        var cursor: i64 = 0;
        var batch: [max_page]i64 = undefined;
        while (true) {
            const selection = try self.confidentBatch(allocator, minimum_confidence, cursor, release_id, &batch);
            cursor = selection.last_file_id orelse break;
            if (selection.chosen.len == 0) continue;
            self.write_lane.acquire();
            defer self.write_lane.release();
            try self.db.exec("BEGIN IMMEDIATE;");
            errdefer self.db.exec("ROLLBACK;") catch {};
            touched.clearRetainingCapacity();
            for (selection.chosen) |proposal_id| {
                const acceptance = self.acceptLocked(allocator, proposal_id, .bulk, &files, &touched) catch |err| switch (err) {
                    error.InvalidProposalPayload, error.StaleIdentificationProposal => continue,
                    else => return err,
                };
                accepted += 1;
                values_written += acceptance.values_written;
            }
            for (touched.items) |touched_release|
                values_written += try self.applyReleaseConsensusLocked(allocator, touched_release, &files);
            try self.db.exec("COMMIT;");
        }
        return .{
            .allocator = allocator,
            .accepted = accepted,
            .values_written = values_written,
            .file_ids = try files.toOwnedSlice(allocator),
        };
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
                .tagged_track_number = if (optionalInt64(statement, 9)) |number| std.math.cast(u32, number) else null,
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
        .track_title = said.track_title,
        .track_artist = said.track_artist,
        .release_title = said.release_title,
        .release_artist = said.release_artist,
        .release_date = said.release_date,
        .release_group_mbid = said.release_group_mbid,
        .release_track_mbid = said.release_track_mbid,
        .disc_number = said.disc_number,
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
        "       " ++ needs_musicbrainz ++ ", " ++ needs_acoustid ++ ",\n" ++
        "       (SELECT track_number FROM observed_file_tags WHERE observed_file_tags.file_id = track.file_id)\n" ++
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

const release_a = "aaaaaaaa-1111-4000-8000-000000000000";
const release_b = "bbbbbbbb-1111-4000-8000-000000000000";

fn enrichedFor(release_mbid: []const u8) ProposalPayload {
    var payload: ProposalPayload = .{ .title = "Song", .release_mbid = release_mbid, .musicbrainz_confidence = 0.9 };
    payload.enrich(release_mbid, .{
        .release_title = "Album",
        .release_artist = "Artist",
        .release_date = "2019-01",
        .release_track_mbid = mbid_b,
        .track_number = 4,
        .disc_number = 2,
    });
    return payload;
}

test "a proposal found again on another release keeps none of the old release's values" {
    const found: ProposalPayload = .{ .title = "Song", .release_mbid = release_b, .track_number = 9, .musicbrainz_confidence = 0.9 };
    const merged = mergeProposalPayload(enrichedFor(release_a), .{ .musicbrainz = true }, 0.9, .{
        .recording_mbid = mbid_a,
        .found_by = .{ .musicbrainz = true },
        .payload = found,
    });

    try testing.expectEqualStrings(release_b, merged.release_mbid.?);
    try testing.expect(!merged.isEnriched());
    try testing.expectEqual(@as(?[]const u8, null), merged.release_title);
    try testing.expectEqual(@as(?[]const u8, null), merged.release_date);
    try testing.expectEqual(@as(?u32, null), merged.disc_number);
    try testing.expectEqual(@as(?u32, 9), merged.track_number);
}

test "a proposal found again on the same release keeps its release values, and new ones replace them" {
    const plain: ProposalPayload = .{ .title = "Song", .release_mbid = release_a, .track_number = 9, .musicbrainz_confidence = 0.9 };
    const kept = mergeProposalPayload(enrichedFor(release_a), .{ .musicbrainz = true }, 0.9, .{
        .recording_mbid = mbid_a,
        .found_by = .{ .musicbrainz = true },
        .payload = plain,
    });
    try testing.expect(kept.isEnriched());
    try testing.expectEqualStrings("Album", kept.release_title.?);
    try testing.expectEqual(@as(?u32, 4), kept.track_number);

    var renamed = enrichedFor(release_a);
    renamed.release_title = "Album (Deluxe)";
    const replaced = mergeProposalPayload(enrichedFor(release_a), .{ .musicbrainz = true }, 0.9, .{
        .recording_mbid = mbid_a,
        .found_by = .{ .musicbrainz = true },
        .payload = renamed,
    });
    try testing.expectEqualStrings("Album (Deluxe)", replaced.release_title.?);

    const fingerprint_only = mergeProposalPayload(enrichedFor(release_a), .{ .musicbrainz = true }, 0.9, .{
        .recording_mbid = mbid_a,
        .found_by = .{ .acoustid = true },
        .payload = .{ .acoustid_score = 0.95, .acoustid_confidence = 0.9 },
    });
    try testing.expectEqualStrings("Album", fingerprint_only.release_title.?);
}

test "a value is never stored blank and is cut at its cap on a character boundary" {
    try testing.expectEqual(@as(?[]const u8, null), cleanValue(""));
    try testing.expectEqual(@as(?[]const u8, null), cleanValue(" \t"));
    try testing.expectEqualStrings("Album", cleanValue("Album").?);
    var long: [max_value_bytes + 8]u8 = @splat('a');
    @memcpy(long[max_value_bytes - 1 ..][0..2], "é");
    const capped = cleanValue(&long).?;
    try testing.expectEqual(@as(usize, max_value_bytes - 1), capped.len);
    try testing.expect(std.unicode.utf8ValidateSlice(capped));
}
