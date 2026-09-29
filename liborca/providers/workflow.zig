const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/model.zig");
const model = @import("model.zig");
const scoring = @import("scoring.zig");

pub const minimum_confidence: f32 = 0.5;

pub fn identify(
    allocator: std.mem.Allocator,
    proposals: *database.IdentificationProposalRepository,
    provider: model.Provider,
    file_id: i64,
    query: model.Query,
) !u32 {
    const candidates = try provider.search(allocator, query);
    defer candidates.deinit();
    const ranked = try scoring.rank(allocator, query, candidates.items);
    defer allocator.free(ranked);
    var stored: u32 = 0;
    for (ranked) |result| {
        if (result.score < minimum_confidence) break;
        const candidate = candidates.items[result.candidate_index];
        const payload = try (database.ProposalPayload{
            .title = candidate.title,
            .artist = candidate.artist,
            .album = candidate.album,
            .track_number = candidate.track_number,
            .release_mbid = candidate.release_mbid,
            .duration_ms = candidate.duration_ms,
            .mb_score = candidate.mb_score,
        }).encode(allocator);
        defer allocator.free(payload);
        const state = try proposals.put(.{
            .file_id = file_id,
            .provider = candidate.provider,
            .provider_id = candidate.provider_id,
            .confidence = result.score,
            .payload = payload,
        });
        if (state == .pending) stored += 1;
    }
    return stored;
}

const testing = std.testing;
const exact_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
const distant_mbid = "9a2c1f6e-3b4d-4e5f-8a7b-6c5d4e3f2a1b";

const FakeProvider = struct {
    fn provider(self: *FakeProvider) model.Provider {
        return .{ .id = "musicbrainz", .context = self, .search_fn = search };
    }

    fn search(_: *anyopaque, allocator: std.mem.Allocator, _: model.Query) anyerror!model.CandidateList {
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
};

fn openLibraryWithFile(uri: [:0]const u8) !struct { library: database.LibraryDatabase, file_id: i64 } {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
    errdefer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 100 });
    return .{ .library = library, .file_id = file_id };
}

test "identify stores only the candidates worth reviewing, with what the provider said, and a dismissed one stays dismissed" {
    var opened = try openLibraryWithFile("file:orca-workflow-identify?mode=memory&cache=shared");
    defer opened.library.close();
    var fake: FakeProvider = .{};

    const stored = try identify(testing.allocator, &opened.library.identification_proposals, fake.provider(), opened.file_id, .{
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 223_500,
    });

    try testing.expectEqual(@as(u32, 1), stored);
    const pending = try opened.library.identification_proposals.pending(testing.allocator, opened.file_id, 10);
    defer {
        for (pending) |proposal| proposal.deinit();
        testing.allocator.free(pending);
    }
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings(exact_mbid, pending[0].provider_id);
    const payload = try database.ProposalPayload.parse(testing.allocator, pending[0].payload);
    defer payload.deinit();
    try testing.expectEqualStrings("Bryter Layter", payload.value.album);
    try testing.expectEqualStrings("1c1a2b3c-4d5e-4f60-8a7b-9c8d7e6f5a4b", payload.value.release_mbid.?);
    try testing.expectEqual(@as(?u64, 224_000), payload.value.duration_ms);
    try testing.expectEqual(@as(?u8, 100), payload.value.mb_score);

    try opened.library.identification_proposals.dismiss(pending[0].id);
    const again = try identify(testing.allocator, &opened.library.identification_proposals, fake.provider(), opened.file_id, .{
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 223_500,
    });
    try testing.expectEqual(@as(u32, 0), again);
    const after_dismissal = try opened.library.identification_proposals.pending(testing.allocator, opened.file_id, 10);
    defer testing.allocator.free(after_dismissal);
    try testing.expectEqual(@as(usize, 0), after_dismissal.len);
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
