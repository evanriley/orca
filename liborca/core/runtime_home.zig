const library_pass = @import("../library/root.zig");
const runtime = @import("runtime.zig");

const home = library_pass.home;
const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;

pub fn libraryListeningWeek(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime) !home.ListeningWeek {
    return home.listeningWeek(try runtime.libraryDatabase(self, library), time);
}

pub fn libraryRecentReleases(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime, output: []home.PlayedRelease) !usize {
    return home.recentReleases(try runtime.libraryDatabase(self, library), time, output);
}

pub fn libraryRediscover(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime, output: []home.PlayedRelease) !usize {
    return home.rediscover(try runtime.libraryDatabase(self, library), time, output);
}

pub fn libraryNeverPlayed(self: *OrcaRuntime, library: LibraryHandle, output: []home.HomeTrack) !usize {
    return home.neverPlayed(try runtime.libraryDatabase(self, library), output);
}

pub fn libraryDeepCuts(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime, output: []home.HomeTrack) !usize {
    return home.deepCuts(try runtime.libraryDatabase(self, library), time, output);
}

pub fn libraryTopArtists(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime, days: u32, output: []home.TopArtist) !usize {
    return home.topArtists(try runtime.libraryDatabase(self, library), time, days, output);
}

pub fn libraryFormats(self: *OrcaRuntime, library: LibraryHandle) !home.Formats {
    return home.formats(try runtime.libraryDatabase(self, library));
}

pub fn libraryOnThisDay(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime) !home.OnThisDay {
    return home.onThisDay(try runtime.libraryDatabase(self, library), time);
}

pub fn libraryHistoryAge(self: *OrcaRuntime, library: LibraryHandle, time: home.LocalTime) !home.HistoryAge {
    return home.historyAge(try runtime.libraryDatabase(self, library), time);
}
