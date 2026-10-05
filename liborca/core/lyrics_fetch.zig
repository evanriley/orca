const std = @import("std");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");

const lrclib = providers.lrclib;
const Lyrics = metadata.lyrics.Lyrics;
const LyricsRecord = database.LyricsRecord;

/// Where a lyrics job found a Track's lyrics, or why it found none. A Track
/// that does not exist, or has no file and nothing cached, is `not_found`.
///
/// When the job fetches, the outcome is what the fetch came to, even when
/// the Track's own plain lyrics outrank LRCLIB's and are the ones returned.
pub const Outcome = enum(u8) {
    local,
    fetched,
    /// LRCLIB's answer to the same query, kept from an earlier job.
    cached,
    /// LRCLIB had nothing for the same query less than
    /// `retry_missing_after_s` ago.
    cached_miss,
    not_found,
    /// The Track has no title or no artist to ask LRCLIB with.
    no_metadata,
    /// LRCLIB's answer was refused: a `4xx` other than `404`, a redirect, or
    /// a body that is not a record of at most 512 KiB.
    refused,
    unavailable,
    /// Another Orca process holds LRCLIB.
    busy,
    cancelled,
    not_requested,
};

pub const Result = struct {
    outcome: Outcome,
    lyrics: ?Lyrics,
};

pub const retry_missing_after_s: i64 = 7 * 24 * 60 * 60;
pub const fetch_deadline_ms: i64 = 60_000;

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: *database.LibraryDatabase,
    lrclib: ?*lrclib.Lrclib = null,
    wall_clock: ?network.client.Clock = null,

    pub fn run(self: *Fetch, track_id: i64) !Result {
        const local = try library_pass.lyrics_lookup.trackLyrics(self.allocator, self.io, self.library, track_id);
        errdefer if (local) |found| found.deinit();
        if (local) |found| if (found.kind == .synced) return .{ .outcome = .local, .lyrics = found };

        const summary = try self.library.tracks.byId(self.allocator, track_id) orelse
            return localOr(local, .not_found);
        defer summary.deinit(self.allocator);
        const title = std.mem.trim(u8, summary.title, " \t");
        const artist = std.mem.trim(u8, summary.artist, " \t");
        if (title.len == 0 or artist.len == 0)
            return localOr(local, if (self.lrclib == null) .not_found else .no_metadata);
        const query: lrclib.Query = .init(title, artist, std.mem.trim(u8, summary.album, " \t"), summary.duration_ms);
        const digest = query.digest();

        const stored = try self.library.track_lyrics.get(self.allocator, track_id);
        defer if (stored) |row| row.deinit();
        const current = if (stored) |row| if (std.mem.eql(u8, &row.query_digest, &digest)) row else null else null;

        const archive = self.lrclib orelse {
            if (current) |row| if (!row.record.isMiss()) {
                const picked = try self.pick(local, row.record);
                return .{ .outcome = if (picked.local) .local else .cached, .lyrics = picked.lyrics };
            };
            return localOr(local, .not_found);
        };
        const now_s = @divFloor(self.wall_clock.?.nowMs(), 1000);
        if (current) |row| {
            if (!row.record.isMiss()) return .{ .outcome = .cached, .lyrics = (try self.pick(local, row.record)).lyrics };
            if (now_s - row.fetched_at < retry_missing_after_s) return .{ .outcome = .cached_miss, .lyrics = local };
        }
        const answer = archive.get(self.allocator, query) catch |err| {
            const outcome: Outcome = switch (err) {
                error.Canceled => .cancelled,
                error.ProviderBusy => .busy,
                error.NetworkUnavailable, error.Offline, error.Timeout, error.RateLimited, error.ProviderUnavailable => .unavailable,
                error.RedirectRefused, error.ProviderRejectedRequest, error.InvalidProviderResponse, error.ResponseTooLarge => .refused,
                else => return err,
            };
            return .{ .outcome = outcome, .lyrics = local };
        };
        var fetched: LyricsRecord = .{};
        defer switch (answer) {
            .found => |record| record.deinit(),
            .missing => {},
        };
        switch (answer) {
            .found => |record| fetched = .{
                .lrclib_id = record.id(),
                .synced = record.synced(),
                .plain = record.plain(),
                .instrumental = record.instrumental(),
            },
            .missing => {},
        }
        if (!try self.library.track_lyrics.put(track_id, &digest, fetched, now_s)) {
            if (local) |found| found.deinit();
            return .{ .outcome = .not_found, .lyrics = null };
        }
        if (fetched.isMiss()) return .{ .outcome = .not_found, .lyrics = local };
        return .{ .outcome = .fetched, .lyrics = (try self.pick(local, fetched)).lyrics };
    }

    const Picked = struct {
        lyrics: ?Lyrics,
        local: bool,
    };

    /// The better of `local`, which is not synced, and `record`. Whichever is
    /// not returned is freed.
    fn pick(self: *Fetch, local: ?Lyrics, record: LyricsRecord) !Picked {
        if (record.synced) |text| if (try metadata.lyrics.parse(self.allocator, text, .lrclib)) |remote| {
            if (remote.kind == .synced or local == null) {
                if (local) |found| found.deinit();
                return .{ .lyrics = remote, .local = false };
            }
            remote.deinit();
        };
        if (local) |found| return .{ .lyrics = found, .local = true };
        if (record.plain) |text| if (try metadata.lyrics.parse(self.allocator, text, .lrclib)) |remote|
            return .{ .lyrics = remote, .local = false };
        if (record.instrumental) return .{ .lyrics = try metadata.lyrics.instrumental(self.allocator, .lrclib), .local = false };
        return .{ .lyrics = null, .local = false };
    }
};

fn localOr(local: ?Lyrics, outcome: Outcome) Result {
    return .{ .outcome = if (local != null) .local else outcome, .lyrics = local };
}
