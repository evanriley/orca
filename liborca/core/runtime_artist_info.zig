const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const runtime = @import("runtime.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;

pub fn libraryArtistInfo(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !?database.ArtistInfo {
    return (try runtime.libraryDatabase(self, library)).artist_info.get(self.allocator, artist_id);
}

pub fn libraryArtistPhoto(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !?metadata.EmbeddedImage {
    return (try runtime.libraryDatabase(self, library)).artist_info.photo(self.allocator, artist_id);
}

pub fn libraryArtistLinks(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !database.ArtistLinks {
    return (try runtime.libraryDatabase(self, library)).artist_info.links(self.allocator, artist_id);
}

pub fn libraryArtistElsewhere(self: *OrcaRuntime, library: LibraryHandle, allocator: std.mem.Allocator, artist_id: i64) ![]database.ElsewhereRelease {
    return (try runtime.libraryDatabase(self, library)).artist_info.elsewhere(allocator, artist_id);
}

pub fn libraryRelatedArtists(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !database.RelatedArtists {
    return (try runtime.libraryDatabase(self, library)).artist_info.related(self.allocator, artist_id);
}

pub fn libraryRelatedArtistPhoto(self: *OrcaRuntime, library: LibraryHandle, musicbrainz_artist_id: []const u8) !?metadata.EmbeddedImage {
    return (try runtime.libraryDatabase(self, library)).artist_info.relatedPhoto(self.allocator, musicbrainz_artist_id);
}

pub fn libraryRelatedArtistPhotoInfo(self: *OrcaRuntime, library: LibraryHandle, musicbrainz_artist_id: []const u8) !?database.RelatedArtistPhotoInfo {
    return (try runtime.libraryDatabase(self, library)).artist_info.relatedPhotoInfo(self.allocator, musicbrainz_artist_id);
}

pub fn libraryReleaseInfo(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !?database.ReleaseInfo {
    return (try runtime.libraryDatabase(self, library)).release_info.get(self.allocator, release_id);
}

pub fn setGenreFill(self: *OrcaRuntime, library: LibraryHandle, fill: runtime.GenreFill) !void {
    try (try runtime.libraryDatabase(self, library)).settings.setFlag(database.setting_genre_fill_musicbrainz, fill.musicbrainz);
}

pub fn libraryGenreFill(self: *OrcaRuntime, library: LibraryHandle) !runtime.GenreFill {
    return .{ .musicbrainz = try (try runtime.libraryDatabase(self, library)).settings.flag(database.setting_genre_fill_musicbrainz, true) };
}

pub fn librarySetArtistLove(
    self: *OrcaRuntime,
    library: LibraryHandle,
    artist_ids: []const i64,
    loved: bool,
) !database.ArtistLoveChange {
    return (try runtime.libraryDatabase(self, library)).artist_loves.set(artist_ids, loved);
}

pub fn libraryArtistLoved(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !bool {
    return (try runtime.libraryDatabase(self, library)).artist_loves.isLoved(artist_id);
}
