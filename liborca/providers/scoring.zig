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
    try addTextEvidence(allocator, query.title, candidate.title, 0.2, &weighted_score, &total_weight);
    try addTextEvidence(allocator, query.artist, candidate.artist, 0.2, &weighted_score, &total_weight);
    try addTextEvidence(allocator, query.album, candidate.album, 0.1, &weighted_score, &total_weight);
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
    weighted_score: *f64,
    total_weight: *f64,
) !void {
    const text = expected orelse return;
    if (text.len == 0 or actual.len == 0) return;
    total_weight.* += weight;
    weighted_score.* += weight * try textSimilarity(allocator, text, actual);
}

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
