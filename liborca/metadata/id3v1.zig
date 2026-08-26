const std = @import("std");
const source = @import("../storage/source.zig");

pub const Tag = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    year: []const u8,
    comment: []const u8,
    track_number: ?u8,
    genre: u8,
};

pub fn read(readable: source.ReadableSource, buffer: *[128]u8) !?Tag {
    if (readable.size() < buffer.len) return null;
    if (try readable.readAt(readable.size() - buffer.len, buffer) != buffer.len) return null;
    return parse(buffer);
}

pub fn parse(bytes: *const [128]u8) ?Tag {
    if (!std.mem.eql(u8, bytes[0..3], "TAG")) return null;
    const is_v11 = bytes[125] == 0 and bytes[126] != 0;
    return .{
        .title = trim(bytes[3..33]),
        .artist = trim(bytes[33..63]),
        .album = trim(bytes[63..93]),
        .year = trim(bytes[93..97]),
        .comment = trim(if (is_v11) bytes[97..125] else bytes[97..127]),
        .track_number = if (is_v11) bytes[126] else null,
        .genre = bytes[127],
    };
}

/// Encode a conservative ID3v1/1.1 tag. The portable baseline deliberately
/// rejects non-ASCII and overlong values rather than silently truncating or
/// guessing a legacy code page.
pub fn encode(tag: Tag) ![128]u8 {
    var bytes: [128]u8 = @splat(0);
    @memcpy(bytes[0..3], "TAG");
    try writeField(bytes[3..33], tag.title);
    try writeField(bytes[33..63], tag.artist);
    try writeField(bytes[63..93], tag.album);
    try writeField(bytes[93..97], tag.year);
    if (tag.track_number) |track| {
        if (track == 0) return error.InvalidId3v1Track;
        try writeField(bytes[97..125], tag.comment);
        bytes[125] = 0;
        bytes[126] = track;
    } else {
        try writeField(bytes[97..127], tag.comment);
    }
    bytes[127] = tag.genre;
    return bytes;
}

fn writeField(destination: []u8, value: []const u8) !void {
    if (value.len > destination.len) return error.Id3v1FieldTooLong;
    for (value) |byte| if (byte >= 0x80) return error.Id3v1RequiresAscii;
    @memcpy(destination[0..value.len], value);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trimEnd(u8, value, " \x00");
}

test "parses ID3v1.1 without leaking format conventions into metadata" {
    var bytes: [128]u8 = @splat(0);
    @memcpy(bytes[0..3], "TAG");
    @memcpy(bytes[3..13], "Test title");
    @memcpy(bytes[33..44], "Test artist");
    @memcpy(bytes[63..73], "Test album");
    @memcpy(bytes[93..97], "2026");
    bytes[126] = 7;
    bytes[127] = 13;

    const tag = parse(&bytes).?;
    try std.testing.expectEqualStrings("Test title", tag.title);
    try std.testing.expectEqualStrings("Test artist", tag.artist);
    try std.testing.expectEqual(@as(?u8, 7), tag.track_number);
}

test "portable ID3v1 writer round-trips without silent truncation" {
    const bytes = try encode(.{
        .title = "Generated title",
        .artist = "Generated artist",
        .album = "Generated album",
        .year = "2026",
        .comment = "Orca fixture",
        .track_number = 3,
        .genre = 13,
    });
    const tag = parse(&bytes).?;
    try std.testing.expectEqualStrings("Generated title", tag.title);
    try std.testing.expectEqual(@as(?u8, 3), tag.track_number);
    try std.testing.expectError(error.Id3v1FieldTooLong, encode(.{
        .title = "This title is deliberately longer than thirty bytes",
        .artist = "",
        .album = "",
        .year = "",
        .comment = "",
        .track_number = null,
        .genre = 255,
    }));
}

/// Both legacy ID3 text encodings default to Latin-1, which is not UTF-8 and
/// must be widened before a canonical value can carry it.
pub fn latin1ToUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var wide: usize = 0;
    for (bytes) |byte| wide += @intFromBool(byte >= 0x80);
    const output = try allocator.alloc(u8, bytes.len + wide);
    var index: usize = 0;
    for (bytes) |byte| {
        if (byte < 0x80) {
            output[index] = byte;
            index += 1;
        } else {
            output[index] = 0xc0 | (byte >> 6);
            output[index + 1] = 0x80 | (byte & 0x3f);
            index += 2;
        }
    }
    return output;
}

test "Latin-1 text widens to UTF-8 instead of reaching the model as raw bytes" {
    const widened = try latin1ToUtf8(std.testing.allocator, "Caf\xe9");
    defer std.testing.allocator.free(widened);
    try std.testing.expectEqualStrings("Caf\u{e9}", widened);
}

/// The ID3v1 numeric genre table, including the Winamp extensions ID3v2 text
/// frames also reference. It lives with the format that defined it so callers
/// only ever see genre names.
const genre_names = [_][]const u8{
    "Blues",                  "Classic Rock",        "Country",          "Dance",
    "Disco",                  "Funk",                "Grunge",           "Hip-Hop",
    "Jazz",                   "Metal",               "New Age",          "Oldies",
    "Other",                  "Pop",                 "R&B",              "Rap",
    "Reggae",                 "Rock",                "Techno",           "Industrial",
    "Alternative",            "Ska",                 "Death Metal",      "Pranks",
    "Soundtrack",             "Euro-Techno",         "Ambient",          "Trip-Hop",
    "Vocal",                  "Jazz+Funk",           "Fusion",           "Trance",
    "Classical",              "Instrumental",        "Acid",             "House",
    "Game",                   "Sound Clip",          "Gospel",           "Noise",
    "Alternative Rock",       "Bass",                "Soul",             "Punk",
    "Space",                  "Meditative",          "Instrumental Pop", "Instrumental Rock",
    "Ethnic",                 "Gothic",              "Darkwave",         "Techno-Industrial",
    "Electronic",             "Pop-Folk",            "Eurodance",        "Dream",
    "Southern Rock",          "Comedy",              "Cult",             "Gangsta",
    "Top 40",                 "Christian Rap",       "Pop/Funk",         "Jungle",
    "Native US",              "Cabaret",             "New Wave",         "Psychedelic",
    "Rave",                   "Showtunes",           "Trailer",          "Lo-Fi",
    "Tribal",                 "Acid Punk",           "Acid Jazz",        "Polka",
    "Retro",                  "Musical",             "Rock & Roll",      "Hard Rock",
    "Folk",                   "Folk-Rock",           "National Folk",    "Swing",
    "Fast Fusion",            "Bebop",               "Latin",            "Revival",
    "Celtic",                 "Bluegrass",           "Avantgarde",       "Gothic Rock",
    "Progressive Rock",       "Psychedelic Rock",    "Symphonic Rock",   "Slow Rock",
    "Big Band",               "Chorus",              "Easy Listening",   "Acoustic",
    "Humour",                 "Speech",              "Chanson",          "Opera",
    "Chamber Music",          "Sonata",              "Symphony",         "Booty Bass",
    "Primus",                 "Porn Groove",         "Satire",           "Slow Jam",
    "Club",                   "Tango",               "Samba",            "Folklore",
    "Ballad",                 "Power Ballad",        "Rhythmic Soul",    "Freestyle",
    "Duet",                   "Punk Rock",           "Drum Solo",        "A Cappella",
    "Euro-House",             "Dance Hall",          "Goa",              "Drum & Bass",
    "Club-House",             "Hardcore",            "Terror",           "Indie",
    "BritPop",                "Negerpunk",           "Polsk Punk",       "Beat",
    "Christian Gangsta Rap",  "Heavy Metal",         "Black Metal",      "Crossover",
    "Contemporary Christian", "Christian Rock",      "Merengue",         "Salsa",
    "Thrash Metal",           "Anime",               "Jpop",             "Synthpop",
    "Abstract",               "Art Rock",            "Baroque",          "Bhangra",
    "Big Beat",               "Breakbeat",           "Chillout",         "Downtempo",
    "Dub",                    "EBM",                 "Eclectic",         "Electro",
    "Electroclash",           "Emo",                 "Experimental",     "Garage",
    "Global",                 "IDM",                 "Illbient",         "Industro-Goth",
    "Jam Band",               "Krautrock",           "Leftfield",        "Lounge",
    "Math Rock",              "New Romantic",        "Nu-Breakz",        "Post-Punk",
    "Post-Rock",              "Psytrance",           "Shoegaze",         "Space Rock",
    "Trop Rock",              "World Music",         "Neoclassical",     "Audiobook",
    "Audio Theatre",          "Neue Deutsche Welle", "Podcast",          "Indie Rock",
    "G-Funk",                 "Dubstep",             "Garage Rock",      "Psybient",
};

pub fn genreName(code: u8) ?[]const u8 {
    if (code >= genre_names.len) return null;
    return genre_names[code];
}

test "ID3v1 genre numbers resolve to names instead of leaking codes" {
    try std.testing.expectEqualStrings("Metal", genreName(9).?);
    try std.testing.expectEqualStrings("Psybient", genreName(191).?);
    try std.testing.expect(genreName(192) == null);
    try std.testing.expect(genreName(255) == null);
}
