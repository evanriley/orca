//! What a finished search says it left to review. Whether an album can be
//! reviewed, and in which Matches tab, is liborca's answer; this only words
//! it.

const std = @import("std");
const liborca = @import("liborca");
const strings = @import("strings.zig");

pub const Bucket = liborca.ReleaseMatchBucket;

pub const no_album_match = "No album match found";
pub const no_album_match_in_details = "No album match found · review the recording in Details";

/// What was searched: an album, one Track without a recording ID, or one
/// Track searched again whatever its recording ID.
pub const Scope = enum { album, track_search, track_reidentify };

const max_title_bytes = 96;

pub fn bucketName(bucket: Bucket) [:0]const u8 {
    return switch (bucket) {
        .confident => "Confident",
        .needs_review => "Needs Review",
        .unmatched => "Unmatched",
        .reviewed => "Reviewed",
    };
}

/// Whether the Matches page lists the album where it waits for a person.
pub fn reviewable(bucket: ?Bucket) bool {
    return switch (bucket orelse return false) {
        .confident, .needs_review => true,
        .unmatched, .reviewed => false,
    };
}

/// The toast for a search that matched something, given where the album it
/// concerned stands now: null when the search left it on no Release.
pub fn matchedText(buffer: []u8, scope: Scope, title: []const u8, bucket: ?Bucket) [:0]const u8 {
    const known = bucket orelse return unreviewable(scope);
    return switch (known) {
        .confident, .needs_review => strings.printZ(buffer, "{s} is ready to review in {s}", .{
            shortTitle(title),
            bucketName(known),
        }) catch "An album is ready to review",
        .reviewed => strings.printZ(buffer, "{s} is already reviewed", .{shortTitle(title)}) catch "The album is already reviewed",
        .unmatched => unreviewable(scope),
    };
}

fn unreviewable(scope: Scope) [:0]const u8 {
    return switch (scope) {
        .album, .track_reidentify => no_album_match,
        .track_search => no_album_match_in_details,
    };
}

/// The toast for a search of the whole library: the Tracks it matched and
/// the albums those matches left ready to review.
pub fn libraryText(buffer: []u8, matched: u64, albums: u64) [:0]const u8 {
    if (matched == 0) return "No new matches found";
    const tracks = if (matched == 1) "track" else "tracks";
    if (albums == 0) return strings.printZ(buffer, "Found matches for {f} {s} · " ++ no_album_match, .{
        strings.grouped(matched),
        tracks,
    }) catch "Found matches";
    return strings.printZ(buffer, "Found matches for {f} {s} · {f} {s} ready to review", .{
        strings.grouped(matched),
        tracks,
        strings.grouped(albums),
        if (albums == 1) "album" else "albums",
    }) catch "Found matches";
}

fn shortTitle(title: []const u8) []const u8 {
    if (title.len == 0) return "The album";
    if (title.len <= max_title_bytes) return title;
    var end: usize = max_title_bytes;
    while (end > 0 and title[end] & 0xc0 == 0x80) end -= 1;
    return title[0..end];
}

test "an album search that left the album in Needs Review names the album and the tab" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Big Grams is ready to review in Needs Review", matchedText(&buffer, .album, "Big Grams", .needs_review));
    try std.testing.expectEqualStrings("Big Grams is ready to review in Confident", matchedText(&buffer, .track_reidentify, "Big Grams", .confident));
    try std.testing.expect(reviewable(.needs_review) and reviewable(.confident));
}

test "an album search that formed no release candidate says no album match was found" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(no_album_match, matchedText(&buffer, .album, "Big Grams", .unmatched));
    try std.testing.expectEqualStrings(no_album_match, matchedText(&buffer, .album, "Big Grams", null));
    try std.testing.expectEqualStrings(no_album_match, matchedText(&buffer, .track_reidentify, "Big Grams", .unmatched));
    try std.testing.expect(!reviewable(.unmatched) and !reviewable(.reviewed) and !reviewable(null));
}

test "a track search that formed no release candidate points at the recording in Details" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(no_album_match_in_details, matchedText(&buffer, .track_search, "Big Grams", .unmatched));
    try std.testing.expectEqualStrings(no_album_match_in_details, matchedText(&buffer, .track_search, "Big Grams", null));
}

test "a search of an album whose review still holds says it is already reviewed" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Big Grams is already reviewed", matchedText(&buffer, .album, "Big Grams", .reviewed));
    try std.testing.expectEqualStrings("The album is ready to review in Needs Review", matchedText(&buffer, .album, "", .needs_review));
}

test "a long album title is cut at a character boundary so the toast still fits" {
    var buffer: [256]u8 = undefined;
    var title: [161]u8 = undefined;
    title[0] = 'a';
    var at: usize = 1;
    while (at < title.len) : (at += 2) @memcpy(title[at..][0..2], "é");
    const text = matchedText(&buffer, .album, &title, .needs_review);
    try std.testing.expect(std.mem.endsWith(u8, text, " is ready to review in Needs Review"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(text.len < buffer.len);
}

test "a library search names the albums ready to review, or that none are" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("No new matches found", libraryText(&buffer, 0, 0));
    try std.testing.expectEqualStrings("Found matches for 1 track · No album match found", libraryText(&buffer, 1, 0));
    try std.testing.expectEqualStrings("Found matches for 1,204 tracks · 3 albums ready to review", libraryText(&buffer, 1204, 3));
    try std.testing.expectEqualStrings("Found matches for 2 tracks · 1 album ready to review", libraryText(&buffer, 2, 1));
}
