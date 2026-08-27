const std = @import("std");
const analysis = @import("../analysis/root.zig");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const object = @import("object.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const sqlite = @import("../database/sqlite.zig");
const storage = @import("../storage/root.zig");

pub const TrackRef = audio.playback_queue.TrackRef;

/// Typed reasons a queue entry could not be turned into audio. Hosts get these
/// as completion failures rather than a generic error: "this track has no file"
/// and "no codec can read this file" call for different repair actions.
pub const OpenTrackError = error{
    TrackNotInBoundLibrary,
    TrackHasNoPlayableFile,
    TrackFileMissing,
    CodecUnavailable,
};

/// Resolves `library track id -> decodable audio`.
///
/// It holds its own **independent read-only connection**, per `docs/database.md`
/// — the engine thread opens tracks on it while the Library's single write lane
/// stays free. The connection and the codec registry are the only state, so the
/// engine never reaches back into a `handle.Pool` to resolve anything.
///
/// One opener is bound to one Library. A queue entry naming a different Library
/// is refused rather than silently resolved against the wrong database.
pub const TrackSourceOpener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: object.LibraryHandle,
    reader: sqlite.Database,
    tracks: database.TrackRepository,
    /// The Library's write side, used only to mark a Location `missing` when a
    /// file the database still lists turns out not to be there.
    locations: *database.LocationRepository,
    /// Read-only, on the opener's own connection: the stored loudness for the
    /// file behind a queue entry, looked up while the entry is being loaded.
    analysis_cache: database.AnalysisCacheRepository,
    codecs: codec.CodecRegistry,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        library: object.LibraryHandle,
        library_database: *database.LibraryDatabase,
    ) !*TrackSourceOpener {
        const self = try allocator.create(TrackSourceOpener);
        errdefer allocator.destroy(self);
        const reader = try library_database.openReader();
        errdefer reader.close();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .library = library,
            .reader = reader,
            .tracks = .{ .db = reader, .write_lane = library_database.write_lane },
            .locations = &library_database.locations,
            .analysis_cache = .{ .db = reader, .write_lane = library_database.write_lane },
            .codecs = codec.CodecRegistry.builtins(),
        };
        return self;
    }

    pub fn destroy(self: *TrackSourceOpener) void {
        const allocator = self.allocator;
        self.reader.close();
        allocator.destroy(self);
    }

    pub fn opener(self: *TrackSourceOpener) audio.playback_queue.TrackOpener {
        return .{ .context = self, .open_fn = openRef };
    }

    fn openRef(
        context: *anyopaque,
        ref: TrackRef,
    ) anyerror!audio.source_session.SourceSession {
        const self: *TrackSourceOpener = @ptrCast(@alignCast(context));
        return self.openTrack(ref);
    }

    /// Opens a queue entry's audio, already carrying its own loudness
    /// correction.
    ///
    /// The correction is attached **here**, at the one place a queue entry
    /// becomes audio, rather than at each caller. Every path that produces a
    /// session — the control lane's hard load, the engine thread's gapless
    /// auto-advance, a deferred format switch, a seek that re-opens the
    /// audible entry — goes through this function, so none of them can forget
    /// to publish one and none of them can publish a stale one.
    ///
    /// That does mean the engine thread reads two indexed rows and two 64 KiB
    /// file ranges when it opens an entry. It already resolves the Location
    /// and opens the file on that lane for the same reason: opening is not the
    /// decode path, it happens once per entry, and it is emphatically not the
    /// render lane. Pre-resolving corrections on the control lane instead
    /// would mean guessing which entry auto-advance is going to pick, which
    /// repeat and shuffle make unknowable until it picks it.
    pub fn openTrack(
        self: *TrackSourceOpener,
        ref: TrackRef,
    ) !audio.source_session.SourceSession {
        if (!ref.library.eql(self.library)) return error.TrackNotInBoundLibrary;
        const resolved = (try self.tracks.playableLocation(self.allocator, ref.track_id)) orelse
            return error.TrackHasNoPlayableFile;
        defer resolved.deinit();
        var session = audio.loaded_source.LoadedSource.open(
            self.allocator,
            self.io,
            self.codecs,
            resolved.uri,
        ) catch |err| switch (err) {
            error.FileNotFound, error.BadPathName => {
                // The library still claims this file exists. Record what is
                // actually true rather than failing the same way every time.
                markLocationMissing(self.locations, resolved.file_id) catch {};
                return error.TrackFileMissing;
            },
            error.UnsupportedAudioFormat => return error.CodecUnavailable,
            else => return err,
        };
        // Observed, not taken from the row. The correction must be keyed on
        // the content that is about to be decoded, not on what the Library
        // last recorded about it. A lookup that fails is a correction we
        // cannot vouch for, which is the same answer as one that is absent —
        // and it must never fail the load, because the track is playable
        // either way.
        session.replay_gain = self.replayGain(
            resolved.file_id,
            observedIdentity(self.io, resolved.uri),
        ) catch 1;
        return session;
    }

    /// The loudness correction measured from exactly these bytes, or 1.
    ///
    /// Unity covers four different situations on purpose — never analyzed,
    /// analyzed under other parameters, analyzed under an older algorithm, and
    /// analyzed from bytes this file no longer has — because a Player does the
    /// same thing with all four: play at unity. A correction whose provenance
    /// is not the file in front of us is worse than no correction, and only
    /// this identity, taken from the file itself, can rule that out: the
    /// Library's own record of a file's bytes is only as fresh as the last
    /// scan.
    ///
    /// Only the canonical parameters are adopted. The target LUFS is one of
    /// them, so adopting a measurement made under arbitrary parameters would
    /// apply a correction toward a target nobody chose.
    ///
    /// Reads only the fixed header of the stored result. The rest is a
    /// waveform, and this runs while a track is loading.
    fn replayGain(
        self: *const TrackSourceOpener,
        file_id: i64,
        source_identity: ?quick_hash.Digest,
    ) !f32 {
        const identity = source_identity orelse return 1;
        var header: [analysis.encoding.header_size]u8 = undefined;
        const stored = (try self.analysis_cache.resultInto(
            analysis.service.diagnosticsKey(file_id, identity, .{}),
            &header,
        )) orelse return 1;
        if (stored < header.len) return 1;
        const loudness = (try analysis.encoding.decodeLoudness(&header)) orelse return 1;
        return audio.processing.replayGainMultiplier(
            loudness.replay_gain_db,
            loudness.sample_peak,
        );
    }
};

/// The quick hash of a file that has just been opened for playback.
///
/// A second open rather than a borrowed one: `SourceSession` deliberately
/// hides the `ReadableSource` its decoder holds, because nothing downstream of
/// the producer may reach it. Two 64 KiB positional reads against a file the
/// decoder is about to read in full is not a cost worth breaking that for.
///
/// Failure is null rather than an error: an identity that cannot be read means
/// nothing content-keyed can be adopted, which is the same answer as having no
/// measurement, and it must never stop a playable track from playing.
fn observedIdentity(io: std.Io, uri: []const u8) ?quick_hash.Digest {
    var local = storage.LocalFileSource.open(io, uri) catch return null;
    defer local.close();
    return quick_hash.fromSource(local.readable()) catch null;
}

/// Marks every Location of a file as `missing`.
///
/// This is a `LocationRepository` operation and belongs there next to `move`;
/// it lives here only because `liborca/database/` is being edited concurrently.
/// Move it when that lands — nothing else about it should change.
fn markLocationMissing(
    locations: *database.LocationRepository,
    file_id: i64,
) !void {
    locations.write_lane.acquire();
    defer locations.write_lane.release();
    var statement = try locations.db.prepare(
        \\UPDATE locations SET state='missing', missing_since=unixepoch()
        \\WHERE file_id=?1 AND state<>'missing';
    );
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    if (try statement.step() != .done) return error.SqlFailed;
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

fn projectSingleFile(
    library: *database.LibraryDatabase,
    path: []const u8,
) !i64 {
    const volume_id = try library.volumes.ensure(.{
        .stable_key = "uuid:track-source-test",
        .label = "Test volume",
    });
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = volume_id,
        .uri = path,
    });
    try library.tracks.upsertTracks(&.{.{
        .title = "Reference",
        .preferred_file_id = file_id,
    }});
    var page = try library.tracks.page(testing.allocator, .{ .limit = 1, .offset = 0 });
    defer page.deinit();
    return page.items[0].id;
}

test "a track id resolves to a self-contained decodable session" {
    var library = try database.LibraryDatabase.open(
        testing.allocator,
        testing.io,
        "file:orca-track-source-open?mode=memory&cache=shared",
    );
    defer library.close();
    const track_id = try projectSingleFile(&library, "fixtures/audio/generated-reference.wav");

    const handle: object.LibraryHandle = .{ .index = 0, .generation = 1 };
    const opener = try TrackSourceOpener.create(testing.allocator, testing.io, handle, &library);
    defer opener.destroy();

    var session = try opener.openTrack(.{ .library = handle, .track_id = track_id });
    defer session.deinit();
    // Self-contained: nothing backing the decoder lives in this frame.
    try testing.expect(session.owned_source != null);
    var samples: [64]f32 = undefined;
    try testing.expect(try session.readFrames(&samples, true) > 0);
}

test "a track whose file has gone marks its location missing and fails typed" {
    var library = try database.LibraryDatabase.open(
        testing.allocator,
        testing.io,
        "file:orca-track-source-missing?mode=memory&cache=shared",
    );
    defer library.close();
    const track_id = try projectSingleFile(&library, "fixtures/audio/does-not-exist.wav");

    const handle: object.LibraryHandle = .{ .index = 0, .generation = 1 };
    const opener = try TrackSourceOpener.create(testing.allocator, testing.io, handle, &library);
    defer opener.destroy();

    try testing.expectError(
        error.TrackFileMissing,
        opener.openTrack(.{ .library = handle, .track_id = track_id }),
    );
    // Recorded, not merely reported: the next scan starts from the truth.
    const resolved = try library.tracks.playableLocation(testing.allocator, track_id);
    if (resolved) |value| {
        defer value.deinit();
        const location_id = (try library.locations.find(
            try library.volumes.ensure(.{ .stable_key = "uuid:track-source-test" }),
            "fixtures/audio/does-not-exist.wav",
        )).?;
        try testing.expectEqual(
            database.LocationState.missing,
            try library.locations.stateOf(location_id),
        );
    }
}

test "a track from another Library is refused rather than resolved wrongly" {
    var library = try database.LibraryDatabase.open(
        testing.allocator,
        testing.io,
        "file:orca-track-source-foreign?mode=memory&cache=shared",
    );
    defer library.close();
    const track_id = try projectSingleFile(&library, "fixtures/audio/generated-reference.wav");
    const handle: object.LibraryHandle = .{ .index = 0, .generation = 1 };
    const other: object.LibraryHandle = .{ .index = 1, .generation = 1 };
    const opener = try TrackSourceOpener.create(testing.allocator, testing.io, handle, &library);
    defer opener.destroy();
    try testing.expectError(
        error.TrackNotInBoundLibrary,
        opener.openTrack(.{ .library = other, .track_id = track_id }),
    );
}
