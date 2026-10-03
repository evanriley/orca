const database = @import("../database/root.zig");
const runtime = @import("runtime.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;

pub fn libraryGenrePage(self: *OrcaRuntime, library: LibraryHandle, query: database.GenreQuery) !database.GenrePage {
    return (try runtime.libraryDatabase(self, library)).genres.page(self.allocator, query);
}

pub fn libraryGenreCount(self: *OrcaRuntime, library: LibraryHandle, filter: []const u8) !u64 {
    return (try runtime.libraryDatabase(self, library)).genres.count(self.allocator, filter);
}

pub fn libraryGenre(self: *OrcaRuntime, library: LibraryHandle, genre_id: i64) !?database.GenreSummary {
    return (try runtime.libraryDatabase(self, library)).genres.byId(self.allocator, genre_id);
}

pub fn libraryTrackGenres(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !database.GenreNames {
    return (try runtime.libraryDatabase(self, library)).genres.forTrack(self.allocator, track_id);
}

pub fn libraryReleaseGenres(self: *OrcaRuntime, library: LibraryHandle, release_id: i64, limit: u32) !database.GenreCounts {
    return (try runtime.libraryDatabase(self, library)).genres.forRelease(self.allocator, release_id, limit);
}

pub fn libraryArtistGenres(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64, limit: u32) !database.GenreCounts {
    return (try runtime.libraryDatabase(self, library)).genres.forArtist(self.allocator, artist_id, limit);
}

pub fn librarySetTrackGenres(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_ids: []const i64,
    names: []const []const u8,
) !void {
    if (track_ids.len == 0 or track_ids.len > database.repository.max_page) return error.InvalidTrackSelection;
    return (try runtime.libraryDatabase(self, library)).genres.setTrackGenres(self.allocator, track_ids, names);
}

pub fn libraryGenreArtwork(self: *OrcaRuntime, library: LibraryHandle, genre_id: i64, limit: u32) !database.ReleaseIds {
    return (try runtime.libraryDatabase(self, library)).genres.artworkReleases(self.allocator, genre_id, limit);
}
