//! The folding that turns a display name into the key two spellings share.
//!
//! This lives beside the schema rather than beside the projection because
//! `artists.key` is a stored, uniquely indexed column: a migration that
//! backfills `tracks.artist_id` has to fold exactly the way the projection
//! folded when it wrote those keys, or a migrated database and a freshly
//! scanned one would disagree about who an artist is. `migrations.zig`
//! registers `orca_artist_key` and `orca_artist_sort_key` as SQLite functions
//! over these two entry points so the backfill runs the same code the
//! projection runs.
const std = @import("std");

pub const key_buffer_size = 512;

/// Fold a display name onto the key two spellings of one name share.
///
/// The specification asks for NFKC plus full case folding. This implements the
/// part of that which a music library actually exercises without shipping the
/// Unicode tables: whitespace is collapsed and trimmed, halfwidth/fullwidth
/// forms are folded to ASCII, and case is folded across ASCII, Latin-1, Latin
/// Extended-A, Greek and Cyrillic. Canonical composition is *not* performed, so
/// a precomposed `é` and a decomposed `e`+U+0301 remain distinct keys. That is
/// a deliberate, documented shortfall rather than an oversight — see the module
/// note in `docs/database.md` if it ever needs closing.
pub fn normalizeKey(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, text.len);
    try normalizeAppend(&out, allocator, text);
    return out.toOwnedSlice(allocator);
}

fn normalizeAppend(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    var pending_space = false;
    var wrote = false;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        if (index + length > text.len) break;
        const point = std.unicode.utf8Decode(text[index .. index + length]) catch {
            index += 1;
            continue;
        };
        index += length;
        if (isSpace(point)) {
            pending_space = wrote;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        var buffer: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(fold(point), &buffer) catch continue;
        try out.appendSlice(allocator, buffer[0..written]);
        wrote = true;
    }
}

/// Stack-only normalization for the hot comparison inside the sole-artist rule,
/// which runs once per file per group and must not allocate to answer.
/// Over-long names are truncated at the buffer, which can only ever merge two
/// artists sharing a 512-byte prefix.
pub fn normalizeInto(buffer: []u8, text: []const u8) []const u8 {
    var length: usize = 0;
    var pending_space = false;
    var index: usize = 0;
    while (index < text.len) {
        const sequence = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        if (index + sequence > text.len) break;
        const point = std.unicode.utf8Decode(text[index .. index + sequence]) catch {
            index += 1;
            continue;
        };
        index += sequence;
        if (isSpace(point)) {
            pending_space = length != 0;
            continue;
        }
        if (pending_space) {
            if (length == buffer.len) break;
            buffer[length] = ' ';
            length += 1;
            pending_space = false;
        }
        var encoded: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(fold(point), &encoded) catch continue;
        if (length + written > buffer.len) break;
        @memcpy(buffer[length..][0..written], encoded[0..written]);
        length += written;
    }
    return buffer[0..length];
}

fn isSpace(point: u21) bool {
    return switch (point) {
        ' ', '\t', '\r', '\n', 0x0b, 0x0c, 0x85, 0xa0, 0x1680, 0x3000 => true,
        0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f => true,
        else => false,
    };
}

fn fold(point: u21) u21 {
    return switch (point) {
        'A'...'Z' => point + 32,
        // Typographic punctuation folds onto its ASCII spelling. Tag writers
        // are inconsistent about this *within a single album*: ALBUMARTIST
        // tends to carry the typographic form a metadata service supplied
        // while ARTIST carries what somebody typed. Without this, `El‐P`
        // (U+2010 HYPHEN) and `El-P` (ASCII hyphen-minus) are two artists --
        // one holding every release and the other holding every track, so
        // browsing to either shows you half the artist. Six artists in a
        // 2,474-artist library were split exactly this way.
        0x2010...0x2015, 0x2212 => '-',
        0x2018...0x201b, 0x2032 => '\'',
        0x201c...0x201f, 0x2033 => '"',
        // Fullwidth forms fold onto their ASCII equivalents, then onto case.
        0xff21...0xff3a => point - 0xfee0 + 32,
        0xff01...0xff20, 0xff3b...0xff5e => point - 0xfee0,
        0xc0...0xd6, 0xd8...0xde => point + 32,
        0x100...0x137, 0x14a...0x177 => if (point % 2 == 0) point + 1 else point,
        0x139...0x148, 0x179...0x17e => if (point % 2 == 1) point + 1 else point,
        0x178 => 0xff,
        0x391...0x3a1, 0x3a3...0x3ab => point + 32,
        0x400...0x40f => point + 80,
        0x410...0x42f => point + 32,
        else => point,
    };
}

/// Leading articles the sort key moves out of the way, longest first.
///
/// English only, and deliberately so: this is the set a real library
/// exercises, and folding an article the user's language does not use would
/// file "La Roux" under R for an English speaker's shelf. Extending it is a
/// localization question, not a schema one.
const articles = [_][]const u8{ "the ", "an ", "a " };

/// The key an artist listing orders by.
///
/// It is a *sort key*, not a display name: `artists.name` stays the thing a
/// host shows, and this is folded the same way `normalizeKey` folds so that
/// ordering is deterministic under a plain BINARY collation and one index can
/// serve the whole listing. A leading English article is dropped rather than
/// appended, because dropping it is enough to file "The Beatles" under B and
/// appending it would make the stored value unsuitable for anything else.
///
/// An artist whose entire name is an article keeps it: "The" is a band.
pub fn sortKey(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const folded = try normalizeKey(allocator, text);
    for (articles) |article| {
        if (folded.len <= article.len) continue;
        if (!std.mem.startsWith(u8, folded, article)) continue;
        if (folded.len == article.len) continue;
        // The caller owns and frees the result, so hand back an allocation
        // rather than a window into one.
        const trimmed = try allocator.dupe(u8, folded[article.len..]);
        allocator.free(folded);
        return trimmed;
    }
    return folded;
}

const testing = std.testing;

test "typographic and typed punctuation fold onto one key" {
    // The real split this closes: the release carried U+2010, the tracks
    // carried ASCII, and they became two artists.
    const pairs = [_][2][]const u8{
        .{ "El\u{2010}P", "El-P" },
        .{ "The O\u{2019}Jays", "The O'Jays" },
        .{ "Gabriel Garz\u{f3}n\u{2010}Montano", "Gabriel Garz\u{f3}n-Montano" },
        .{ "\u{201c}Heavy\u{201d} Weather", "\"Heavy\" Weather" },
    };
    for (pairs) |pair| {
        const left = try normalizeKey(testing.allocator, pair[0]);
        defer testing.allocator.free(left);
        const right = try normalizeKey(testing.allocator, pair[1]);
        defer testing.allocator.free(right);
        try testing.expectEqualStrings(left, right);
    }
}

test "two spellings of one name fold onto one key" {
    const left = try normalizeKey(testing.allocator, "Sigur  Rós");
    defer testing.allocator.free(left);
    const right = try normalizeKey(testing.allocator, " sigur rÓs ");
    defer testing.allocator.free(right);
    try testing.expectEqualStrings(left, right);
}

test "a leading article does not decide where an artist files" {
    const key = try sortKey(testing.allocator, "The Beatles");
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("beatles", key);
}

test "an artist whose whole name is an article keeps it" {
    const key = try sortKey(testing.allocator, "The");
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("the", key);
}

test "the stack-only fold agrees with the allocating one" {
    var buffer: [key_buffer_size]u8 = undefined;
    const names = [_][]const u8{ "ＡＢ", "  Mr.   Bungle ", "Мумий" };
    for (names) |name| {
        const allocated = try normalizeKey(testing.allocator, name);
        defer testing.allocator.free(allocated);
        try testing.expectEqualStrings(allocated, normalizeInto(&buffer, name));
    }
}
