//! A Release's front cover from the Cover Art Archive, fetched only when none
//! of its files carries one and its folder holds no front cover image, and
//! kept in the Library. Media files are never written.
//!
//! A person can also list the archive's images for a Release as candidates
//! and use one as its front, back or booklet cover.

const std = @import("std");
const artwork = @import("artwork.zig");
const database = @import("../database/root.zig");
const image_header = @import("../metadata/image_header.zig");
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
    /// A person chose the Release's front cover, so nothing was fetched.
    chosen,
    /// Candidates were stored from the release's index, but the release
    /// group's index could not be read.
    partial,
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
        if (try self.library.release_artwork.hasChosenFront(release_id)) return .chosen;
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
        const cover = self.archive.frontCover(self.allocator, &release_mbid) catch |err| return outcomeOf(err);
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

fn outcomeOf(err: anyerror) anyerror!Outcome {
    return switch (err) {
        error.Canceled => .cancelled,
        error.ProviderBusy => .busy,
        error.NetworkUnavailable, error.Offline, error.Timeout, error.RateLimited, error.ProviderUnavailable => .unavailable,
        error.RedirectRefused, error.ProviderRejectedRequest, error.InvalidProviderResponse, error.ResponseTooLarge => .refused,
        else => err,
    };
}

/// A candidates fetch's progress, counted in candidates. Written by the
/// fetch, read by any thread.
pub const CandidateProgress = struct {
    /// Candidates whose image and thumbnail were asked for.
    examined: std.atomic.Value(u64) = .init(0),
    /// Zero until the indexes are read.
    total: std.atomic.Value(u64) = .init(0),
    /// Candidates whose full image could not be fetched or measured, kept
    /// without a size.
    unmeasured: std.atomic.Value(u64) = .init(0),
};

/// Lists the archive's images for a Release and stores up to
/// `max_cover_art_candidates` of them with their sizes and thumbnails: its
/// release's index, then its release group's when its files name exactly
/// one. Each candidate's full image is fetched to measure it and then
/// dropped; only the thumbnail is kept.
pub const Candidates = struct {
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    archive: *coverartarchive.CoverArtArchive,
    /// Unix time in milliseconds.
    wall_clock: network.client.Clock,
    progress: *CandidateProgress,

    /// `.fetched` when at least one candidate was stored, `.not_found` when
    /// the archive holds no image for the Release, and `.partial` when the
    /// release's candidates were stored but its release group's index would
    /// not come.
    pub fn run(self: *Candidates, release_id: i64) !Outcome {
        const release_mbid = try self.library.release_artwork.coverReleaseMbid(self.allocator, release_id);
        const group_mbid = try self.library.release_artwork.coverReleaseGroupMbid(release_id);
        if (release_mbid == null and group_mbid == null) return .no_release_id;

        var found: std.ArrayList(Found) = .empty;
        defer found.deinit(self.allocator);
        if (release_mbid) |mbid| {
            const listed = self.archive.releaseIndex(self.allocator, &mbid) catch |err| return outcomeOf(err);
            if (listed) |index| {
                defer index.deinit(self.allocator);
                for (index.images) |indexed| try appendUnique(self.allocator, &found, .{
                    .caa_id = indexed.id,
                    .release_mbid = mbid,
                    .kind = candidateKind(indexed.kind),
                    .approved = indexed.approved,
                });
            }
        }
        var group_missing = false;
        if (group_mbid) |mbid| group: {
            const listed = self.archive.releaseGroupIndex(self.allocator, &mbid) catch |err| {
                const outcome = try outcomeOf(err);
                if (outcome == .cancelled or found.items.len == 0) return outcome;
                group_missing = true;
                break :group;
            };
            if (listed) |index| {
                defer index.deinit(self.allocator);
                for (index.images) |indexed| {
                    if (indexed.kind != .front) continue;
                    try appendUnique(self.allocator, &found, .{
                        .caa_id = indexed.id,
                        .release_mbid = index.release_mbid,
                        .kind = .release_group,
                        .approved = indexed.approved,
                    });
                }
            }
        }
        std.sort.insertion(Found, found.items, {}, Found.before);
        const chosen = found.items[0..@min(found.items.len, database.repository.max_cover_art_candidates)];
        self.progress.total.store(chosen.len, .release);

        var inputs: [database.repository.max_cover_art_candidates]database.CoverArtCandidateInput = undefined;
        var thumbnails: [database.repository.max_cover_art_candidates]?[]u8 = @splat(null);
        defer for (thumbnails) |thumbnail| if (thumbnail) |bytes| self.allocator.free(bytes);
        for (chosen, 0..) |candidate, at| {
            inputs[at] = .{
                .caa_id = candidate.caa_id,
                .musicbrainz_release_id = &chosen[at].release_mbid,
                .kind = candidate.kind,
                .approved = candidate.approved,
            };
            const full = self.measure(candidate) catch |err| switch (err) {
                error.Canceled => return .cancelled,
                else => return err,
            };
            if (full) |measured| {
                inputs[at].width = measured.width;
                inputs[at].height = measured.height;
                inputs[at].mime = measured.mime_type;
            } else {
                _ = self.progress.unmeasured.fetchAdd(1, .acq_rel);
            }
            const small = self.archive.thumbnail(self.allocator, &candidate.release_mbid, candidate.caa_id) catch |err| switch (err) {
                error.Canceled => return .cancelled,
                error.OutOfMemory => return err,
                else => coverartarchive.FrontCover.missing,
            };
            switch (small) {
                .image => |thumbnail| {
                    thumbnails[at] = thumbnail.bytes;
                    inputs[at].thumbnail = thumbnail.bytes;
                },
                .missing => {},
            }
            _ = self.progress.examined.fetchAdd(1, .acq_rel);
        }
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        try self.library.release_artwork.replaceCandidates(release_id, inputs[0..chosen.len], now_s);
        if (group_missing) return .partial;
        return if (chosen.len == 0) .not_found else .fetched;
    }

    const Measured = struct { width: ?u32, height: ?u32, mime_type: []const u8 };

    /// Null when the full image would not come, or is too large to hold.
    fn measure(self: *Candidates, candidate: Found) !?Measured {
        const full = self.archive.image(self.allocator, &candidate.release_mbid, candidate.caa_id) catch |err| switch (err) {
            error.Canceled => return err,
            error.OutOfMemory => return err,
            else => return null,
        };
        switch (full) {
            .missing => return null,
            .image => |image| {
                defer self.allocator.free(image.bytes);
                const measured = image_header.measure(image.bytes);
                return .{ .width = measured.width, .height = measured.height, .mime_type = image.mime_type };
            },
        }
    }
};

const Found = struct {
    caa_id: i64,
    release_mbid: [36]u8,
    kind: database.CoverArtCandidateKind,
    approved: bool,

    fn rank(self: Found) u8 {
        return switch (self.kind) {
            .front => 0,
            .release_group => 1,
            .back => 2,
            .booklet => 3,
            .other => 4,
        };
    }

    fn before(_: void, a: Found, b: Found) bool {
        if (a.rank() != b.rank()) return a.rank() < b.rank();
        return a.caa_id < b.caa_id;
    }
};

fn appendUnique(allocator: std.mem.Allocator, found: *std.ArrayList(Found), candidate: Found) !void {
    for (found.items) |existing| if (existing.caa_id == candidate.caa_id) return;
    try found.append(allocator, candidate);
}

fn candidateKind(kind: coverartarchive.ImageKind) database.CoverArtCandidateKind {
    return switch (kind) {
        .front => .front,
        .back => .back,
        .booklet => .booklet,
        .other => .other,
    };
}

/// Fetches one stored candidate's full image and keeps it as a cover the
/// person chose.
pub const Use = struct {
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    archive: *coverartarchive.CoverArtArchive,
    /// Unix time in milliseconds.
    wall_clock: network.client.Clock,

    /// `.not_found` when the Release no longer lists the candidate or the
    /// archive no longer holds the image.
    pub fn run(self: *Use, release_id: i64, caa_id: i64, kind: database.ReleaseArtworkKind) !Outcome {
        const release_mbid = try self.library.release_artwork.candidateRelease(release_id, caa_id) orelse return .not_found;
        const full = self.archive.image(self.allocator, &release_mbid, caa_id) catch |err| return outcomeOf(err);
        switch (full) {
            .missing => return .not_found,
            .image => |image| {
                defer self.allocator.free(image.bytes);
                const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
                try self.library.release_artwork.set(release_id, kind, image.bytes, image.mime_type, &release_mbid, now_s);
                return .fetched;
            },
        }
    }
};
