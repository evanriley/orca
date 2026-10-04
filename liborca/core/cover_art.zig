//! A Release's front cover from the Cover Art Archive, fetched only when none
//! of its files carries one and its folder holds no front cover image, and
//! kept in the Library. Media files are never written.

const std = @import("std");
const artwork = @import("artwork.zig");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");

const coverartarchive = providers.coverartarchive;

/// What fetching a Release's cover came to.
pub const Outcome = enum(u8) {
    /// The job was not asked to fetch a cover.
    not_requested,
    /// A file of the Release carries a cover, so nothing was fetched.
    embedded,
    fetched,
    /// A cover fetched earlier for the same release ID is kept.
    cached,
    /// The archive had no cover less than `retry_missing_after_s` ago.
    cached_miss,
    /// The archive has no front cover for the release.
    not_found,
    /// Neither a tag nor an accepted match gives the Release a MusicBrainz
    /// release ID.
    no_release_id,
    /// The archive's answer was refused: a redirect off the archive, another
    /// `4xx`, or a body that is not a JPEG or PNG of at most 4 MiB.
    refused,
    unavailable,
    /// Another Orca process holds the Cover Art Archive.
    busy,
    cancelled,
    /// A front cover image in the Release's folder is shown before a fetched
    /// one, so nothing was fetched.
    folder,
};

/// How long the archive's "no cover" stands before it is asked again.
pub const retry_missing_after_s: i64 = 30 * 24 * 60 * 60;

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: *database.LibraryDatabase,
    archive: *coverartarchive.CoverArtArchive,
    /// Unix time in milliseconds.
    wall_clock: network.client.Clock,

    pub fn run(self: *Fetch, release_id: i64) !Outcome {
        if (try artwork.releaseEmbeddedArtwork(self.allocator, self.io, self.library, release_id)) |image| {
            image.deinit();
            return .embedded;
        }
        if (try artwork.releaseFolderArtwork(self.allocator, self.io, self.library, release_id)) |image| {
            image.deinit();
            return .folder;
        }
        const release_mbid = try self.library.release_artwork.coverReleaseMbid(self.allocator, release_id) orelse
            return .no_release_id;
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        if (try self.library.release_artwork.get(release_id)) |stored| {
            if (std.mem.eql(u8, &stored.musicbrainz_release_id, &release_mbid)) {
                if (stored.has_image) return .cached;
                if (now_s - stored.fetched_at < retry_missing_after_s) return .cached_miss;
            }
        }
        const cover = self.archive.frontCover(self.allocator, &release_mbid) catch |err| return switch (err) {
            error.Canceled => .cancelled,
            error.ProviderBusy => .busy,
            error.NetworkUnavailable, error.Offline, error.Timeout, error.RateLimited, error.ProviderUnavailable => .unavailable,
            error.RedirectRefused, error.ProviderRejectedRequest, error.InvalidProviderResponse, error.ResponseTooLarge => .refused,
            else => err,
        };
        switch (cover) {
            .missing => {
                try self.library.release_artwork.put(release_id, &release_mbid, null, now_s);
                return .not_found;
            },
            .image => |image| {
                defer self.allocator.free(image.bytes);
                try self.library.release_artwork.put(release_id, &release_mbid, .{
                    .bytes = image.bytes,
                    .mime_type = image.mime_type,
                }, now_s);
                return .fetched;
            },
        }
    }
};
