const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/model.zig");
const model = @import("model.zig");
const scoring = @import("scoring.zig");

pub const minimum_confidence: f32 = 0.5;

/// One search's candidates, scored against the Track and folded into one
/// piece of evidence per recording. Payload strings borrow from the candidate
/// lists, which must outlive it.
pub const Evidence = struct {
    allocator: std.mem.Allocator,
    items: []database.ProposalEvidence,

    pub fn deinit(self: Evidence) void {
        self.allocator.free(self.items);
    }
};

/// Scores what MusicBrainz and AcoustID each returned for one Track and keeps
/// the recordings whose combined confidence reaches `minimum_confidence`.
/// AcoustID's own score counts as the fingerprint evidence `scoring` weighs.
pub fn collect(
    allocator: std.mem.Allocator,
    query: model.Query,
    musicbrainz: []const model.Candidate,
    acoustid: []const model.Candidate,
) !Evidence {
    var items: std.ArrayList(database.ProposalEvidence) = .empty;
    errdefer items.deinit(allocator);
    for (musicbrainz) |candidate| {
        if (!metadata.isMusicBrainzId(candidate.provider_id)) continue;
        try items.append(allocator, .{
            .recording_mbid = candidate.provider_id,
            .found_by = .{ .musicbrainz = true },
            .payload = .{
                .title = candidate.title,
                .artist = candidate.artist,
                .album = candidate.album,
                .track_number = candidate.track_number,
                .release_mbid = candidate.release_mbid,
                .duration_ms = candidate.duration_ms,
                .mb_score = candidate.mb_score,
                .musicbrainz_confidence = try scoring.score(allocator, query, candidate),
            },
        });
    }
    for (acoustid) |candidate| {
        if (!metadata.isMusicBrainzId(candidate.provider_id)) continue;
        const confidence = try scoring.score(allocator, query, candidate);
        const existing = for (items.items) |*item| {
            if (std.mem.eql(u8, item.recording_mbid, candidate.provider_id)) break item;
        } else null;
        if (existing) |item| {
            item.found_by.acoustid = true;
            item.payload.acoustid_score = candidate.fingerprint_similarity;
            item.payload.acoustid_confidence = confidence;
            continue;
        }
        try items.append(allocator, .{
            .recording_mbid = candidate.provider_id,
            .found_by = .{ .acoustid = true },
            .payload = .{
                .title = candidate.title,
                .artist = candidate.artist,
                .album = candidate.album,
                .duration_ms = candidate.duration_ms,
                .acoustid_score = candidate.fingerprint_similarity,
                .acoustid_confidence = confidence,
            },
        });
    }
    var kept: usize = 0;
    for (items.items) |item| {
        if (item.payload.combinedConfidence() < minimum_confidence) continue;
        items.items[kept] = item;
        kept += 1;
    }
    items.shrinkRetainingCapacity(kept);
    return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

/// Stores a search's evidence for a file and marks it searched by the
/// providers that answered. Returns how many proposals are pending.
pub fn record(
    allocator: std.mem.Allocator,
    proposals: *database.IdentificationProposalRepository,
    file_id: i64,
    query: model.Query,
    answered: database.ProviderSet,
    musicbrainz: []const model.Candidate,
    acoustid: []const model.Candidate,
) !u32 {
    const evidence = try collect(allocator, query, musicbrainz, acoustid);
    defer evidence.deinit();
    return proposals.recordSearch(allocator, file_id, answered, evidence.items);
}

const testing = std.testing;
const exact_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
const distant_mbid = "9a2c1f6e-3b4d-4e5f-8a7b-6c5d4e3f2a1b";

fn exactAndDistant(allocator: std.mem.Allocator) !model.CandidateList {
    var exact = try model.Candidate.init(allocator, "musicbrainz", exact_mbid, "Northern Sky", "Nick Drake", "Bryter Layter");
    errdefer exact.deinit();
    exact.duration_ms = 224_000;
    exact.mb_score = 100;
    exact.release_mbid = try allocator.dupe(u8, "1c1a2b3c-4d5e-4f60-8a7b-9c8d7e6f5a4b");
    var distant = try model.Candidate.init(allocator, "musicbrainz", distant_mbid, "Something Else", "Other Artist", "Compilation");
    errdefer distant.deinit();
    distant.duration_ms = 90_000;
    const items = try allocator.alloc(model.Candidate, 2);
    items[0] = distant;
    items[1] = exact;
    return .{ .allocator = allocator, .items = items };
}

fn fingerprinted(allocator: std.mem.Allocator, mbid: []const u8, title: []const u8, score: f32) !model.CandidateList {
    var candidate = try model.Candidate.init(allocator, "acoustid", mbid, title, if (title.len == 0) "" else "Nick Drake", "");
    errdefer candidate.deinit();
    candidate.duration_ms = 224_000;
    candidate.fingerprint_similarity = score;
    const items = try allocator.alloc(model.Candidate, 1);
    items[0] = candidate;
    return .{ .allocator = allocator, .items = items };
}

fn openLibraryWithFile(uri: [:0]const u8) !struct { library: database.LibraryDatabase, file_id: i64 } {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
    errdefer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 100 });
    return .{ .library = library, .file_id = file_id };
}

const northern_sky: model.Query = .{
    .title = "Northern Sky",
    .artist = "Nick Drake",
    .album = "Bryter Layter",
    .duration_ms = 223_500,
};

test "only the candidates worth reviewing are stored, with what the provider said, and a dismissed one stays dismissed" {
    var opened = try openLibraryWithFile("file:orca-workflow-identify?mode=memory&cache=shared");
    defer opened.library.close();
    const found = try exactAndDistant(testing.allocator);
    defer found.deinit();

    const stored = try record(testing.allocator, &opened.library.identification_proposals, opened.file_id, northern_sky, .{ .musicbrainz = true }, found.items, &.{});

    try testing.expectEqual(@as(u32, 1), stored);
    const pending = try opened.library.identification_proposals.pending(testing.allocator, opened.file_id, 10);
    defer {
        for (pending) |proposal| proposal.deinit();
        testing.allocator.free(pending);
    }
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings(exact_mbid, pending[0].provider_id);
    try testing.expectEqualStrings("musicbrainz", pending[0].provider);
    const payload = try database.ProposalPayload.parse(testing.allocator, pending[0].payload);
    defer payload.deinit();
    try testing.expectEqualStrings("Bryter Layter", payload.value.album);
    try testing.expectEqualStrings("1c1a2b3c-4d5e-4f60-8a7b-9c8d7e6f5a4b", payload.value.release_mbid.?);
    try testing.expectEqual(@as(?u64, 224_000), payload.value.duration_ms);
    try testing.expectEqual(@as(?u8, 100), payload.value.mb_score);

    try opened.library.identification_proposals.dismiss(pending[0].id);
    const found_again = try fingerprinted(testing.allocator, exact_mbid, "Northern Sky", 0.98);
    defer found_again.deinit();
    const again = try record(testing.allocator, &opened.library.identification_proposals, opened.file_id, northern_sky, .{ .acoustid = true }, &.{}, found_again.items);
    try testing.expectEqual(@as(u32, 0), again);
    const after_dismissal = try opened.library.identification_proposals.pending(testing.allocator, opened.file_id, 10);
    defer testing.allocator.free(after_dismissal);
    try testing.expectEqual(@as(usize, 0), after_dismissal.len);
}

test "one recording found by both services is one proposal, more confident than either alone" {
    const text = try exactAndDistant(testing.allocator);
    defer text.deinit();
    const fingerprint = try fingerprinted(testing.allocator, exact_mbid, "Northern Sky", 0.9);
    defer fingerprint.deinit();

    const alone_musicbrainz = try collect(testing.allocator, northern_sky, text.items, &.{});
    defer alone_musicbrainz.deinit();
    const alone_acoustid = try collect(testing.allocator, northern_sky, &.{}, fingerprint.items);
    defer alone_acoustid.deinit();
    const both = try collect(testing.allocator, northern_sky, text.items, fingerprint.items);
    defer both.deinit();

    try testing.expectEqual(@as(usize, 1), both.items.len);
    const merged = both.items[0];
    try testing.expect(merged.found_by.musicbrainz and merged.found_by.acoustid);
    try testing.expectEqualStrings("Bryter Layter", merged.payload.album);
    try testing.expectEqual(@as(?f32, 0.9), merged.payload.acoustid_score);
    const combined = merged.payload.combinedConfidence();
    try testing.expect(combined > alone_musicbrainz.items[0].payload.combinedConfidence());
    try testing.expect(combined > alone_acoustid.items[0].payload.combinedConfidence());
}

test "a fingerprint match with no title still becomes a proposal for an untagged file" {
    const fingerprint = try fingerprinted(testing.allocator, exact_mbid, "", 0.95);
    defer fingerprint.deinit();

    const evidence = try collect(testing.allocator, .{ .duration_ms = 224_300 }, &.{}, fingerprint.items);
    defer evidence.deinit();

    try testing.expectEqual(@as(usize, 1), evidence.items.len);
    try testing.expectEqualStrings("", evidence.items[0].payload.title);
    try testing.expect(evidence.items[0].payload.combinedConfidence() >= minimum_confidence);
}

test "accepting a proposal keeps a user's locked recording id and still settles the proposal" {
    var opened = try openLibraryWithFile("file:orca-workflow-locked?mode=memory&cache=shared");
    defer opened.library.close();
    const library = &opened.library;
    const locked_mbid = "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091";
    try library.orca_metadata.upsert(.{
        .file_id = opened.file_id,
        .field = .musicbrainz_recording_id,
        .value = locked_mbid,
        .provenance = .user,
        .locked = true,
    });
    _ = try library.identification_proposals.put(.{
        .file_id = opened.file_id,
        .provider = "musicbrainz",
        .provider_id = exact_mbid,
        .confidence = 0.95,
        .payload =
        \\{"title":"Provider title","artist":"Provider artist","album":"Provider album","track_number":2}
        ,
    });
    const pending = try library.identification_proposals.pending(testing.allocator, opened.file_id, 10);
    defer {
        for (pending) |proposal| proposal.deinit();
        testing.allocator.free(pending);
    }

    const acceptance = try library.identification_proposals.acceptProposal(testing.allocator, pending[0].id);

    try testing.expectEqual(@as(u32, 0), acceptance.values_written);
    const kept = (try library.orca_metadata.get(testing.allocator, opened.file_id, .musicbrainz_recording_id)).?;
    defer kept.deinit(testing.allocator);
    try testing.expectEqualStrings(locked_mbid, kept.text);
    try testing.expectEqual(metadata.Provenance.user, kept.provenance);
    try testing.expect(kept.locked);
    try testing.expect(try library.orca_metadata.get(testing.allocator, opened.file_id, .title) == null);
    const remaining = try library.identification_proposals.pending(testing.allocator, opened.file_id, 10);
    defer testing.allocator.free(remaining);
    try testing.expectEqual(@as(usize, 0), remaining.len);
}
