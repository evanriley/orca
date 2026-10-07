const std = @import("std");
const model = @import("model.zig");

pub fn rank(
    allocator: std.mem.Allocator,
    query: model.Query,
    candidates: []const model.Candidate,
) ![]model.ScoredCandidate {
    const scored = try allocator.alloc(model.ScoredCandidate, candidates.len);
    errdefer allocator.free(scored);
    for (candidates, scored, 0..) |candidate, *result, index| {
        const value = try score(allocator, query, candidate);
        result.* = .{
            .candidate_index = index,
            .score = value,
            .confidence = if (value >= 0.85) .high else if (value >= 0.6) .medium else .low,
        };
    }
    std.mem.sort(model.ScoredCandidate, scored, {}, struct {
        fn lessThan(_: void, first: model.ScoredCandidate, second: model.ScoredCandidate) bool {
            return first.score > second.score;
        }
    }.lessThan);
    return scored;
}

pub fn score(
    allocator: std.mem.Allocator,
    query: model.Query,
    candidate: model.Candidate,
) !f32 {
    var weighted_score: f64 = 0;
    var total_weight: f64 = 0;
    if (query.embedded_provider_id) |provider_id| {
        total_weight += 0.5;
        if (std.mem.eql(u8, provider_id, candidate.provider_id)) weighted_score += 0.5;
    }
    try addTextEvidence(allocator, query.title, candidate.title, 0.2, .counts_against, &weighted_score, &total_weight);
    try addTextEvidence(allocator, query.artist, candidate.artist, 0.2, .counts_against, &weighted_score, &total_weight);
    try addTextEvidence(allocator, query.album, candidate.album, 0.1, .ignored, &weighted_score, &total_weight);
    if (query.duration_ms) |duration| if (candidate.duration_ms) |candidate_duration| {
        total_weight += 0.2;
        const difference = if (duration > candidate_duration)
            duration - candidate_duration
        else
            candidate_duration - duration;
        weighted_score += 0.2 * @max(0, 1 - @as(f64, @floatFromInt(difference)) / 10_000);
    };
    if (candidate.fingerprint_similarity) |similarity| {
        total_weight += 0.3;
        weighted_score += 0.3 * std.math.clamp(similarity, 0, 1);
    }
    if (total_weight == 0) return 0;
    return @floatCast(weighted_score / total_weight);
}

fn addTextEvidence(
    allocator: std.mem.Allocator,
    expected: ?[]const u8,
    actual: []const u8,
    weight: f64,
    when_missing: MissingCandidateText,
    weighted_score: *f64,
    total_weight: *f64,
) !void {
    const text = expected orelse return;
    if (text.len == 0) return;
    if (actual.len == 0) {
        if (when_missing == .counts_against) total_weight.* += weight;
        return;
    }
    total_weight.* += weight;
    weighted_score.* += weight * try textSimilarity(allocator, text, actual);
}

const MissingCandidateText = enum { counts_against, ignored };

pub fn textSimilarity(allocator: std.mem.Allocator, first: []const u8, second: []const u8) !f64 {
    if (std.ascii.eqlIgnoreCase(first, second)) return 1;
    const longer = @max(first.len, second.len);
    if (longer == 0) return 1;
    var previous = try allocator.alloc(usize, second.len + 1);
    defer allocator.free(previous);
    var current = try allocator.alloc(usize, second.len + 1);
    defer allocator.free(current);
    for (previous, 0..) |*value, index| value.* = index;
    for (first, 0..) |first_byte, first_index| {
        current[0] = first_index + 1;
        for (second, 0..) |second_byte, second_index| {
            const substitution = previous[second_index] +
                @intFromBool(std.ascii.toLower(first_byte) != std.ascii.toLower(second_byte));
            current[second_index + 1] = @min(
                @min(current[second_index] + 1, previous[second_index + 1] + 1),
                substitution,
            );
        }
        const swap = previous;
        previous = current;
        current = swap;
    }
    return 1 - @as(f64, @floatFromInt(previous[second.len])) /
        @as(f64, @floatFromInt(longer));
}

test "candidate scoring combines tags duration fingerprints and embedded IDs" {
    const allocator = std.testing.allocator;
    var exact = try model.Candidate.init(
        allocator,
        "musicbrainz",
        "recording-1",
        "Northern Sky",
        "Nick Drake",
        "Bryter Layter",
    );
    defer exact.deinit();
    exact.duration_ms = 224_000;
    exact.fingerprint_similarity = 0.98;
    var alternative = try model.Candidate.init(
        allocator,
        "musicbrainz",
        "recording-2",
        "Northern Lights",
        "Other Artist",
        "Compilation",
    );
    defer alternative.deinit();
    alternative.duration_ms = 260_000;
    alternative.fingerprint_similarity = 0.2;
    const ranked = try rank(allocator, .{
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 223_500,
        .embedded_provider_id = "recording-1",
    }, &.{ exact, alternative });
    defer allocator.free(ranked);
    try std.testing.expectEqual(@as(usize, 0), ranked[0].candidate_index);
    try std.testing.expectEqual(model.Confidence.high, ranked[0].confidence);
    try std.testing.expect(ranked[0].score > ranked[1].score);
}

const tagged_northern_sky: model.Query = .{
    .title = "Northern Sky",
    .artist = "Nick Drake",
    .album = "Bryter Layter",
    .duration_ms = 224_000,
};

fn fingerprintCandidate(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    title: []const u8,
    artist: []const u8,
) !model.Candidate {
    var candidate = try model.Candidate.init(allocator, "acoustid", provider_id, title, artist, "");
    candidate.duration_ms = 224_000;
    candidate.fingerprint_similarity = 1;
    return candidate;
}

test "a candidate without a title scores below one whose title and artist match a tagged Track" {
    const allocator = std.testing.allocator;
    const untitled = try fingerprintCandidate(allocator, "recording-1", "", "Nick Drake");
    defer untitled.deinit();
    const matching = try fingerprintCandidate(allocator, "recording-2", "Northern Sky", "Nick Drake");
    defer matching.deinit();

    const untitled_score = try score(allocator, tagged_northern_sky, untitled);
    const matching_score = try score(allocator, tagged_northern_sky, matching);

    try std.testing.expect(untitled_score < matching_score);
    try std.testing.expectApproxEqAbs(@as(f32, 1), matching_score, 0.0001);
}

test "a candidate without an artist scores below one whose title and artist match a tagged Track" {
    const allocator = std.testing.allocator;
    const uncredited = try fingerprintCandidate(allocator, "recording-1", "Northern Sky", "");
    defer uncredited.deinit();
    const matching = try fingerprintCandidate(allocator, "recording-2", "Northern Sky", "Nick Drake");
    defer matching.deinit();

    try std.testing.expect(try score(allocator, tagged_northern_sky, uncredited) <
        try score(allocator, tagged_northern_sky, matching));
}

test "a candidate without a title is scored on length and fingerprint for an untagged Track" {
    const allocator = std.testing.allocator;
    const untitled = try fingerprintCandidate(allocator, "recording-1", "", "");
    defer untitled.deinit();

    try std.testing.expectApproxEqAbs(
        @as(f32, 1),
        try score(allocator, .{ .title = "", .duration_ms = 224_000 }, untitled),
        0.0001,
    );
}

test "a candidate without an album is not marked down for it" {
    const allocator = std.testing.allocator;
    const without_album = try fingerprintCandidate(allocator, "recording-1", "Northern Sky", "Nick Drake");
    defer without_album.deinit();

    try std.testing.expectApproxEqAbs(
        @as(f32, 1),
        try score(allocator, tagged_northern_sky, without_album),
        0.0001,
    );
}

test "candidates with equal scores keep the provider's order" {
    const allocator = std.testing.allocator;
    const first = try fingerprintCandidate(allocator, "recording-1", "Northern Sky", "Nick Drake");
    defer first.deinit();
    const second = try fingerprintCandidate(allocator, "recording-2", "Northern Sky", "Nick Drake");
    defer second.deinit();

    for ([_][2]model.Candidate{ .{ first, second }, .{ second, first } }) |candidates| {
        const ranked = try rank(allocator, tagged_northern_sky, &candidates);
        defer allocator.free(ranked);
        try std.testing.expectEqual(ranked[0].score, ranked[1].score);
        try std.testing.expectEqual(@as(usize, 0), ranked[0].candidate_index);
        try std.testing.expectEqual(@as(usize, 1), ranked[1].candidate_index);
    }
}

test "candidates with equal scores keep the provider's order among many" {
    const allocator = std.testing.allocator;
    const matching = try fingerprintCandidate(allocator, "recording-1", "Northern Sky", "Nick Drake");
    defer matching.deinit();
    const other = try fingerprintCandidate(allocator, "recording-2", "Hazey Jane", "Nick Drake");
    defer other.deinit();
    var candidates: [64]model.Candidate = undefined;
    for (&candidates, 0..) |*candidate, index| candidate.* = if (index % 3 == 0) matching else other;

    const ranked = try rank(allocator, tagged_northern_sky, &candidates);
    defer allocator.free(ranked);

    for (ranked[0 .. ranked.len - 1], ranked[1..]) |earlier, later| {
        if (earlier.score == later.score)
            try std.testing.expect(earlier.candidate_index < later.candidate_index)
        else
            try std.testing.expect(earlier.score > later.score);
    }
}
