//! The words for what an Apply of the Release ID field would change, from
//! its `ReleaseIdentity` counts.

const std = @import("std");
const liborca = @import("liborca");

fn writeCount(writer: *std.Io.Writer, category: []const u8, count: u8) void {
    if (count == 1) {
        writer.print("{s} on 1 track", .{category}) catch {};
    } else if (count == 255) {
        writer.print("{s} on 255+ tracks", .{category}) catch {};
    } else {
        writer.print("{s} on {d} tracks", .{ category, count }) catch {};
    }
}

fn separate(writer: *std.Io.Writer, started: *bool) void {
    if (started.*) writer.writeAll(", ") catch {};
    started.* = true;
}

/// What the Release ID field's `identity` differs in, joined with ", ", or
/// "" when every count is zero.
pub fn summary(buffer: []u8, identity: liborca.ReleaseIdentity) [:0]const u8 {
    std.debug.assert(buffer.len != 0);
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var started = false;
    if (identity.release != 0) {
        separate(&writer, &started);
        writeCount(&writer, "release IDs", identity.release);
    }
    if (identity.release_group != 0) {
        separate(&writer, &started);
        writer.writeAll("release group ID") catch {};
    }
    if (identity.album_artist != 0) {
        separate(&writer, &started);
        writer.writeAll("album artist ID") catch {};
    }
    if (identity.release_track != 0) {
        separate(&writer, &started);
        writeCount(&writer, "release-track IDs", identity.release_track);
    }
    if (identity.recording != 0) {
        separate(&writer, &started);
        writeCount(&writer, "recording IDs", identity.recording);
    }
    if (identity.numbers != 0) {
        separate(&writer, &started);
        writeCount(&writer, "disc or track numbers", identity.numbers);
    }
    var end = writer.end;
    while (end != 0 and !std.unicode.utf8ValidateSlice(buffer[0..end])) end -= 1;
    buffer[end] = 0;
    return buffer[0..end :0];
}

const testing = std.testing;

fn expectSummary(expected: []const u8, identity: liborca.ReleaseIdentity) !void {
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(expected, summary(&buffer, identity));
}

test "summary_allZero_isEmpty" {
    try expectSummary("", .{});
}

test "summary_listsCategoriesInFixedOrder" {
    try expectSummary("release IDs on 2 tracks, release group ID, album artist ID, release-track IDs on 3 tracks, recording IDs on 4 tracks, disc or track numbers on 1 track", .{
        .release = 2,
        .release_group = 1,
        .album_artist = 1,
        .release_track = 3,
        .recording = 4,
        .numbers = 1,
    });
}

test "summary_singularAndSaturatedCounts" {
    try expectSummary("recording IDs on 1 track", .{ .recording = 1 });
    try expectSummary("recording IDs on 255+ tracks", .{ .recording = 255 });
    try expectSummary("release IDs on 3 tracks", .{ .release = 3 });
}

test "summary_albumLevelValuesOmitCounts" {
    try expectSummary("release group ID, album artist ID", .{ .release_group = 4, .album_artist = 4 });
}
