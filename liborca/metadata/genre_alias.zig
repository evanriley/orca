//! The key two spellings of one genre share, and the name it is shown under.
//!
//! A genre's key is `text_key.normalizeKey` with the separators people
//! disagree about removed, so `Hip-Hop`, `hip hop` and `HipHop` are one key.
//! An Orca-authored alias table then maps the keys of common variant names
//! (`Hip-Hop/Rap`, `RnB`, `Alt Rock`) onto one canonical genre and gives the
//! common genres a canonical display name. Anything the table does not know
//! keeps the first spelling the library saw. `&` is not a separator: `R&B/Soul`
//! is its own genre, not R&B.
//!
//! One stated value can list several genres: `Indie Rock, Rock` and
//! `Rock; Pop` are two each, split on `,` and `;` before folding. `/` does not
//! split, so `Hip-Hop/Rap` stays one value for the alias table. A real genre
//! name that contains a comma (`Folk, World, & Country`) is matched whole
//! before splitting.
//!
//! `genres.key` is a stored, uniquely indexed column, so migration 33 splits
//! and folds through this same code (`orca_genre_part`, `orca_genre_key`,
//! `orca_genre_name`).
const std = @import("std");
const text_key = @import("../database/text_key.zig");

pub const Folded = struct {
    /// Empty when the value is blank or only separators.
    key: []const u8,
    name: []const u8,
};

/// Fold one genre value. `key` is allocated; `name` is a slice of `value` or
/// of the alias table.
pub fn fold(allocator: std.mem.Allocator, value: []const u8) !Folded {
    const trimmed = std.mem.trim(u8, value, whitespace);
    const compact = try searchKey(allocator, trimmed);
    if (compact.len == 0) return .{ .key = compact, .name = "" };
    const canonical = aliases.get(compact) orelse return .{ .key = compact, .name = trimmed };
    allocator.free(compact);
    return .{ .key = try searchKey(allocator, canonical), .name = canonical };
}

/// The genres one stated value lists, in order: its parts between `,` and
/// `;`, trimmed, without blank parts.
pub const Parts = struct {
    rest: []const u8,

    pub fn next(self: *Parts) ?[]const u8 {
        while (true) {
            self.rest = std.mem.trimStart(u8, self.rest, whitespace);
            if (self.rest.len == 0) return null;
            if (unsplitNameLength(self.rest)) |length| {
                defer self.rest = self.rest[length..];
                return self.rest[0..length];
            }
            const end = std.mem.indexOfAny(u8, self.rest, list_separators) orelse self.rest.len;
            const part = std.mem.trimEnd(u8, self.rest[0..end], whitespace);
            self.rest = self.rest[@min(end + 1, self.rest.len)..];
            if (part.len != 0) return part;
        }
    }
};

pub fn parts(value: []const u8) Parts {
    return .{ .rest = value };
}

/// The genres `values` state: each value split into its parts and folded,
/// blank parts dropped, and each genre kept once, where it first appears.
/// Free with `freeAll`; each `name` slices `values` or the alias table.
pub fn foldAll(allocator: std.mem.Allocator, values: []const []const u8) ![]Folded {
    var genres: std.ArrayList(Folded) = .empty;
    errdefer {
        for (genres.items) |genre| allocator.free(genre.key);
        genres.deinit(allocator);
    }
    for (values) |value| {
        var iterator = parts(value);
        while (iterator.next()) |part| {
            const genre = try fold(allocator, part);
            if (genre.key.len == 0 or containsKey(genres.items, genre.key)) {
                allocator.free(genre.key);
                continue;
            }
            genres.append(allocator, genre) catch |err| {
                allocator.free(genre.key);
                return err;
            };
        }
    }
    return genres.toOwnedSlice(allocator);
}

pub fn freeAll(allocator: std.mem.Allocator, genres: []const Folded) void {
    for (genres) |genre| allocator.free(genre.key);
    allocator.free(genres);
}

fn containsKey(genres: []const Folded, key: []const u8) bool {
    for (genres) |genre| {
        if (std.mem.eql(u8, genre.key, key)) return true;
    }
    return false;
}

const whitespace = " \t\r\n";
const list_separators = ",;";

const unsplit_names = [_][]const u8{
    "Folk, World, & Country",
};

fn unsplitNameLength(text: []const u8) ?usize {
    for (unsplit_names) |name| {
        if (!std.ascii.startsWithIgnoreCase(text, name)) continue;
        const after = std.mem.trimStart(u8, text[name.len..], whitespace);
        if (after.len == 0 or std.mem.indexOfScalar(u8, list_separators, after[0]) != null) return name.len;
    }
    return null;
}

/// The folding a genre filter's text needs to match `genres.key` by
/// substring: the key's folding without the alias table.
pub fn searchKey(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const normalized = try text_key.normalizeKey(allocator, text);
    const out: []u8 = @constCast(normalized);
    var length: usize = 0;
    for (out) |byte| {
        if (isSeparator(byte)) continue;
        out[length] = byte;
        length += 1;
    }
    return allocator.realloc(out, length);
}

fn isSeparator(byte: u8) bool {
    return switch (byte) {
        ' ', '-', '_', '.', '/', '\'' => true,
        else => false,
    };
}

const aliases: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "2step", "2-Step" },
    .{ "acidjazz", "Acid Jazz" },
    .{ "afrobeat", "Afrobeat" },
    .{ "altcountry", "Alternative Country" },
    .{ "alternativecountry", "Alternative Country" },
    .{ "althiphop", "Alternative Hip Hop" },
    .{ "alternativehiphop", "Alternative Hip Hop" },
    .{ "altrap", "Alternative Hip Hop" },
    .{ "altr&b", "Alternative R&B" },
    .{ "altrnb", "Alternative R&B" },
    .{ "alternativer&b", "Alternative R&B" },
    .{ "alternativernb", "Alternative R&B" },
    .{ "alternative", "Alternative Rock" },
    .{ "altrock", "Alternative Rock" },
    .{ "alternativerock", "Alternative Rock" },
    .{ "artpop", "Art Pop" },
    .{ "artrock", "Art Rock" },
    .{ "audiobook", "Audiobook" },
    .{ "audiobooks", "Audiobook" },
    .{ "avantgarde", "Avant-Garde" },
    .{ "bigband", "Big Band" },
    .{ "blackmetal", "Black Metal" },
    .{ "bluesrock", "Blues Rock" },
    .{ "bossanova", "Bossa Nova" },
    .{ "chillout", "Chillout" },
    .{ "childrens", "Children's Music" },
    .{ "childrensmusic", "Children's Music" },
    .{ "christmas", "Christmas" },
    .{ "christmasmusic", "Christmas" },
    .{ "xmas", "Christmas" },
    .{ "classicrock", "Classic Rock" },
    .{ "cloudrap", "Cloud Rap" },
    .{ "contemporaryr&b", "Contemporary R&B" },
    .{ "contemporaryrnb", "Contemporary R&B" },
    .{ "dancepop", "Dance-Pop" },
    .{ "deathmetal", "Death Metal" },
    .{ "deephouse", "Deep House" },
    .{ "doowop", "Doo-Wop" },
    .{ "dreampop", "Dream Pop" },
    .{ "drumandbass", "Drum and Bass" },
    .{ "drum&bass", "Drum and Bass" },
    .{ "drumnbass", "Drum and Bass" },
    .{ "dnb", "Drum and Bass" },
    .{ "d&b", "Drum and Bass" },
    .{ "easylistening", "Easy Listening" },
    .{ "eastcoasthiphop", "East Coast Hip Hop" },
    .{ "edm", "EDM" },
    .{ "electronicdancemusic", "EDM" },
    .{ "electropop", "Electropop" },
    .{ "folk,world,&country", "Folk, World, & Country" },
    .{ "folkrock", "Folk Rock" },
    .{ "garagerock", "Garage Rock" },
    .{ "hardrock", "Hard Rock" },
    .{ "hardcorepunk", "Hardcore Punk" },
    .{ "heavymetal", "Heavy Metal" },
    .{ "hiphop", "Hip Hop" },
    .{ "hiphoprap", "Hip Hop" },
    .{ "raphiphop", "Hip Hop" },
    .{ "rap&hiphop", "Hip Hop" },
    .{ "hiphop&rap", "Hip Hop" },
    .{ "indiefolk", "Indie Folk" },
    .{ "indiepop", "Indie Pop" },
    .{ "indierock", "Indie Rock" },
    .{ "jpop", "J-Pop" },
    .{ "jrock", "J-Rock" },
    .{ "jazzfusion", "Jazz Fusion" },
    .{ "kpop", "K-Pop" },
    .{ "lofi", "Lo-Fi" },
    .{ "mathrock", "Math Rock" },
    .{ "neosoul", "Neo Soul" },
    .{ "newage", "New Age" },
    .{ "newwave", "New Wave" },
    .{ "noiserock", "Noise Rock" },
    .{ "numetal", "Nu Metal" },
    .{ "poppunk", "Pop Punk" },
    .{ "poprap", "Pop Rap" },
    .{ "poprock", "Pop Rock" },
    .{ "posthardcore", "Post-Hardcore" },
    .{ "postpunk", "Post-Punk" },
    .{ "postpunkrevival", "Post-Punk Revival" },
    .{ "postrock", "Post-Rock" },
    .{ "progrock", "Progressive Rock" },
    .{ "progressiverock", "Progressive Rock" },
    .{ "progmetal", "Progressive Metal" },
    .{ "progressivemetal", "Progressive Metal" },
    .{ "psychrock", "Psychedelic Rock" },
    .{ "psychedelicrock", "Psychedelic Rock" },
    .{ "punkrock", "Punk Rock" },
    .{ "r&b", "R&B" },
    .{ "rnb", "R&B" },
    .{ "randb", "R&B" },
    .{ "rhythmandblues", "R&B" },
    .{ "rhythm&blues", "R&B" },
    .{ "rockandroll", "Rock and Roll" },
    .{ "rock&roll", "Rock and Roll" },
    .{ "rocknroll", "Rock and Roll" },
    .{ "shoegaze", "Shoegaze" },
    .{ "shoegazing", "Shoegaze" },
    .{ "singersongwriter", "Singer-Songwriter" },
    .{ "skapunk", "Ska Punk" },
    .{ "smoothjazz", "Smooth Jazz" },
    .{ "softrock", "Soft Rock" },
    .{ "soundtrack", "Soundtrack" },
    .{ "soundtracks", "Soundtrack" },
    .{ "ost", "Soundtrack" },
    .{ "originalsoundtrack", "Soundtrack" },
    .{ "spokenword", "Spoken Word" },
    .{ "synthpop", "Synth-Pop" },
    .{ "techhouse", "Tech House" },
    .{ "triphop", "Trip Hop" },
    .{ "ukgarage", "UK Garage" },
    .{ "westcoasthiphop", "West Coast Hip Hop" },
    .{ "world", "World" },
    .{ "worldmusic", "World" },
});

fn expectFolds(value: []const u8, key: []const u8, name: []const u8) !void {
    const folded = try fold(std.testing.allocator, value);
    defer std.testing.allocator.free(folded.key);
    try std.testing.expectEqualStrings(key, folded.key);
    try std.testing.expectEqualStrings(name, folded.name);
}

test "spellings of hip hop with or without the rap suffix fold to one genre" {
    try expectFolds("Hip-Hop/Rap", "hiphop", "Hip Hop");
    try expectFolds("hip hop", "hiphop", "Hip Hop");
    try expectFolds("HipHop", "hiphop", "Hip Hop");
    try expectFolds("  Hip Hop ", "hiphop", "Hip Hop");
    try expectFolds("Rap/Hip Hop", "hiphop", "Hip Hop");
}

test "an ampersand is part of a genre, so R&B/Soul is one genre and not R&B" {
    try expectFolds("R&B/Soul", "r&bsoul", "R&B/Soul");
    try expectFolds("RnB", "r&b", "R&B");
    try expectFolds("r and b", "r&b", "R&B");
    try expectFolds("Rhythm & Blues", "r&b", "R&B");
}

test "a genre the table does not know keeps its first spelling under a folded key" {
    try expectFolds("East-Coast  hip hop", "eastcoasthiphop", "East Coast Hip Hop");
    try expectFolds("Post-Punk Revival", "postpunkrevival", "Post-Punk Revival");
    try expectFolds("Brill Building", "brillbuilding", "Brill Building");
    try expectFolds("brill-building", "brillbuilding", "brill-building");
    try expectFolds("Alt. Rock", "alternativerock", "Alternative Rock");
}

test "a blank or separator-only value has no key" {
    try expectFolds("", "", "");
    try expectFolds(" - / ", "", "");
}

test "every canonical name folds to itself, so its key is stable" {
    for (aliases.values()) |canonical| {
        const folded = try fold(std.testing.allocator, canonical);
        defer std.testing.allocator.free(folded.key);
        try std.testing.expectEqualStrings(canonical, folded.name);
    }
}

fn expectSplits(values: []const []const u8, names: []const []const u8) !void {
    const genres = try foldAll(std.testing.allocator, values);
    defer freeAll(std.testing.allocator, genres);
    try std.testing.expectEqual(names.len, genres.len);
    for (names, genres) |name, genre| try std.testing.expectEqualStrings(name, genre.name);
}

test "a comma or semicolon list in one value is several genres in stated order" {
    try expectSplits(&.{"Indie Rock, Rock, Alternative Rock"}, &.{ "Indie Rock", "Rock", "Alternative Rock" });
    try expectSplits(&.{"Electronic;Ambient ; Downtempo"}, &.{ "Electronic", "Ambient", "Downtempo" });
    try expectSplits(&.{ "Jazz, Funk", "Soul" }, &.{ "Jazz", "Funk", "Soul" });
}

test "a slash does not split, so a slashed name still folds through the alias table" {
    try expectSplits(&.{"R&B/Soul, Hip-Hop/Rap"}, &.{ "R&B/Soul", "Hip Hop" });
}

test "blank parts are dropped and a genre listed twice is kept where it first appears" {
    try expectSplits(&.{" , Rock,, ;Pop; rock ;"}, &.{ "Rock", "Pop" });
    try expectSplits(&.{ "Hip Hop", "Rock, hip-hop" }, &.{ "Hip Hop", "Rock" });
    try expectSplits(&.{ " ; ", "" }, &.{});
}

test "a genre name containing a comma is matched whole before splitting" {
    try expectSplits(&.{"Folk, World, & Country"}, &.{"Folk, World, & Country"});
    try expectSplits(&.{"Rock; folk, world, & country , Pop"}, &.{ "Rock", "Folk, World, & Country", "Pop" });
    try expectSplits(&.{"Folk, World, & Country Blues"}, &.{ "Folk", "World", "& Country Blues" });
}
