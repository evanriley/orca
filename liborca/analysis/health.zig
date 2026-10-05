const std = @import("std");
const database = @import("../database/root.zig");

/// The one wording for each duplicate finding.
///
/// Shared with `library/duplicate_pass.zig`, which is what produces these
/// three kinds at library scale. Two spellings would drift, and `orca-cli health`
/// would describe the same finding two ways depending on which pass filed it.
pub const exact_duplicate_details = "content also appears at {s}";
pub const identical_audio_details = "audio also appears at {s}, in different bytes";
pub const likely_duplicate_details = "audio resembles {s} ({d:.1}% match)";

/// Room for the longest formatted details a rule here produces.
pub const DetailsBuffer = [96]u8;

pub fn missingMetadata(
    title: []const u8,
    artist: []const u8,
    album: []const u8,
) ?database.HealthIssueInput {
    if (!missing(title) and !missing(artist) and !missing(album)) return null;
    return .{
        .kind = .missing_metadata,
        .severity = .warning,
        .details = "title, artist, or album is missing",
    };
}

pub fn albumArtistAnomaly(album: []const u8, album_artist: ?[]const u8) ?database.HealthIssueInput {
    if (missing(album) or !missing(album_artist orelse "")) return null;
    return .{
        .kind = .album_artist_anomaly,
        .severity = .information,
        .details = "album artist is missing",
    };
}

pub fn clipping(
    buffer: *DetailsBuffer,
    clipped_runs: u64,
    clipped_samples: u64,
) ?database.HealthIssueInput {
    if (clipped_runs == 0) return null;
    return .{
        .kind = .clipping,
        .severity = .warning,
        .details = std.fmt.bufPrint(
            buffer,
            "{d} clipped {s} ({d} samples at full scale)",
            .{ clipped_runs, if (clipped_runs == 1) "run" else "runs", clipped_samples },
        ) catch unreachable,
    };
}

pub fn excessiveSilence(
    buffer: *DetailsBuffer,
    silent_frames: u64,
    frames: u64,
) ?database.HealthIssueInput {
    if (frames == 0 or silent_frames * 5 <= frames) return null;
    return .{
        .kind = .excessive_silence,
        .severity = .warning,
        .details = std.fmt.bufPrint(
            buffer,
            "{d:.1}% of frames are silent",
            .{100 * @as(f64, @floatFromInt(silent_frames)) / @as(f64, @floatFromInt(frames))},
        ) catch unreachable,
    };
}

pub fn missingAnalysis(integrated_lufs: ?f32) ?database.HealthIssueInput {
    if (integrated_lufs != null) return null;
    return .{
        .kind = .missing_analysis,
        .severity = .information,
        .details = "track is too short or silent for loudness analysis",
    };
}

fn missing(value: ?[]const u8) bool {
    return value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0;
}

test "any blank title, artist or album is missing metadata" {
    try std.testing.expect(missingMetadata("Track", "Orca", "Album") == null);
    try std.testing.expectEqual(
        database.HealthIssueKind.missing_metadata,
        missingMetadata(" \t", "Orca", "Album").?.kind,
    );
    try std.testing.expect(missingMetadata("Track", "", "Album") != null);
    try std.testing.expect(missingMetadata("Track", "Orca", "") != null);
}

test "an album without an album artist is an anomaly and a blank album is not" {
    try std.testing.expect(albumArtistAnomaly("Album", null) != null);
    try std.testing.expect(albumArtistAnomaly("Album", " ") != null);
    try std.testing.expect(albumArtistAnomaly("Album", "Orca") == null);
    try std.testing.expect(albumArtistAnomaly("", null) == null);
}

test "audio findings follow the clipping and silence thresholds" {
    var buffer: DetailsBuffer = undefined;
    try std.testing.expect(clipping(&buffer, 0, 0) == null);
    try std.testing.expectEqualStrings(
        "1 clipped run (3 samples at full scale)",
        clipping(&buffer, 1, 3).?.details,
    );
    try std.testing.expectEqualStrings(
        "2 clipped runs (7 samples at full scale)",
        clipping(&buffer, 2, 7).?.details,
    );
    try std.testing.expectEqualStrings(
        "18446744073709551615 clipped runs (18446744073709551615 samples at full scale)",
        clipping(&buffer, std.math.maxInt(u64), std.math.maxInt(u64)).?.details,
    );
    try std.testing.expect(excessiveSilence(&buffer, 200, 1000) == null);
    try std.testing.expect(excessiveSilence(&buffer, 0, 0) == null);
    try std.testing.expectEqualStrings(
        "30.0% of frames are silent",
        excessiveSilence(&buffer, 300, 1000).?.details,
    );
    try std.testing.expect(missingAnalysis(-14) == null);
    try std.testing.expectEqual(
        database.HealthIssueKind.missing_analysis,
        missingAnalysis(null).?.kind,
    );
}
