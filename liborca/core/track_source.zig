const std = @import("std");
const analysis = @import("../analysis/root.zig");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const object = @import("object.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const sqlite = @import("../database/sqlite.zig");
const storage = @import("../storage/root.zig");
const library_pass = @import("../library/root.zig");

pub const TrackRef = audio.playback_queue.TrackRef;

/// Typed reasons a queue entry could not be turned into audio. Hosts get these
/// as completion failures rather than a generic error: "this track has no file"
/// and "no codec can read this file" call for different repair actions.
pub const OpenTrackError = error{
    TrackNotInBoundLibrary,
    TrackHasNoPlayableFile,
    TrackFileMissing,
    TrackFolderUnavailable,
    CodecUnavailable,
};

/// Resolves `library track id -> decodable audio`.
///
/// It holds its own **independent read-only connection**, per `docs/database.md`,
/// so the engine thread opens tracks without waiting on the Library's single
/// write lane. It does reach for that lane in one place — recording that a file
/// it could not open is missing — and there it declines rather than waits, for
/// the reason `markMissingIfLaneFree` gives. The connection and the codec registry are the only state, so the
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
        return .{ .context = self, .open_fn = openRef, .release_fn = releaseOfRef };
    }

    fn releaseOfRef(context: *anyopaque, ref: TrackRef) ?i64 {
        const self: *TrackSourceOpener = @ptrCast(@alignCast(context));
        if (!ref.library.eql(self.library)) return null;
        return self.tracks.releaseId(ref.track_id) catch null;
    }

    fn openRef(
        context: *anyopaque,
        ref: TrackRef,
    ) anyerror!audio.source_session.SourceSession {
        const self: *TrackSourceOpener = @ptrCast(@alignCast(context));
        return self.openTrack(ref);
    }

    fn rootAvailable(self: *TrackSourceOpener, root_id: ?i64) bool {
        const roots: database.LibraryRootRepository = .{ .db = self.reader, .write_lane = self.tracks.write_lane };
        const root = (roots.find(self.allocator, root_id orelse return true) catch return true) orelse return true;
        defer root.deinit(self.allocator);
        const volumes: database.VolumeRepository = .{ .db = self.reader, .write_lane = self.tracks.write_lane };
        const recorded_key = if (root.volume_id == database.LibraryDatabase.null_volume)
            null
        else
            (volumes.stableKey(self.allocator, root.volume_id) catch return true) orelse return true;
        defer if (recorded_key) |key| self.allocator.free(key);
        return library_pass.volume_check.rootAvailable(self.allocator, self.io, root.path, recorded_key);
    }

    /// Opens a queue entry's audio, already carrying its own loudness
    /// corrections, track and album.
    ///
    /// The correction is attached **here**, at the one place a queue entry
    /// becomes audio, rather than at each caller. Every path that produces a
    /// session — the control lane's hard load, the engine thread's gapless
    /// auto-advance, a deferred format switch, a seek that re-opens the
    /// audible entry — goes through this function, so none of them can forget
    /// to publish one and none of them can publish a stale one.
    ///
    /// That does mean the engine thread reads a few indexed rows, one bounded
    /// statement over the entry's Release, and two 64 KiB file ranges when it
    /// opens an entry. It already resolves the Location
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
                if (!self.rootAvailable(resolved.root_id)) return error.TrackFolderUnavailable;
                // The library still claims this file exists. Record what is
                // actually true rather than failing the same way every time.
                _ = self.locations.markMissingIfLaneFree(resolved.file_id) catch {};
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
        const own = self.measurement(
            resolved.file_id,
            observedIdentity(self.io, resolved.uri),
        ) catch null;
        session.replay_gain = .{
            .track = if (own) |value| value.trackGain() else null,
            .album = if (own) |value| self.albumGain(ref.track_id, value) catch null else null,
        };
        return session;
    }

    /// The measurement taken from exactly these bytes, or null.
    ///
    /// Null covers four different situations on purpose — never analyzed,
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
    fn measurement(
        self: *const TrackSourceOpener,
        file_id: i64,
        source_identity: ?quick_hash.Digest,
    ) !?Measurement {
        const identity = source_identity orelse return null;
        var header: [analysis.encoding.header_size]u8 = undefined;
        const key = analysis.service.diagnosticsKey(file_id, identity, .{});
        const stored = (try self.analysis_cache.resultInto(key, &header)) orelse return null;
        if (stored < header.len) return null;
        return try Measurement.decode(&header);
    }

    /// The album correction for the Release `track_id` belongs to, or null
    /// when it has none or not every Track of it is measured.
    ///
    /// Computed here, at open, from the per-file measurements rather than
    /// stored per Release, so re-analysing a Track or moving it to another
    /// Release can never leave a stale album figure behind. The entry's own
    /// measurement is `entry`, taken from the bytes just opened; every other
    /// member's is keyed on the identity the Library recorded for its file,
    /// because opening every file of the album to hash it would cost a disc's
    /// worth of reads per track.
    fn albumGain(self: *const TrackSourceOpener, track_id: i64, entry: Measurement) !?audio.processing.Correction {
        var album: AlbumLoudness = .{ .entry_track_id = track_id, .entry = entry };
        const selector = analysis.service.diagnosticsSelector(.{});
        return switch (try self.analysis_cache.visitReleaseMembers(track_id, &selector, &album)) {
            .visited => album.gain(),
            .no_release, .too_large => null,
        };
    }
};

/// What one stored diagnostics header says about loudness.
const Measurement = struct {
    /// Null when the analysis found no gated loudness: audio too quiet or too
    /// short for any 400 ms block to pass the absolute gate.
    loudness: ?analysis.encoding.Loudness,
    sample_peak: f32,

    fn decode(header: []const u8) !Measurement {
        return .{
            .loudness = try analysis.encoding.decodeLoudness(header),
            .sample_peak = try analysis.encoding.decodeSamplePeak(header),
        };
    }

    fn trackGain(self: Measurement) ?audio.processing.Correction {
        const loudness = self.loudness orelse return null;
        return .{
            .gain = audio.processing.replayGainLinear(loudness.replay_gain_db),
            .peak = positivePeak(loudness.sample_peak),
        };
    }
};

/// The loudness of a Release as one programme: the duration-weighted mean of
/// its Tracks' integrated loudness in the energy domain, toward the canonical
/// target, with the loudest Track's peak to cap it against.
///
/// BS.1770 gating over the album's merged blocks would be exact, but the
/// stored result keeps only each file's gated loudness. A Track with no gated
/// loudness contributes no energy and no duration, as its blocks would fall
/// below the absolute gate of the album too, while its peak still counts.
const AlbumLoudness = struct {
    entry_track_id: i64,
    entry: Measurement,
    weighted_energy: f64 = 0,
    weighted_seconds: f64 = 0,
    peak: f32 = 0,
    complete: bool = true,

    pub fn visit(self: *AlbumLoudness, member: database.ReleaseMember) !void {
        const measured = if (member.track_id == self.entry_track_id)
            self.entry
        else
            Measurement.decode(member.result) catch {
                self.complete = false;
                return;
            };
        self.add(measured, member.duration_ms);
    }

    fn add(self: *AlbumLoudness, measured: Measurement, duration_ms: ?i64) void {
        self.peak = @max(self.peak, measured.sample_peak);
        const loudness = measured.loudness orelse return;
        const milliseconds = duration_ms orelse 0;
        if (milliseconds <= 0) {
            self.complete = false;
            return;
        }
        const seconds = @as(f64, @floatFromInt(milliseconds)) / 1000;
        self.weighted_energy += seconds * std.math.pow(f64, 10, @as(f64, loudness.integrated_lufs) / 10);
        self.weighted_seconds += seconds;
    }

    fn gain(self: *const AlbumLoudness) ?audio.processing.Correction {
        if (!self.complete or self.weighted_seconds == 0) return null;
        const lufs = 10 * std.math.log10(self.weighted_energy / self.weighted_seconds);
        const target: f64 = (analysis.diagnostics.Parameters{}).replay_gain_target_lufs;
        return .{
            .gain = audio.processing.replayGainLinear(@floatCast(target - lufs)),
            .peak = positivePeak(self.peak),
        };
    }
};

fn positivePeak(peak: f32) ?f32 {
    return if (peak > 0) peak else null;
}

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
    try testing.expect(try session.readFrames(&samples, .{ .mode = .track }) > 0);
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
