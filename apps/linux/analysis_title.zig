//! The analysis banner's sentence: what Orca now measures that the analyzed
//! files lack.

const std = @import("std");
const liborca = @import("liborca");

pub fn text(buffer: *[256]u8, missing: liborca.MissingMeasurements) [:0]const u8 {
    const phrases = [_]struct { bool, []const u8, [:0]const u8 }{
        .{ missing.features, "measures tempo, key and energy", "Orca now measures tempo, key and energy. Analyze your music to use them in Radio and Daily Mixes." },
        .{ missing.loudness_and_checks, "measures loudness differently", "Orca now measures loudness differently. Analyze your music to update ReplayGain and the audio checks." },
        .{ missing.fingerprint, "fingerprints music differently", "Orca now fingerprints music differently. Analyze your music to keep finding duplicates." },
    };
    var count: usize = 0;
    for (phrases) |phrase| count += @intFromBool(phrase[0]);
    if (count == 1) for (phrases) |phrase| if (phrase[0]) return phrase[2];
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll("Orca now") catch unreachable;
    var written: usize = 0;
    for (phrases) |phrase| {
        if (!phrase[0]) continue;
        written += 1;
        const separator = if (written == 1) " " else if (written == count) " and " else ", ";
        writer.print("{s}{s}", .{ separator, phrase[1] }) catch unreachable;
    }
    writer.writeAll(". Analyze your music to use them.") catch unreachable;
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

test "the banner names each missing measurement in one sentence" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Orca now measures tempo, key and energy. Analyze your music to use them in Radio and Daily Mixes.",
        text(&buffer, .{ .features = true }),
    );
    try std.testing.expectEqualStrings(
        "Orca now fingerprints music differently. Analyze your music to keep finding duplicates.",
        text(&buffer, .{ .fingerprint = true }),
    );
    try std.testing.expectEqualStrings(
        "Orca now measures tempo, key and energy and fingerprints music differently. Analyze your music to use them.",
        text(&buffer, .{ .features = true, .fingerprint = true }),
    );
    try std.testing.expectEqualStrings(
        "Orca now measures tempo, key and energy, measures loudness differently and fingerprints music differently. Analyze your music to use them.",
        text(&buffer, .{ .features = true, .loudness_and_checks = true, .fingerprint = true }),
    );
}
