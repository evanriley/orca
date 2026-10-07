const library_pass = @import("../library/root.zig");
const runtime = @import("runtime.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_listens = @import("runtime_listens.zig");

const daily_mixes = library_pass.daily_mixes;
const JobHandle = runtime.JobHandle;
const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;

pub fn startDailyMixes(self: *OrcaRuntime, library: LibraryHandle, request: daily_mixes.Options) !JobHandle {
    return runtime_jobs.startDailyMixes(self, library, request);
}

pub fn libraryDailyMixes(self: *OrcaRuntime, library: LibraryHandle, now_s: i64, utc_offset_s: i64) !daily_mixes.DailyMixes {
    const library_database = try runtime.libraryDatabase(self, library);
    return daily_mixes.read(library_database, now_s, utc_offset_s);
}

pub fn libraryDailyMixEntries(self: *OrcaRuntime, library: LibraryHandle, mix_id: i64, output: []daily_mixes.Entry) !usize {
    const library_database = try runtime.libraryDatabase(self, library);
    return daily_mixes.entries(library_database, mix_id, runtime_listens.sampleTime(self).wall_s, output);
}

pub fn libraryNotForMe(self: *OrcaRuntime, library: LibraryHandle, track_id: i64, now_s: i64) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    return daily_mixes.notForMe(library_database, track_id, now_s);
}

pub fn libraryClearNotForMe(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    return daily_mixes.clearNotForMe(library_database, track_id);
}

pub fn libraryResetRecommendations(self: *OrcaRuntime, library: LibraryHandle) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    return daily_mixes.resetRecommendations(library_database);
}

pub fn librarySaveDailyMix(self: *OrcaRuntime, library: LibraryHandle, mix_id: i64, name: []const u8) !i64 {
    const library_database = try runtime.libraryDatabase(self, library);
    return daily_mixes.save(library_database, mix_id, name, runtime_listens.sampleTime(self).wall_s);
}
