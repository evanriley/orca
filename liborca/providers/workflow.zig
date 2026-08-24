const std = @import("std");
const database = @import("../database/root.zig");
const model = @import("model.zig");
const scoring = @import("scoring.zig");

const ProposalPayload = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: ?u32,
};

pub const Suggestions = struct {
    candidates: model.CandidateList,
    ranked: []model.ScoredCandidate,

    pub fn deinit(self: Suggestions) void {
        const allocator = self.candidates.allocator;
        self.candidates.deinit();
        allocator.free(self.ranked);
    }
};

pub fn identify(
    allocator: std.mem.Allocator,
    proposals: *database.IdentificationProposalRepository,
    provider: model.Provider,
    file_id: i64,
    query: model.Query,
) !Suggestions {
    const candidates = try provider.search(allocator, query);
    errdefer candidates.deinit();
    const ranked = try scoring.rank(allocator, query, candidates.items);
    errdefer allocator.free(ranked);
    for (ranked) |result| {
        const candidate = candidates.items[result.candidate_index];
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        try std.json.Stringify.value(ProposalPayload{
            .title = candidate.title,
            .artist = candidate.artist,
            .album = candidate.album,
            .track_number = candidate.track_number,
        }, .{}, &writer.writer);
        try proposals.put(.{
            .file_id = file_id,
            .provider = candidate.provider,
            .provider_id = candidate.provider_id,
            .confidence = result.score,
            .payload = writer.writer.buffered(),
        });
    }
    return .{ .candidates = candidates, .ranked = ranked };
}

pub fn accept(
    allocator: std.mem.Allocator,
    proposals: *database.IdentificationProposalRepository,
    proposal: database.IdentificationProposal,
    file_id: i64,
) !void {
    const parsed = std.json.parseFromSlice(ProposalPayload, allocator, proposal.payload, .{}) catch
        return error.InvalidProposalPayload;
    defer parsed.deinit();
    const payload = parsed.value;
    var values: [4]database.OrcaMetadataInput = undefined;
    var count: usize = 0;
    if (payload.title.len > 0) {
        values[count] = .{ .file_id = file_id, .field = .title, .value = payload.title, .provenance = .provider };
        count += 1;
    }
    if (payload.artist.len > 0) {
        values[count] = .{ .file_id = file_id, .field = .artist, .value = payload.artist, .provenance = .provider };
        count += 1;
    }
    if (payload.album.len > 0) {
        values[count] = .{ .file_id = file_id, .field = .album, .value = payload.album, .provenance = .provider };
        count += 1;
    }
    var track_number_buffer: [16]u8 = undefined;
    if (payload.track_number) |track_number| {
        values[count] = .{
            .file_id = file_id,
            .field = .track_number,
            .value = try std.fmt.bufPrint(&track_number_buffer, "{d}", .{track_number}),
            .provenance = .provider,
        };
        count += 1;
    }
    try proposals.accept(proposal.id, file_id, values[0..count]);
}

test "accepted proposals update Orca metadata but preserve user locks" {
    const allocator = std.testing.allocator;
    var library = try database.LibraryDatabase.open(
        allocator,
        std.testing.io,
        "file:orca-identification-workflow?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 100 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = "music/track.flac",
        .native_inode = 1,
        .size_bytes = 100,
        .modified_ns = 1,
    });
    try library.orca_metadata.upsert(.{
        .file_id = file_id,
        .field = .title,
        .value = "User title",
        .provenance = .user,
        .locked = true,
    });
    const payload =
        \\{"title":"Provider title","artist":"Provider artist","album":"Provider album","track_number":2}
    ;
    try library.identification_proposals.put(.{
        .file_id = file_id,
        .provider = "musicbrainz",
        .provider_id = "recording-1",
        .confidence = 0.95,
        .payload = payload,
    });
    const pending = try library.identification_proposals.pending(allocator, file_id, 10);
    defer {
        for (pending) |proposal| proposal.deinit();
        allocator.free(pending);
    }
    try accept(allocator, &library.identification_proposals, pending[0], file_id);
    const title = (try library.orca_metadata.get(allocator, file_id, .title)).?;
    defer title.deinit(allocator);
    try std.testing.expectEqualStrings("User title", title.text);
    try std.testing.expect(title.locked);
    const artist = (try library.orca_metadata.get(allocator, file_id, .artist)).?;
    defer artist.deinit(allocator);
    try std.testing.expectEqualStrings("Provider artist", artist.text);
    try std.testing.expectEqual(@import("../metadata/model.zig").Provenance.provider, artist.provenance);
    const remaining = try library.identification_proposals.pending(
        allocator,
        file_id,
        10,
    );
    defer allocator.free(remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}
