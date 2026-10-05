const std = @import("std");
const musicbrainz = @import("../providers/musicbrainz.zig");

pub const ProviderSourceId = enum(u8) {
    musicbrainz,
    musicbrainz_genres,
    cover_art_archive,
    acoustid,
    listenbrainz,
    lrclib,
    wikidata,
    wikimedia_commons,
    wikipedia,
};

/// A service Orca takes data from, with what it supplies and under which
/// licence, so every frontend credits the same sources.
pub const ProviderSource = struct {
    id: ProviderSourceId,
    name: []const u8,
    url: []const u8,
    supplies: []const u8,
    licence: []const u8,
    licence_url: ?[]const u8,
};

const cc0 = "CC0 1.0";
const cc0_url = "https://creativecommons.org/publicdomain/zero/1.0/";

/// One entry per `ProviderSourceId`, in its order.
pub const provider_sources: []const ProviderSource = &.{
    .{
        .id = .musicbrainz,
        .name = "MusicBrainz",
        .url = "https://musicbrainz.org",
        .supplies = "Recording, release and artist identification; artist and release details",
        .licence = cc0,
        .licence_url = cc0_url,
    },
    .{
        .id = .musicbrainz_genres,
        .name = "MusicBrainz genres",
        .url = "https://musicbrainz.org",
        .supplies = "Genres filled from MusicBrainz",
        .licence = musicbrainz.genre_licence,
        .licence_url = "https://creativecommons.org/licenses/by-nc-sa/3.0/",
    },
    .{
        .id = .cover_art_archive,
        .name = "Cover Art Archive",
        .url = "https://coverartarchive.org",
        .supplies = "Release covers",
        .licence = "Images remain the property of their rights holders",
        .licence_url = null,
    },
    .{
        .id = .acoustid,
        .name = "AcoustID",
        .url = "https://acoustid.org",
        .supplies = "Audio fingerprint lookups and submissions",
        .licence = "CC BY-SA 3.0",
        .licence_url = "https://creativecommons.org/licenses/by-sa/3.0/",
    },
    .{
        .id = .listenbrainz,
        .name = "ListenBrainz",
        .url = "https://listenbrainz.org",
        .supplies = "Listen submission, feedback, artist popularity and similar artists (Labs)",
        .licence = cc0,
        .licence_url = cc0_url,
    },
    .{
        .id = .lrclib,
        .name = "LRCLIB",
        .url = "https://lrclib.net",
        .supplies = "Synced and plain lyrics",
        .licence = "Lyrics are not licensed by LRCLIB; rights stay with their owners",
        .licence_url = null,
    },
    .{
        .id = .wikidata,
        .name = "Wikidata",
        .url = "https://www.wikidata.org",
        .supplies = "Artist links, identifiers and photo lookup",
        .licence = cc0,
        .licence_url = cc0_url,
    },
    .{
        .id = .wikimedia_commons,
        .name = "Wikimedia Commons",
        .url = "https://commons.wikimedia.org",
        .supplies = "Artist photos",
        .licence = "Licence varies per file; shown with each photo",
        .licence_url = null,
    },
    .{
        .id = .wikipedia,
        .name = "Wikipedia",
        .url = "https://www.wikipedia.org",
        .supplies = "Artist biographies and release descriptions",
        .licence = "CC BY-SA 4.0",
        .licence_url = "https://creativecommons.org/licenses/by-sa/4.0/",
    },
};

test "every provider source names itself, its url, what it supplies and its licence, once each and in id order" {
    const ids = std.enums.values(ProviderSourceId);
    try std.testing.expectEqual(ids.len, provider_sources.len);
    for (provider_sources, ids) |source, id| {
        try std.testing.expectEqual(id, source.id);
        try std.testing.expect(source.name.len > 0);
        try std.testing.expect(source.url.len > 0);
        try std.testing.expect(source.supplies.len > 0);
        try std.testing.expect(source.licence.len > 0);
        if (source.licence_url) |licence_url| try std.testing.expect(licence_url.len > 0);
    }
    var seen = std.EnumSet(ProviderSourceId).empty;
    for (provider_sources) |source| {
        try std.testing.expect(!seen.contains(source.id));
        seen.insert(source.id);
    }
}
