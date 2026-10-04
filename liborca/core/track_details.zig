//! Everything the Library knows about one Track, gathered for a details view.
//!
//! One bounded set of indexed reads over the Library's own connection: the
//! Track row, the file it resolves to with its best location and Release, and
//! the stored loudness header. Nothing on disk is opened or hashed, so a file
//! that has changed or gone since the last scan is described as the scan left
//! it.

const std = @import("std");
const analysis = @import("../analysis/root.zig");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");

/// The loudness measured from a file's stored bytes, under the canonical
/// analysis parameters.
pub const Loudness = struct {
    /// Integrated loudness in LUFS.
    integrated_lufs: f32,
    /// The ReplayGain correction toward the analysis target, in dB.
    replay_gain_db: f32,
    /// Largest absolute sample as a linear amplitude: 1.0 is full scale.
    sample_peak: f32,
};

pub const RecordingIdSource = enum {
    tag,
    match,
    edit,

    fn of(provenance: metadata.Provenance) RecordingIdSource {
        return switch (provenance) {
            .observed_file => .tag,
            .user => .edit,
            .provider, .inference, .analysis => .match,
        };
    }
};

/// A Track as a details view shows it. Caller-owned: release with `deinit`.
pub const TrackDetails = struct {
    allocator: std.mem.Allocator,
    track_id: i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    album_artist: []u8,
    /// The Release's date as the projection resolved it.
    date: ?[]u8,
    track_number: ?i64,
    disc_number: ?i64,
    compilation: ?bool,
    /// The file's codec identifier, such as `flac` or `mp3`; empty when the
    /// Track has no file or the file was never probed.
    codec: []u8,
    /// Whether `codec` names an encoding that discards audio. False for an
    /// unknown codec.
    lossy: bool,
    sample_rate: ?u32,
    bit_depth: ?u32,
    channels: ?u32,
    duration_ms: ?i64,
    size_bytes: ?i64,
    /// File size over duration, so it includes tags and artwork. Null when
    /// either is unknown.
    bitrate_kbps: ?u32,
    /// The uri of the best location that is not missing.
    path: ?[]u8,
    /// Whether the Track has no location that is not missing.
    file_missing: bool,
    /// Null when the file has not been measured, or was measured under other
    /// parameters, an older algorithm, or bytes it no longer has.
    loudness: ?Loudness,
    has_artwork: bool,
    /// The Track's total on its disc: a total one of its files states, else
    /// the larger of the positions on the disc and the highest track number
    /// there (`track_total_inferred`).
    track_total: ?i64,
    track_total_inferred: bool,
    /// The file's stated disc total, else the Release's disc count.
    disc_total: ?i64,
    explicit: metadata.Explicit,
    /// When the library first saw the file, in Unix seconds.
    added_at: ?i64,
    /// The file's modification time at the last scan, in Unix seconds.
    modified_at: ?i64,
    /// Listens of the Track's recording through any of its files.
    play_count: u64,
    /// Unix seconds at which the latest listen started.
    last_played_at: ?i64,
    feedback: database.Feedback,
    feedback_syncable: bool,
    rating: ?u8,
    musicbrainz_recording_id: ?[]u8,
    musicbrainz_recording_id_source: ?RecordingIdSource,
    musicbrainz_release_id: ?[]u8,
    musicbrainz_release_id_source: ?RecordingIdSource,
    musicbrainz_release_group_id: ?[]u8,
    musicbrainz_release_group_id_source: ?RecordingIdSource,
    musicbrainz_release_track_id: ?[]u8,
    musicbrainz_release_track_id_source: ?RecordingIdSource,
    musicbrainz_album_artist_id: ?[]u8,
    musicbrainz_album_artist_id_source: ?RecordingIdSource,
    /// The Track's first `max_genres` genres, in the order its source gave
    /// them.
    genres: [][]u8,

    pub const max_genres = 5;

    pub fn deinit(self: TrackDetails) void {
        freeGenres(self.allocator, self.genres);
        self.allocator.free(self.title);
        self.allocator.free(self.artist);
        self.allocator.free(self.album);
        self.allocator.free(self.album_artist);
        if (self.date) |value| self.allocator.free(value);
        self.allocator.free(self.codec);
        if (self.path) |value| self.allocator.free(value);
        inline for (.{
            self.musicbrainz_recording_id,
            self.musicbrainz_release_id,
            self.musicbrainz_release_group_id,
            self.musicbrainz_release_track_id,
            self.musicbrainz_album_artist_id,
        }) |id| if (id) |value| self.allocator.free(value);
    }
};

/// The details of one Track, or null when it does not exist.
pub fn load(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    track_id: i64,
) !?TrackDetails {
    return loadForFile(allocator, library, track_id, null);
}

/// The details of one Track with the file facts of `file_id`, one of its
/// files, in place of those of the file it resolves to.
pub fn loadForFile(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    track_id: i64,
    file_id: ?i64,
) !?TrackDetails {
    var summary = (try library.tracks.byId(allocator, track_id)) orelse return null;
    allocator.free(summary.codec);
    summary.codec = &.{};
    allocator.free(summary.path);
    summary.path = &.{};
    allocator.free(summary.genre);
    summary.genre = &.{};
    errdefer summary.deinit(allocator);
    const facts = try library.tracks.fileFactsOf(allocator, track_id, file_id);
    errdefer if (facts) |value| value.deinit();

    const loudness = if (facts) |file| try storedLoudness(library, file) else null;
    const duration_ms = if (facts) |file| file.duration_ms orelse summary.duration_ms else summary.duration_ms;
    const size_bytes = if (facts) |file| positive(file.size_bytes) else null;
    const plays = try library.listens.trackPlayStats(track_id);
    const feedback_syncable = try library.feedback.canSync(track_id);
    const recording_mbid = try library.tracks.recordingMbid(allocator, track_id);
    errdefer if (recording_mbid) |value| value.deinit(allocator);
    const release_mbid = try library.tracks.musicBrainzId(allocator, track_id, .musicbrainz_release_id);
    errdefer if (release_mbid) |value| value.deinit(allocator);
    const release_group_mbid = try library.tracks.musicBrainzId(allocator, track_id, .musicbrainz_release_group_id);
    errdefer if (release_group_mbid) |value| value.deinit(allocator);
    const release_track_mbid = try library.tracks.musicBrainzId(allocator, track_id, .musicbrainz_release_track_id);
    errdefer if (release_track_mbid) |value| value.deinit(allocator);
    const album_artist_mbid = try library.tracks.musicBrainzId(allocator, track_id, .musicbrainz_album_artist_id);
    errdefer if (album_artist_mbid) |value| value.deinit(allocator);
    const genres = try loadGenres(allocator, library, track_id);
    errdefer freeGenres(allocator, genres);
    const codec_identifier = if (facts) |file| file.codec else try allocator.alloc(u8, 0);

    return .{
        .allocator = allocator,
        .track_id = summary.id,
        .title = summary.title,
        .artist = summary.artist,
        .album = summary.album,
        .album_artist = summary.album_artist,
        .date = if (facts) |file| file.release_date else null,
        .track_number = summary.track_number,
        .disc_number = summary.disc_number,
        .compilation = if (facts) |file| file.compilation else null,
        .codec = codec_identifier,
        .lossy = isLossy(codec_identifier),
        .sample_rate = if (facts) |file| positiveU32(file.sample_rate) else null,
        .bit_depth = if (facts) |file| positiveU32(file.bit_depth) else null,
        .channels = if (facts) |file| positiveU32(file.channels) else null,
        .duration_ms = duration_ms,
        .size_bytes = size_bytes,
        .bitrate_kbps = bitrateKbps(size_bytes, duration_ms),
        .path = if (facts) |file| file.path else null,
        .file_missing = if (facts) |file| file.path == null else true,
        .loudness = loudness,
        .has_artwork = if (facts) |file| file.has_artwork else false,
        .track_total = summary.track_total,
        .track_total_inferred = if (facts) |file| file.track_total_inferred else false,
        .disc_total = summary.disc_total,
        .explicit = summary.explicit,
        .added_at = if (facts) |file| file.first_seen_at else null,
        .modified_at = if (facts) |file| file.modified_at else null,
        .play_count = plays.play_count,
        .last_played_at = plays.last_played_at,
        .feedback = summary.feedback,
        .feedback_syncable = feedback_syncable,
        .rating = summary.rating,
        .musicbrainz_recording_id = if (recording_mbid) |value| value.text else null,
        .musicbrainz_recording_id_source = if (recording_mbid) |value| RecordingIdSource.of(value.provenance) else null,
        .musicbrainz_release_id = if (release_mbid) |value| value.text else null,
        .musicbrainz_release_id_source = if (release_mbid) |value| RecordingIdSource.of(value.provenance) else null,
        .musicbrainz_release_group_id = if (release_group_mbid) |value| value.text else null,
        .musicbrainz_release_group_id_source = if (release_group_mbid) |value| RecordingIdSource.of(value.provenance) else null,
        .musicbrainz_release_track_id = if (release_track_mbid) |value| value.text else null,
        .musicbrainz_release_track_id_source = if (release_track_mbid) |value| RecordingIdSource.of(value.provenance) else null,
        .musicbrainz_album_artist_id = if (album_artist_mbid) |value| value.text else null,
        .musicbrainz_album_artist_id_source = if (album_artist_mbid) |value| RecordingIdSource.of(value.provenance) else null,
        .genres = genres,
    };
}

fn loadGenres(allocator: std.mem.Allocator, library: *database.LibraryDatabase, track_id: i64) ![][]u8 {
    const names = try library.genres.forTrack(allocator, track_id);
    defer names.deinit();
    const genres = try allocator.alloc([]u8, @min(names.items.len, TrackDetails.max_genres));
    for (genres, names.items[0..genres.len]) |*genre, *name| {
        genre.* = name.name;
        name.name = &.{};
    }
    return genres;
}

fn freeGenres(allocator: std.mem.Allocator, genres: []const []u8) void {
    for (genres) |genre| allocator.free(genre);
    allocator.free(genres);
}

/// The size and duration a bitrate is derived from, rounded to the nearest
/// kilobit per second.
pub fn bitrateKbps(size_bytes: ?i64, duration_ms: ?i64) ?u32 {
    const size: u64 = std.math.cast(u64, size_bytes orelse return null) orelse return null;
    const duration: u64 = std.math.cast(u64, duration_ms orelse return null) orelse return null;
    if (size == 0 or duration == 0) return null;
    const kilobits_per_second = (size *| 8 +| duration / 2) / duration;
    return std.math.cast(u32, kilobits_per_second);
}

fn isLossy(codec_identifier: []const u8) bool {
    return codec_identifier.len > 0 and !codec.decoder.codec_id.isLossless(codec_identifier);
}

fn positive(value: i64) ?i64 {
    return if (value > 0) value else null;
}

fn positiveU32(value: ?i64) ?u32 {
    const number = value orelse return null;
    if (number <= 0) return null;
    return std.math.cast(u32, number);
}

fn storedLoudness(
    library: *database.LibraryDatabase,
    file: database.repository.TrackFileFacts,
) !?Loudness {
    const identity = file.quick_hash orelse return null;
    var header: [analysis.encoding.header_size]u8 = undefined;
    const stored = (try library.analysis_cache.resultInto(
        analysis.service.diagnosticsKey(file.file_id, identity, .{}),
        &header,
    )) orelse return null;
    if (stored < header.len) return null;
    const measured = analysis.encoding.decodeLoudness(&header) catch |err| switch (err) {
        error.InvalidAnalysisResult, error.UnsupportedAnalysisResultVersion => return null,
    };
    const value = measured orelse return null;
    return .{
        .integrated_lufs = value.integrated_lufs,
        .replay_gain_db = value.replay_gain_db,
        .sample_peak = value.sample_peak,
    };
}

const testing = std.testing;

test "a bitrate is the file size over the duration, rounded to a kilobit" {
    try testing.expectEqual(@as(?u32, 1000), bitrateKbps(125_000, 1000));
    try testing.expectEqual(@as(?u32, 955), bitrateKbps(32_083_623, 268_769));
    try testing.expectEqual(@as(?u32, 10), bitrateKbps(1_250, 1000));
}

test "a bitrate is unknown without a size or a duration" {
    try testing.expectEqual(@as(?u32, null), bitrateKbps(null, 1000));
    try testing.expectEqual(@as(?u32, null), bitrateKbps(125_000, null));
    try testing.expectEqual(@as(?u32, null), bitrateKbps(0, 1000));
    try testing.expectEqual(@as(?u32, null), bitrateKbps(125_000, 0));
    try testing.expectEqual(@as(?u32, null), bitrateKbps(-5, 1000));
}

test "every lossy codec is reported lossy and an unknown codec is not" {
    for ([_][]const u8{ "mp1", "mp2", "mp3", "aac", "vorbis", "opus", "qoa" }) |lossy| {
        try testing.expect(isLossy(lossy));
    }
    for ([_][]const u8{ "flac", "alac", "pcm", "pcm_float", "" }) |not_lossy| {
        try testing.expect(!isLossy(not_lossy));
    }
}
