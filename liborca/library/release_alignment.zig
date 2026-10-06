const std = @import("std");
const database = @import("../database/root.zig");

/// Within this many milliseconds a Track's length agrees with a release
/// track's.
pub const length_agreement_ms = 2000;
/// A suggestion needs at least this many of the three evidence flags.
pub const suggestion_minimum_evidence = 2;

pub const PlacementStatus = enum {
    /// A person paired the Track with the release track.
    paired,
    /// The release lists a recording ID the Track holds.
    automatic,
    /// Evidence agrees; a person confirms it.
    suggested,
    /// No local Track is on the release track.
    not_in_files,
};

/// Where the Track's recording ID that placed it came from.
pub const RecordingSource = enum {
    /// The play file's recording ID in effect: its tag or a user-set value.
    in_effect,
    accepted_match,
    pending_match,
};

pub const PlacementEvidence = struct {
    /// Set for an automatic placement only.
    recording_source: ?RecordingSource = null,
    /// The normalized titles are equal.
    title_equal: bool = false,
    /// The lengths are within `length_agreement_ms`.
    length_close: bool = false,
    /// The Track's disc (1 when unset) and track number are the release
    /// track's.
    position_equal: bool = false,
    /// The Track's length minus the release track's, when both are known.
    length_delta_ms: ?i64 = null,

    fn count(self: PlacementEvidence) u8 {
        return @as(u8, @intFromBool(self.title_equal)) + @intFromBool(self.length_close) + @intFromBool(self.position_equal);
    }
};

/// A Track of the Release as an alignment shows it.
pub const AlignedTrack = struct {
    track_id: i64,
    title: []const u8,
    track_number: ?u32,
    disc_number: ?u32,
    duration_ms: ?i64,
};

/// One release track and the local Track placed on it.
pub const ReleaseTrackPlacement = struct {
    disc: u32,
    position: u32,
    title: []const u8,
    artist_credit: []const u8,
    length_ms: ?u64,
    recording_mbid: []const u8,
    release_track_mbid: []const u8,
    status: PlacementStatus,
    /// Null when `status` is `not_in_files`.
    track: ?AlignedTrack,
    /// What agrees between `track` and the release track.
    evidence: PlacementEvidence,
};

/// A Release laid against one MusicBrainz release's tracklist snapshot.
pub const ReleaseAlignment = struct {
    arena: *std.heap.ArenaAllocator,
    release_id: i64,
    release_mbid: []const u8,
    title: []const u8,
    artist_credit: []const u8,
    release_date: ?[]const u8,
    release_group_mbid: ?[]const u8,
    medium_count: u32,
    /// Unix seconds.
    fetched_at: i64,
    /// One per release track, in disc then position order.
    rows: []const ReleaseTrackPlacement,
    /// Tracks placed on no release track, in disc, track number, then
    /// Track ID order.
    not_on_release: []const AlignedTrack,

    pub fn deinit(self: ReleaseAlignment) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

const Holding = struct { mbid: []const u8, source: RecordingSource };

/// Places `tracks` on `tracklist`. `tracks` are in disc (1 when unset),
/// track number (unset last), then Track ID order, as a
/// `database.ReleaseMatchView` holds them.
///
/// Each of `pairings` on the tracklist's release places its Track first,
/// unless the snapshot no longer lists its release track or the Track is not
/// among `tracks`. Automatic placement then runs over the Track's recording IDs in effect and
/// accepted first, then its pending ones; within each, a Track takes a free
/// release track listing its recording at its own disc and track number
/// first, then the first free one listing it. The Track earlier in order
/// wins a release track two Tracks hold. A suggestion pairs a still
/// unplaced Track and release track when at least
/// `suggestion_minimum_evidence` flags agree and the pair is the unique
/// best for both.
pub fn alignRelease(
    allocator: std.mem.Allocator,
    release_id: i64,
    tracks: []const database.ReleaseMatchTrack,
    tracklist: *const database.ReleaseTracklistRecord,
    pairings: []const database.ReleaseTrackPairing,
) !ReleaseAlignment {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    var result: ReleaseAlignment = .{
        .arena = arena,
        .release_id = release_id,
        .release_mbid = "",
        .title = "",
        .artist_credit = "",
        .release_date = null,
        .release_group_mbid = null,
        .medium_count = tracklist.medium_count,
        .fetched_at = tracklist.fetched_at,
        .rows = &.{},
        .not_on_release = &.{},
    };
    errdefer result.deinit();
    const owned = arena.allocator();
    result.release_mbid = try owned.dupe(u8, tracklist.release_mbid);
    result.title = try owned.dupe(u8, tracklist.title);
    result.artist_credit = try owned.dupe(u8, tracklist.artist_credit);
    result.release_date = if (tracklist.release_date) |date| try owned.dupe(u8, date) else null;
    result.release_group_mbid = if (tracklist.release_group_mbid) |mbid| try owned.dupe(u8, mbid) else null;

    var scratch_arena: std.heap.ArenaAllocator = .init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const release_tracks = tracklist.tracks;
    const placed_track = try scratch.alloc(?usize, release_tracks.len);
    @memset(placed_track, null);
    const source_of = try scratch.alloc(?RecordingSource, release_tracks.len);
    @memset(source_of, null);
    const placed_row = try scratch.alloc(?usize, tracks.len);
    @memset(placed_row, null);
    const holdings = try scratch.alloc([]const Holding, tracks.len);
    for (tracks, holdings) |*track, *held| held.* = try holdingsOf(scratch, track);
    const paired = try scratch.alloc(bool, release_tracks.len);
    @memset(paired, false);

    for (pairings) |pairing| {
        if (!std.mem.eql(u8, pairing.release_mbid, tracklist.release_mbid)) continue;
        const track_index = for (tracks, 0..) |track, index| {
            if (track.track_id == pairing.track_id) break index;
        } else continue;
        const row = for (release_tracks, 0..) |release_track, index| {
            if (std.mem.eql(u8, release_track.release_track_mbid, pairing.release_track_mbid)) break index;
        } else continue;
        if (placed_row[track_index] != null or placed_track[row] != null) continue;
        placed_track[row] = track_index;
        placed_row[track_index] = row;
        paired[row] = true;
    }

    for ([_]bool{ true, false }) |strong| {
        for ([_]bool{ true, false }) |at_position| {
            for (tracks, holdings, placed_row, 0..) |*track, held, *row_slot, track_index| {
                if (row_slot.* != null) continue;
                for (held) |holding| {
                    if (isStrong(holding.source) != strong) continue;
                    const row = freeRow(release_tracks, placed_track, holding.mbid, if (at_position) track else null) orelse continue;
                    placed_track[row] = track_index;
                    source_of[row] = holding.source;
                    row_slot.* = row;
                    break;
                }
            }
        }
    }

    const evidence = try scratch.alloc(PlacementEvidence, tracks.len * release_tracks.len);
    const title_keys = try scratch.alloc([]const u8, tracks.len);
    for (tracks, title_keys) |track, *key| key.* = try database.text_key.normalizeKey(scratch, track.title);
    const release_keys = try scratch.alloc([]const u8, release_tracks.len);
    for (release_tracks, release_keys) |release_track, *key| key.* = try database.text_key.normalizeKey(scratch, release_track.title);
    for (tracks, 0..) |*track, track_index| {
        for (release_tracks, 0..) |*release_track, row| {
            evidence[track_index * release_tracks.len + row] = compare(track, title_keys[track_index], release_track, release_keys[row]);
        }
    }

    const suggested = try scratch.alloc(?usize, release_tracks.len);
    @memset(suggested, null);
    for (tracks, 0..) |_, track_index| {
        if (placed_row[track_index] != null) continue;
        const row = bestRow(evidence, release_tracks.len, track_index, placed_track) orelse continue;
        if (bestTrack(evidence, release_tracks.len, tracks.len, row, placed_row) != track_index) continue;
        suggested[row] = track_index;
    }

    const rows = try owned.alloc(ReleaseTrackPlacement, release_tracks.len);
    for (release_tracks, rows, 0..) |release_track, *placement, row| {
        const track_index = placed_track[row] orelse suggested[row];
        placement.* = .{
            .disc = release_track.disc,
            .position = release_track.position,
            .title = try owned.dupe(u8, release_track.title),
            .artist_credit = try owned.dupe(u8, release_track.artist_credit),
            .length_ms = release_track.length_ms,
            .recording_mbid = try owned.dupe(u8, release_track.recording_mbid),
            .release_track_mbid = try owned.dupe(u8, release_track.release_track_mbid),
            .status = if (paired[row]) .paired else if (placed_track[row] != null) .automatic else if (suggested[row] != null) .suggested else .not_in_files,
            .track = if (track_index) |index| try alignedTrack(owned, &tracks[index]) else null,
            .evidence = if (track_index) |index| evidence[index * release_tracks.len + row] else .{},
        };
        placement.evidence.recording_source = source_of[row];
    }
    result.rows = rows;

    var not_on_release: std.ArrayList(AlignedTrack) = .empty;
    for (tracks, 0..) |*track, track_index| {
        if (placed_row[track_index] != null) continue;
        if (std.mem.indexOfScalar(?usize, suggested, track_index) != null) continue;
        try not_on_release.append(owned, try alignedTrack(owned, track));
    }
    result.not_on_release = not_on_release.items;
    return result;
}

fn holdingsOf(scratch: std.mem.Allocator, track: *const database.ReleaseMatchTrack) ![]const Holding {
    var held: std.ArrayList(Holding) = .empty;
    if (track.recording_mbid) |mbid| try held.append(scratch, .{ .mbid = mbid, .source = .in_effect });
    for (track.proposals) |proposal| {
        if (proposal.state == .accepted) try held.append(scratch, .{ .mbid = proposal.recording_mbid, .source = .accepted_match });
    }
    for (track.proposals) |proposal| {
        if (proposal.state == .pending) try held.append(scratch, .{ .mbid = proposal.recording_mbid, .source = .pending_match });
    }
    return held.items;
}

fn isStrong(source: RecordingSource) bool {
    return source != .pending_match;
}

fn freeRow(
    release_tracks: []const database.ReleaseTracklistTrack,
    placed_track: []const ?usize,
    mbid: []const u8,
    at: ?*const database.ReleaseMatchTrack,
) ?usize {
    for (release_tracks, placed_track, 0..) |release_track, placed, row| {
        if (placed != null) continue;
        if (!std.ascii.eqlIgnoreCase(release_track.recording_mbid, mbid)) continue;
        if (at) |track| if (!samePosition(track, release_track)) continue;
        return row;
    }
    return null;
}

fn samePosition(track: *const database.ReleaseMatchTrack, release_track: database.ReleaseTracklistTrack) bool {
    const number = track.track_number orelse return false;
    return number == release_track.position and (track.disc_number orelse 1) == release_track.disc;
}

fn compare(
    track: *const database.ReleaseMatchTrack,
    title_key: []const u8,
    release_track: *const database.ReleaseTracklistTrack,
    release_key: []const u8,
) PlacementEvidence {
    var evidence: PlacementEvidence = .{
        .title_equal = title_key.len != 0 and std.mem.eql(u8, title_key, release_key),
        .position_equal = samePosition(track, release_track.*),
    };
    if (track.duration_ms) |local| if (release_track.length_ms) |length| if (std.math.cast(i64, length)) |remote| {
        const delta = local - remote;
        evidence.length_delta_ms = delta;
        evidence.length_close = @abs(delta) <= length_agreement_ms;
    };
    return evidence;
}

fn bestRow(evidence: []const PlacementEvidence, row_count: usize, track_index: usize, placed_track: []const ?usize) ?usize {
    var best: ?usize = null;
    var best_count: u8 = suggestion_minimum_evidence - 1;
    var tied = false;
    for (0..row_count) |row| {
        if (placed_track[row] != null) continue;
        const count = evidence[track_index * row_count + row].count();
        if (count > best_count) {
            best = row;
            best_count = count;
            tied = false;
        } else if (count == best_count and best != null) tied = true;
    }
    return if (tied) null else best;
}

fn bestTrack(evidence: []const PlacementEvidence, row_count: usize, track_count: usize, row: usize, placed_row: []const ?usize) ?usize {
    var best: ?usize = null;
    var best_count: u8 = suggestion_minimum_evidence - 1;
    var tied = false;
    for (0..track_count) |track_index| {
        if (placed_row[track_index] != null) continue;
        const count = evidence[track_index * row_count + row].count();
        if (count > best_count) {
            best = track_index;
            best_count = count;
            tied = false;
        } else if (count == best_count and best != null) tied = true;
    }
    return if (tied) null else best;
}

fn alignedTrack(owned: std.mem.Allocator, track: *const database.ReleaseMatchTrack) !AlignedTrack {
    return .{
        .track_id = track.track_id,
        .title = try owned.dupe(u8, track.title),
        .track_number = track.track_number,
        .disc_number = track.disc_number,
        .duration_ms = track.duration_ms,
    };
}

const testing = std.testing;

fn testId(comptime n: u8) []const u8 {
    return std.fmt.comptimePrint("00000000-0000-4000-8000-0000000000{x:0>2}", .{n});
}

fn releaseTrack(comptime position: u32, recording: []const u8, title: []const u8, length_ms: u64) database.ReleaseTracklistTrack {
    return .{
        .disc = 1,
        .position = position,
        .title = title,
        .artist_credit = "Kavinsky",
        .length_ms = length_ms,
        .recording_mbid = recording,
        .release_track_mbid = testId(200 + position),
    };
}

fn tracklistOf(tracks: []const database.ReleaseTracklistTrack) database.ReleaseTracklistRecord {
    return .{
        .release_mbid = testId(255),
        .title = "Nightcall",
        .artist_credit = "Kavinsky",
        .medium_count = 1,
        .fetched_at = 0,
        .tracks = tracks,
    };
}

fn localTrack(id: i64, title: []const u8, number: ?u32, duration_ms: ?i64, recording: ?[]const u8) database.ReleaseMatchTrack {
    return .{
        .track_id = id,
        .play_file = id,
        .title = title,
        .artist = "Kavinsky",
        .duration_ms = duration_ms,
        .track_number = number,
        .disc_number = null,
        .tagged_release = null,
        .recording_mbid = recording,
        .proposals = &.{},
    };
}

fn testProposal(state: database.ProposalState, recording: []const u8) database.ReleaseMatchProposal {
    return .{
        .id = 1,
        .state = state,
        .confidence = 0.9,
        .found_by = .{ .acoustid = true },
        .recording_mbid = recording,
        .in_album_group = false,
        .corrects = false,
        .payload = .{},
    };
}

test "a Track whose title and length agree with an unplaced release track is suggested with its evidence, and a lone equal title is not" {
    const release_tracks = [_]database.ReleaseTracklistTrack{
        releaseTrack(1, testId(1), "Intro", 100_000),
        releaseTrack(2, testId(2), "Nightcall", 258_000),
        releaseTrack(3, testId(3), "Outro", 150_000),
    };
    const tracklist = tracklistOf(&release_tracks);
    const tracks = [_]database.ReleaseMatchTrack{
        localTrack(1, "Intro", 1, 100_000, testId(1)),
        localTrack(2, "Nightcall", 7, 258_800, testId(20)),
        localTrack(3, "Outro", 9, 180_000, null),
    };
    const alignment = try alignRelease(testing.allocator, 1, &tracks, &tracklist, &.{});
    defer alignment.deinit();

    try testing.expectEqual(PlacementStatus.automatic, alignment.rows[0].status);
    try testing.expectEqual(@as(?RecordingSource, .in_effect), alignment.rows[0].evidence.recording_source);
    const suggestion = alignment.rows[1];
    try testing.expectEqual(PlacementStatus.suggested, suggestion.status);
    try testing.expectEqual(@as(i64, 2), suggestion.track.?.track_id);
    try testing.expect(suggestion.evidence.title_equal);
    try testing.expect(suggestion.evidence.length_close);
    try testing.expect(!suggestion.evidence.position_equal);
    try testing.expectEqual(@as(?i64, 800), suggestion.evidence.length_delta_ms);
    try testing.expectEqual(@as(?RecordingSource, null), suggestion.evidence.recording_source);
    try testing.expectEqual(PlacementStatus.not_in_files, alignment.rows[2].status);
    try testing.expectEqual(@as(?AlignedTrack, null), alignment.rows[2].track);
    try testing.expectEqual(@as(usize, 1), alignment.not_on_release.len);
    try testing.expectEqual(@as(i64, 3), alignment.not_on_release[0].track_id);
}

test "a release track missing from the files and a Track the release does not list are both shown" {
    const release_tracks = [_]database.ReleaseTracklistTrack{
        releaseTrack(1, testId(1), "Nightcall", 258_000),
        releaseTrack(2, testId(2), "Nightcall (Dustin N'Guyen remix)", 270_000),
        releaseTrack(3, testId(3), "Nightcall (Breakbot remix)", 280_000),
        releaseTrack(4, testId(4), "Nightcall (Lovefoxxx remix)", 290_000),
    };
    const tracklist = tracklistOf(&release_tracks);
    const accepted = [_]database.ReleaseMatchProposal{testProposal(.accepted, testId(1))};
    const pending = [_]database.ReleaseMatchProposal{testProposal(.pending, testId(3))};
    var tracks = [_]database.ReleaseMatchTrack{
        localTrack(1, "Nightcall", 1, 258_000, null),
        localTrack(2, "Remix", 2, 270_000, testId(2)),
        localTrack(3, "Remix", 3, 280_000, null),
        localTrack(4, "Testarossa Autodrive", null, 230_000, testId(40)),
    };
    tracks[0].proposals = &accepted;
    tracks[2].proposals = &pending;
    const alignment = try alignRelease(testing.allocator, 1, &tracks, &tracklist, &.{});
    defer alignment.deinit();

    try testing.expectEqual(@as(?RecordingSource, .accepted_match), alignment.rows[0].evidence.recording_source);
    try testing.expectEqual(@as(?RecordingSource, .in_effect), alignment.rows[1].evidence.recording_source);
    try testing.expectEqual(@as(?RecordingSource, .pending_match), alignment.rows[2].evidence.recording_source);
    for (alignment.rows[0..3], 1..) |row, id| {
        try testing.expectEqual(PlacementStatus.automatic, row.status);
        try testing.expectEqual(@as(i64, @intCast(id)), row.track.?.track_id);
    }
    try testing.expectEqual(PlacementStatus.not_in_files, alignment.rows[3].status);
    try testing.expectEqual(@as(usize, 1), alignment.not_on_release.len);
    try testing.expectEqual(@as(i64, 4), alignment.not_on_release[0].track_id);
}

test "a recording the release lists twice places a Track at its own track number, else on the first listing" {
    const release_tracks = [_]database.ReleaseTracklistTrack{
        releaseTrack(1, testId(1), "Nightcall", 258_000),
        releaseTrack(2, testId(2), "Flashback", 200_000),
        releaseTrack(3, testId(1), "Nightcall (reprise)", 258_000),
    };
    const tracklist = tracklistOf(&release_tracks);

    const numbered = [_]database.ReleaseMatchTrack{localTrack(1, "Nightcall", 3, 258_000, testId(1))};
    const at_number = try alignRelease(testing.allocator, 1, &numbered, &tracklist, &.{});
    defer at_number.deinit();
    try testing.expectEqual(PlacementStatus.not_in_files, at_number.rows[0].status);
    try testing.expectEqual(PlacementStatus.automatic, at_number.rows[2].status);

    const unnumbered = [_]database.ReleaseMatchTrack{localTrack(1, "Nightcall", null, 258_000, testId(1))};
    const first = try alignRelease(testing.allocator, 1, &unnumbered, &tracklist, &.{});
    defer first.deinit();
    try testing.expectEqual(PlacementStatus.automatic, first.rows[0].status);
    try testing.expectEqual(PlacementStatus.not_in_files, first.rows[2].status);
}

test "of two Tracks holding a recording the release lists once, the one at its track number wins, else the earlier, and the other is not on the release" {
    const release_tracks = [_]database.ReleaseTracklistTrack{
        releaseTrack(1, testId(9), "Intro", 60_000),
        releaseTrack(2, testId(1), "Nightcall", 258_000),
    };
    const tracklist = tracklistOf(&release_tracks);

    const at_number = [_]database.ReleaseMatchTrack{
        localTrack(4, "Nightcall", 1, 258_000, testId(1)),
        localTrack(10, "Nightcall", 2, 258_000, testId(1)),
    };
    const by_number = try alignRelease(testing.allocator, 1, &at_number, &tracklist, &.{});
    defer by_number.deinit();
    try testing.expectEqual(@as(i64, 10), by_number.rows[1].track.?.track_id);
    try testing.expectEqual(PlacementStatus.not_in_files, by_number.rows[0].status);
    try testing.expectEqual(@as(usize, 1), by_number.not_on_release.len);
    try testing.expectEqual(@as(i64, 4), by_number.not_on_release[0].track_id);

    const elsewhere = [_]database.ReleaseMatchTrack{
        localTrack(4, "Nightcall", 5, 258_000, testId(1)),
        localTrack(10, "Nightcall", 6, 258_000, testId(1)),
    };
    const by_order = try alignRelease(testing.allocator, 1, &elsewhere, &tracklist, &.{});
    defer by_order.deinit();
    try testing.expectEqual(@as(i64, 4), by_order.rows[1].track.?.track_id);
    try testing.expectEqual(@as(usize, 1), by_order.not_on_release.len);
    try testing.expectEqual(@as(i64, 10), by_order.not_on_release[0].track_id);
}

test "a recording ID in effect outranks an earlier Track's pending match for the same release track" {
    const release_tracks = [_]database.ReleaseTracklistTrack{releaseTrack(1, testId(1), "Nightcall", 258_000)};
    const tracklist = tracklistOf(&release_tracks);
    const pending = [_]database.ReleaseMatchProposal{testProposal(.pending, testId(1))};
    var tracks = [_]database.ReleaseMatchTrack{
        localTrack(1, "Nightcall", 1, 258_000, null),
        localTrack(2, "Nightcall", 2, 258_000, testId(1)),
    };
    tracks[0].proposals = &pending;
    const alignment = try alignRelease(testing.allocator, 1, &tracks, &tracklist, &.{});
    defer alignment.deinit();
    try testing.expectEqual(@as(i64, 2), alignment.rows[0].track.?.track_id);
    try testing.expectEqual(@as(?RecordingSource, .in_effect), alignment.rows[0].evidence.recording_source);
    try testing.expectEqual(@as(i64, 1), alignment.not_on_release[0].track_id);
}

test "a Track that two release tracks fit equally well is suggested on neither" {
    const release_tracks = [_]database.ReleaseTracklistTrack{
        releaseTrack(1, testId(1), "Nightcall", 258_000),
        releaseTrack(2, testId(2), "Nightcall", 258_500),
    };
    const tracklist = tracklistOf(&release_tracks);
    const tracks = [_]database.ReleaseMatchTrack{localTrack(1, "Nightcall", null, 258_200, null)};
    const alignment = try alignRelease(testing.allocator, 1, &tracks, &tracklist, &.{});
    defer alignment.deinit();
    try testing.expectEqual(PlacementStatus.not_in_files, alignment.rows[0].status);
    try testing.expectEqual(PlacementStatus.not_in_files, alignment.rows[1].status);
    try testing.expectEqual(@as(usize, 1), alignment.not_on_release.len);
}

fn testPairing(track_id: i64, release_track_mbid: []const u8) database.ReleaseTrackPairing {
    return .{
        .release_id = 1,
        .track_id = track_id,
        .release_mbid = testId(255),
        .release_track_mbid = release_track_mbid,
        .recording_mbid = testId(1),
        .origin = .by_hand,
        .created_at = 0,
        .in_snapshot = true,
        .disc = 1,
        .position = 1,
    };
}

test "a pairing places its Track before automatic placement, and the Track it displaces is suggested elsewhere or not on the release" {
    const release_tracks = [_]database.ReleaseTracklistTrack{
        releaseTrack(1, testId(1), "Nightcall", 258_000),
        releaseTrack(2, testId(2), "Flashback", 200_000),
    };
    const tracklist = tracklistOf(&release_tracks);
    const tracks = [_]database.ReleaseMatchTrack{
        localTrack(1, "Nightcall", 1, 258_000, testId(1)),
        localTrack(2, "Testarossa", 5, 230_000, null),
        localTrack(3, "Flashback", 2, 200_000, null),
    };
    const pairings = [_]database.ReleaseTrackPairing{testPairing(2, testId(201))};
    const alignment = try alignRelease(testing.allocator, 1, &tracks, &tracklist, &pairings);
    defer alignment.deinit();

    try testing.expectEqual(PlacementStatus.paired, alignment.rows[0].status);
    try testing.expectEqual(@as(i64, 2), alignment.rows[0].track.?.track_id);
    try testing.expectEqual(@as(?RecordingSource, null), alignment.rows[0].evidence.recording_source);
    try testing.expect(!alignment.rows[0].evidence.title_equal);
    try testing.expectEqual(@as(?i64, -28_000), alignment.rows[0].evidence.length_delta_ms);
    try testing.expectEqual(PlacementStatus.suggested, alignment.rows[1].status);
    try testing.expectEqual(@as(i64, 3), alignment.rows[1].track.?.track_id);
    try testing.expectEqual(@as(usize, 1), alignment.not_on_release.len);
    try testing.expectEqual(@as(i64, 1), alignment.not_on_release[0].track_id);
}

test "a pairing on a release track the snapshot no longer lists, or on another release, is ignored" {
    const release_tracks = [_]database.ReleaseTracklistTrack{releaseTrack(1, testId(1), "Nightcall", 258_000)};
    const tracklist = tracklistOf(&release_tracks);
    const tracks = [_]database.ReleaseMatchTrack{localTrack(1, "Nightcall", 1, 258_000, testId(1))};
    var elsewhere = testPairing(1, testId(201));
    elsewhere.release_mbid = testId(254);
    const pairings = [_]database.ReleaseTrackPairing{ testPairing(1, testId(209)), elsewhere };
    const alignment = try alignRelease(testing.allocator, 1, &tracks, &tracklist, &pairings);
    defer alignment.deinit();
    try testing.expectEqual(PlacementStatus.automatic, alignment.rows[0].status);
}
