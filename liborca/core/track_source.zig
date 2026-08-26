const std = @import("std");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const object = @import("object.zig");
const sqlite = @import("../database/sqlite.zig");

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

    pub fn openTrack(
        self: *TrackSourceOpener,
        ref: TrackRef,
    ) !audio.source_session.SourceSession {
        if (!ref.library.eql(self.library)) return error.TrackNotInBoundLibrary;
        const resolved = (try self.tracks.playableLocation(self.allocator, ref.track_id)) orelse
            return error.TrackHasNoPlayableFile;
        defer resolved.deinit();
        return audio.loaded_source.LoadedSource.open(
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
            error.UnsupportedAudioFormat => error.CodecUnavailable,
            else => err,
        };
    }
};

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
    try testing.expect(try session.readFrames(&samples) > 0);
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
