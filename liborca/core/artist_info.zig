//! An Artist's photo, biography, origin, years active, links and
//! MusicBrainz release groups: a local image from the Artist's folder, then
//! MusicBrainz, Wikidata, Wikimedia Commons and Wikipedia; its listeners
//! from ListenBrainz and related artists from ListenBrainz Labs; and, unless
//! turned off, MusicBrainz genres for its Tracks that have none. Kept in the
//! Library; no media file is written.

const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");

const wikidata = providers.wikidata;
const wikimedia_commons = providers.wikimedia_commons;
const wikipedia = providers.wikipedia;
const listenbrainz_labs = providers.listenbrainz_labs;
const release_info = @import("release_info.zig");
const cover_art = @import("cover_art.zig");
const CachedGet = providers.cached_get.CachedGet;
const MusicBrainz = providers.musicbrainz.MusicBrainz;
const CoverArtArchive = providers.coverartarchive.CoverArtArchive;
const ArtistInfoRecord = database.ArtistInfoRecord;
const ArtistLink = database.ArtistLink;

/// What fetching an Artist's info came to: the first step that failed, else
/// how the info was found. Stored by number in `artist_info.outcome`;
/// append only.
pub const Outcome = enum(u8) {
    /// The job has not finished.
    not_requested = 0,
    fetched = 1,
    /// Info fetched less than `refresh_after_s` ago for the same MusicBrainz
    /// artist ID and requested language is kept, and nothing was asked.
    cached = 2,
    /// The Artist has no MusicBrainz artist ID, so only a local image was
    /// looked for.
    no_musicbrainz_id = 3,
    /// Offline: only the local image and answers already cached were used.
    offline = 4,
    /// There is no such Artist.
    not_found = 5,
    /// A service's answer was refused: a `4xx`, a redirect off the service,
    /// or a body Orca does not accept.
    refused = 6,
    unavailable = 7,
    /// Another Orca process holds one of the services.
    busy = 8,
    cancelled = 9,
};

pub const Options = struct {
    /// The Wikipedia whose article is the biography, falling back to
    /// English: a language code such as `en`, `de` or `zh-yue`.
    language: []const u8 = "en",
    /// Fetch again even when the stored info is recent, and prefer a
    /// Commons photo to a local image.
    force: bool = false,
    /// Make no request; use the local image and answers already cached.
    offline: bool = false,
    /// Then fetch the info of each of the Artist's Releases with a
    /// MusicBrainz release ID, at most `database.artist_releases_max`.
    include_releases: bool = false,
};

/// How long ListenBrainz listeners and related artists are kept.
pub const listenbrainz_refresh_after_s: i64 = 7 * 24 * 60 * 60;

/// How long fetched info is kept before a fetch asks again. A related
/// artist's photo, or the marker that it has none, is kept as long.
pub const refresh_after_s: i64 = 30 * 24 * 60 * 60;
/// At most this many related artists outside the Library have their photo
/// looked for in one fetch.
pub const related_photos_per_fetch = 8;
/// Only the first this many release groups Elsewhere lists have their cover
/// asked for.
pub const release_group_covers_per_fetch = 24;
/// The most area lookups one fetch makes to name the area an origin lies in.
pub const max_origin_area_lookups = 3;
/// The largest local image read from an Artist's folder.
pub const max_local_image_bytes: usize = 8 * 1024 * 1024;
/// Looked for in this order in the Artist's folder.
pub const local_image_names = [_][]const u8{ "artist.jpg", "artist.png", "folder.jpg", "thumb.jpg", "fanart.jpg" };

pub const Services = struct {
    musicbrainz: *MusicBrainz,
    wikidata: *CachedGet,
    wikidata_server: []const u8,
    commons: *CachedGet,
    commons_server: []const u8,
    /// Null asks `https://{language}.wikipedia.org`.
    wikipedia: *CachedGet,
    wikipedia_server: ?[]const u8,
    listenbrainz: *network.Gateway,
    listenbrainz_server: []const u8,
    labs: *CachedGet,
    labs_server: []const u8,
    coverartarchive: *CoverArtArchive,
};

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    library: *database.LibraryDatabase,
    services: Services,
    /// Unix time in milliseconds.
    wall_clock: network.client.Clock,
    language: []const u8 = "en",
    force: bool = false,
    /// Ask no release group cover; the gateways answer only from caches.
    offline: bool = false,
    include_releases: bool = false,

    pub fn run(self: *Fetch, artist_id: i64) !Outcome {
        const info = &self.library.artist_info;
        const subject = try info.subject(artist_id) orelse return .not_found;
        const mbid: ?[]const u8 = if (subject.musicbrainz_artist_id) |*id| id else null;
        var stored = try info.get(self.allocator, artist_id);
        defer if (stored) |*row| row.deinit();
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();

        var genres: ?[]const providers.musicbrainz.Genre = null;
        const outcome = try self.fetchInfo(scratch.allocator(), artist_id, mbid, if (stored) |*row| &row.record else null, now_s, &genres);
        if (outcome == .cancelled) return .cancelled;
        var failure: ?Outcome = switch (outcome) {
            .fetched, .cached, .no_musicbrainz_id => null,
            else => outcome,
        };
        if (genres) |found| if (found.len != 0 and try self.library.settings.flag(database.setting_genre_fill_musicbrainz, true)) {
            var buffer: [providers.musicbrainz.fill_genres_max][]const u8 = undefined;
            _ = try self.library.genres.fillFromProvider(self.allocator, .{ .artist = artist_id }, providers.musicbrainz.topGenres(found, &buffer));
        };
        if (mbid) |artist_mbid| {
            const listened_at = if (stored) |row| row.record.listeners_fetched_at else null;
            if (try self.refreshListenBrainz(artist_id, artist_mbid, listened_at, now_s)) |lb_failure| {
                if (lb_failure == .cancelled) return .cancelled;
                failure = failure orelse lb_failure;
            }
        }
        if (!try self.fetchRelatedPhotos(artist_id, now_s)) return .cancelled;
        if (!try self.fetchReleaseGroupCovers(artist_id, now_s)) return .cancelled;
        if (self.include_releases) {
            const releases = try self.library.release_info.artistReleases(self.allocator, artist_id);
            defer self.allocator.free(releases);
            var release_fetch: release_info.Fetch = .{
                .allocator = self.allocator,
                .library = self.library,
                .services = self.services,
                .wall_clock = self.wall_clock,
                .language = self.language,
                .force = self.force,
            };
            for (releases) |release_id| {
                const release_outcome = try release_fetch.run(release_id);
                switch (release_outcome) {
                    .fetched, .cached, .no_musicbrainz_id, .not_found => {},
                    .cancelled => return .cancelled,
                    else => failure = failure orelse release_outcome,
                }
            }
        }
        return failure orelse outcome;
    }

    /// Listeners from ListenBrainz and related artists from Labs, unless
    /// both were refreshed less than `listenbrainz_refresh_after_s` ago. A
    /// step that fails leaves what it would have written; the refresh time
    /// moves only when both succeed. Returns the first failure.
    fn refreshListenBrainz(self: *Fetch, artist_id: i64, artist_mbid: []const u8, fetched_at: ?i64, now_s: i64) !?Outcome {
        if (!self.force) if (fetched_at) |at| if (now_s - at < listenbrainz_refresh_after_s) return null;
        var progress: Progress = .{};
        var update: database.ArtistListenBrainzUpdate = .{};
        if (progress.step(try lookUp(providers.listenbrainz.artistListeners(
            self.services.listenbrainz,
            self.allocator,
            self.services.listenbrainz_server,
            artist_mbid,
        )))) |listeners| update.listeners = if (listeners) |count| .{ .count = count } else .unknown;
        if (progress.cancelled) return .cancelled;
        var similar = progress.step(try lookUp(listenbrainz_labs.similarArtists(
            self.services.labs,
            self.allocator,
            self.services.labs_server,
            artist_mbid,
        )));
        defer if (similar) |*maybe| if (maybe.*) |*found| found.deinit();
        if (progress.cancelled) return .cancelled;
        var records: [listenbrainz_labs.max_similar]database.RelatedArtistRecord = undefined;
        if (similar) |maybe| {
            const items = if (maybe) |found| found.items else &.{};
            for (items, records[0..items.len]) |item, *record|
                record.* = .{ .mbid = item.mbid, .name = item.name, .score = item.score };
            update.related = records[0..items.len];
        }
        if (progress.failure == null) update.fetched_at = now_s;
        _ = try self.library.artist_info.storeListenBrainz(artist_id, update);
        return progress.failure;
    }

    /// Photos for the first `related_photos_per_fetch` related artists
    /// outside the Library with none kept, nor a marker that they have none,
    /// newer than `refresh_after_s`; with `force`, for the first that many
    /// outside it. An artist whose lookup fails keeps what it had and does
    /// not fail the fetch. False when cancelled.
    fn fetchRelatedPhotos(self: *Fetch, artist_id: i64, now_s: i64) !bool {
        const info = &self.library.artist_info;
        var related = try info.related(self.allocator, artist_id);
        defer related.deinit();
        var looked: usize = 0;
        for (related.items) |artist| {
            if (looked == related_photos_per_fetch) break;
            if (artist.library_artist_id != null) continue;
            if (!self.force) if (try info.relatedPhotoFetchedAt(artist.mbid)) |at|
                if (now_s - at < refresh_after_s) continue;
            looked += 1;
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            switch (try self.relatedPhoto(scratch.allocator(), artist.mbid)) {
                .cancelled => return false,
                .unknown => {},
                .none => try info.storeRelatedPhoto(artist.mbid, null, now_s),
                .some => |found| {
                    defer self.allocator.free(found.image.bytes);
                    try info.storeRelatedPhoto(artist.mbid, &.{
                        .image = .{ .bytes = found.image.bytes, .mime_type = found.image.mime_type },
                        .record = .{
                            .source = .commons,
                            .url = found.details.page_url,
                            .licence = found.details.licence,
                            .licence_url = found.details.licence_url,
                            .credit = found.details.credit,
                        },
                    }, now_s);
                },
            }
        }
        return true;
    }

    /// Front covers from the Cover Art Archive for the first
    /// `release_group_covers_per_fetch` groups Elsewhere lists, skipping a
    /// group whose cover is kept or that was found to have none less than
    /// `cover_art.retry_missing_after_s` ago. A refusal is kept as none; an
    /// unavailable or busy archive ends the step. Neither fails the fetch.
    /// False when cancelled.
    fn fetchReleaseGroupCovers(self: *Fetch, artist_id: i64, now_s: i64) !bool {
        if (self.offline) return true;
        const info = &self.library.artist_info;
        const groups = try info.elsewhere(self.allocator, artist_id);
        defer {
            for (groups) |group| group.deinit(self.allocator);
            self.allocator.free(groups);
        }
        for (groups[0..@min(groups.len, release_group_covers_per_fetch)]) |group| {
            if (!metadata.isMusicBrainzId(group.mbid)) continue;
            if (try info.releaseGroupCoverMark(group.mbid)) |mark|
                if (mark.has_image or now_s - mark.fetched_at < cover_art.retry_missing_after_s) continue;
            switch (try lookUp(self.services.coverartarchive.releaseGroupFrontCover(self.allocator, group.mbid))) {
                .value => |cover| switch (cover) {
                    .missing => try info.storeReleaseGroupCover(group.mbid, null, now_s),
                    .image => |image| {
                        defer self.allocator.free(image.bytes);
                        try info.storeReleaseGroupCover(group.mbid, .{ .bytes = image.bytes, .mime_type = image.mime_type }, now_s);
                    },
                },
                .failed => |outcome| switch (outcome) {
                    .cancelled => return false,
                    .refused => try info.storeReleaseGroupCover(group.mbid, null, now_s),
                    else => return true,
                },
            }
        }
        return true;
    }

    /// The origin as its name and the subdivision it lies in, such as
    /// `Portland, Oregon`, else the country; the name alone when the area is
    /// itself a subdivision or country, or nothing containing it is found
    /// within `max_origin_area_lookups` lookups.
    fn resolveOrigin(self: *Fetch, arena: std.mem.Allocator, progress: *Progress, artist: *const providers.musicbrainz.ArtistLookup) !?[]const u8 {
        const name = artist.origin orelse return null;
        if (isTopArea(artist.origin_area_type)) return name;
        var area_id = artist.origin_area_id orelse return name;
        for (0..max_origin_area_lookups) |looked| {
            const area = progress.step(try lookUp(self.services.musicbrainz.lookUpArea(arena, area_id))) orelse return name;
            if (looked == 0 and isTopArea(area.area.type)) return name;
            const parent = containingArea(area.parents) orelse return name;
            if (isTopArea(parent.type)) return try std.fmt.allocPrint(arena, "{s}, {s}", .{ name, parent.name });
            area_id = parent.id;
        }
        return name;
    }

    const RelatedPhoto = union(enum) {
        /// A step failed in a way that may pass, so nothing is kept.
        unknown,
        /// The artist has no photo, or a service refused to say.
        none,
        /// The image's bytes are the caller's to free; the details live in
        /// the arena passed to `relatedPhoto`.
        some: struct { image: wikimedia_commons.Image, details: PhotoDetails },
        cancelled,
    };

    /// As `fetchInfo` finds a photo: the Commons file Wikidata's P18 names,
    /// else the one MusicBrainz's image relationship names.
    fn relatedPhoto(self: *Fetch, arena: std.mem.Allocator, mbid: []const u8) !RelatedPhoto {
        const artist = switch (try lookUp(self.services.musicbrainz.lookUpArtist(arena, mbid))) {
            .value => |value| value,
            .failed => |outcome| return relatedPhotoFailure(outcome),
        };
        var commons_file = artist.commons_image_file;
        if (artist.wikidata_id) |item_id| {
            switch (try lookUp(wikidata.entity(
                self.services.wikidata,
                arena,
                self.services.wikidata_server,
                item_id,
                self.language,
            ))) {
                .value => |maybe_entity| if (maybe_entity) |entity| if (entity.image_file) |file| {
                    commons_file = file;
                },
                .failed => |outcome| if (commons_file == null or outcome == .cancelled)
                    return relatedPhotoFailure(outcome),
            }
        }
        const file = commons_file orelse return .none;
        const image_info = switch (try lookUp(wikimedia_commons.imageInfo(
            self.services.commons,
            arena,
            self.services.commons_server,
            file,
        ))) {
            .value => |maybe_info| maybe_info orelse return .none,
            .failed => |outcome| return relatedPhotoFailure(outcome),
        };
        return switch (try lookUp(wikimedia_commons.fetchImage(
            self.services.commons.gateway,
            self.allocator,
            self.services.commons_server,
            image_info.thumbnail_url,
        ))) {
            .value => |image| .{ .some = .{ .image = image, .details = commonsPhotoDetails(&image_info) } },
            .failed => |outcome| relatedPhotoFailure(outcome),
        };
    }

    fn relatedPhotoFailure(outcome: Outcome) RelatedPhoto {
        return switch (outcome) {
            .cancelled => .cancelled,
            .refused => .none,
            else => .unknown,
        };
    }

    fn fetchInfo(
        self: *Fetch,
        arena: std.mem.Allocator,
        artist_id: i64,
        mbid: ?[]const u8,
        stored: ?*const ArtistInfoRecord,
        now_s: i64,
        genres: *?[]const providers.musicbrainz.Genre,
    ) !Outcome {
        const info = &self.library.artist_info;
        if (!self.force) if (stored) |row| if (self.isCurrent(row, mbid, now_s)) return .cached;

        var record: ArtistInfoRecord = .{};
        const same_artist = if (stored) |row| std.mem.eql(u8, row.musicbrainz_artist_id orelse "", mbid orelse "") else false;
        if (stored) |row| {
            if (same_artist) {
                record = row.*;
            } else setPhotoDetails(&record, row.photo_source, .{
                .page_url = row.photo_url,
                .licence = row.photo_licence,
                .licence_url = row.photo_licence_url,
                .credit = row.photo_credit,
            });
        }
        record.musicbrainz_artist_id = mbid;
        record.requested_language = self.language;
        record.fetched_at = now_s;
        var progress: Progress = .{};
        var photo: database.ArtistPhotoChange = .keep;

        const local = try self.localImage(artist_id);
        defer if (local) |image| image.deinit();
        if (local) |image| {
            photo = .{ .set = .{ .bytes = image.bytes, .mime_type = image.mime_type } };
            setPhotoDetails(&record, .local, .{});
        } else if (record.photo_source == .local) {
            photo = .clear;
            setPhotoDetails(&record, null, .{});
        }

        const artist_mbid = mbid orelse {
            record.outcome = @intFromEnum(Outcome.no_musicbrainz_id);
            try info.storeReleaseGroups(artist_id, &.{});
            try info.store(artist_id, &record, photo, null);
            return .no_musicbrainz_id;
        };

        var links: ?std.ArrayList(ArtistLink) = null;
        var life_span: ?LifeSpan = null;
        var work_period: WorkPeriod = .{};
        var commons_file: Known([]const u8) = .unknown;
        var article: Known(Article) = .unknown;
        if (progress.step(try lookUp(self.services.musicbrainz.lookUpArtist(arena, artist_mbid)))) |artist| {
            record.artist_type = artist.artist_type;
            life_span = .{ .begin_year = artist.begin_year, .end_year = artist.end_year, .ended = artist.ended };
            record.wikidata_id = artist.wikidata_id;
            record.origin = try self.resolveOrigin(arena, &progress, &artist);
            genres.* = artist.genres;
            commons_file = .from(artist.commons_image_file);
            if (artist.wikidata_id == null) article = .none;
            var found: std.ArrayList(ArtistLink) = .empty;
            try found.appendSlice(arena, artist.links);
            try found.append(arena, .{
                .kind = .musicbrainz,
                .url = try std.fmt.allocPrint(arena, "https://musicbrainz.org/artist/{s}", .{artist_mbid}),
            });
            links = found;
        }
        if (progress.cancelled) return .cancelled;

        if (record.wikidata_id) |item_id| {
            const found = progress.step(try lookUp(wikidata.entity(
                self.services.wikidata,
                arena,
                self.services.wikidata_server,
                item_id,
                self.language,
            )));
            if (progress.cancelled) return .cancelled;
            if (found) |maybe_entity| {
                article = .none;
                if (maybe_entity) |entity| {
                    work_period = .{ .start_year = entity.work_start_year, .end_year = entity.work_end_year };
                    if (entity.image_file) |file| commons_file = .{ .some = file };
                    if (entity.article_title) |title|
                        article = .{ .some = .{ .title = title, .language = entity.article_language.? } };
                }
            } else if (commons_file == .none) commons_file = .unknown;
        }
        if (life_span) |span| try self.setYearsActive(&record, artist_id, span, work_period);

        var commons_image: ?wikimedia_commons.Image = null;
        defer if (commons_image) |image| self.allocator.free(image.bytes);
        if (local == null or self.force) switch (commons_file) {
            .none => if (local == null and record.photo_source != null) {
                photo = .clear;
                setPhotoDetails(&record, null, .{});
            },
            .unknown => {},
            .some => |file| {
                const described = progress.step(try lookUp(wikimedia_commons.imageInfo(
                    self.services.commons,
                    arena,
                    self.services.commons_server,
                    file,
                )));
                if (described) |maybe_image| if (maybe_image) |image_info| {
                    if (progress.step(try lookUp(wikimedia_commons.fetchImage(
                        self.services.commons.gateway,
                        self.allocator,
                        self.services.commons_server,
                        image_info.thumbnail_url,
                    )))) |image| {
                        commons_image = image;
                        photo = .{ .set = .{ .bytes = image.bytes, .mime_type = image.mime_type } };
                        setPhotoDetails(&record, .commons, commonsPhotoDetails(&image_info));
                    }
                } else if (local == null and record.photo_source != null) {
                    photo = .clear;
                    setPhotoDetails(&record, null, .{});
                };
                if (progress.cancelled) return .cancelled;
            },
        };

        const biography: Known(wikipedia.Summary) = switch (article) {
            .unknown => .unknown,
            .none => .none,
            .some => |found| found: {
                const summary = progress.step(try lookUp(wikipedia.summary(
                    self.services.wikipedia,
                    arena,
                    self.services.wikipedia_server,
                    found.language,
                    found.title,
                )));
                if (progress.cancelled) return .cancelled;
                break :found if (summary) |maybe_summary| .from(maybe_summary) else .unknown;
            },
        };
        switch (biography) {
            .unknown => {},
            .none => {
                record.biography = null;
                record.biography_source = null;
                record.biography_url = null;
                record.biography_licence = null;
                record.biography_language = null;
            },
            .some => |summary| {
                record.biography = summary.extract;
                record.biography_source = .wikipedia;
                record.biography_url = summary.page_url;
                record.biography_licence = wikipedia.licence;
                record.biography_language = article.some.language;
            },
        }

        if (links) |*found| if (record.biography_url) |page| {
            for (found.items) |link| {
                if (link.kind == .wikipedia and std.mem.eql(u8, link.url, page)) break;
            } else try found.append(arena, .{ .kind = .wikipedia, .url = page });
        };
        if (progress.step(try lookUp(self.services.musicbrainz.browseReleaseGroups(arena, artist_mbid)))) |browse| {
            try info.storeReleaseGroups(artist_id, browse.groups);
        } else if (progress.cancelled) {
            return .cancelled;
        } else if (!same_artist) try info.storeReleaseGroups(artist_id, &.{});

        const outcome = progress.failure orelse .fetched;
        record.outcome = @intFromEnum(outcome);
        try info.store(artist_id, &record, photo, if (links) |found| found.items else null);
        return outcome;
    }

    fn isCurrent(self: *const Fetch, record: *const ArtistInfoRecord, mbid: ?[]const u8, now_s: i64) bool {
        if (now_s - record.fetched_at >= refresh_after_s) return false;
        const stored_mbid = record.musicbrainz_artist_id orelse "";
        if (!std.mem.eql(u8, stored_mbid, mbid orelse "")) return false;
        if (!std.mem.eql(u8, record.requested_language orelse "", self.language)) return false;
        const outcome = std.enums.fromInt(Outcome, record.outcome) orelse return false;
        return switch (outcome) {
            .fetched, .no_musicbrainz_id => true,
            else => false,
        };
    }

    /// A group's years active are its MusicBrainz life span, from formation
    /// to dissolution. Any other Artist's life span is a lifetime, so its
    /// years are its Wikidata work period, else from the earliest Release
    /// in the Library, ended when the work period ends or the Artist has.
    fn setYearsActive(self: *Fetch, record: *ArtistInfoRecord, artist_id: i64, life_span: LifeSpan, work_period: WorkPeriod) !void {
        if (isGroup(record.artist_type)) {
            record.begin_year = life_span.begin_year;
            record.end_year = life_span.end_year;
            record.ended = life_span.ended;
            return;
        }
        record.begin_year = work_period.start_year orelse try self.library.artist_info.earliestReleaseYear(artist_id);
        record.end_year = work_period.end_year;
        record.ended = work_period.end_year != null or life_span.ended;
    }

    /// The first of `local_image_names` in the Artist's folder that is an
    /// image of at most `max_local_image_bytes`, or null.
    pub fn localImage(self: *Fetch, artist_id: i64) !?metadata.EmbeddedImage {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const folder = try artistFolder(arena, self.library, artist_id) orelse return null;
        for (local_image_names) |name| {
            const image_path = try std.fs.path.join(arena, &.{ folder, name });
            const bytes = std.Io.Dir.cwd().readFileAlloc(
                self.io,
                image_path,
                self.allocator,
                .limited(max_local_image_bytes + 1),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (bytes.len > max_local_image_bytes) {
                self.allocator.free(bytes);
                continue;
            }
            return metadata.model.adoptImage(self.allocator, bytes, .other) catch {
                self.allocator.free(bytes);
                continue;
            };
        }
        return null;
    }
};

pub const Article = struct { title: []const u8, language: []const u8 };

const LifeSpan = struct { begin_year: ?i32, end_year: ?i32, ended: bool };

const WorkPeriod = struct { start_year: ?i32 = null, end_year: ?i32 = null };

const group_types = [_][]const u8{ "Group", "Orchestra", "Choir" };

fn isTopArea(area_type: ?[]const u8) bool {
    const kind = area_type orelse return false;
    return std.mem.eql(u8, kind, "Subdivision") or std.mem.eql(u8, kind, "Country");
}

/// The area to name an origin by among those it lies in: a subdivision,
/// else a country, else the first, to look further up from.
fn containingArea(parents: []const providers.musicbrainz.Area) ?providers.musicbrainz.Area {
    for (parents) |parent| if (std.mem.eql(u8, parent.type orelse "", "Subdivision")) return parent;
    for (parents) |parent| if (std.mem.eql(u8, parent.type orelse "", "Country")) return parent;
    return if (parents.len == 0) null else parents[0];
}

fn isGroup(artist_type: ?[]const u8) bool {
    const kind = artist_type orelse return false;
    for (group_types) |group| if (std.mem.eql(u8, kind, group)) return true;
    return false;
}

/// What a step learned of something: nothing, that there is none, or it.
pub fn Known(comptime T: type) type {
    return union(enum) {
        unknown,
        none,
        some: T,

        pub fn from(value: ?T) @This() {
            return if (value) |present| .{ .some = present } else .none;
        }
    };
}

const PhotoDetails = struct {
    page_url: ?[]const u8 = null,
    licence: ?[]const u8 = null,
    licence_url: ?[]const u8 = null,
    credit: ?[]const u8 = null,
};

/// The deepest folder holding every folder of the Artist's Releases, when it
/// lies within the root each was found under and holds no other Artist's
/// files. Each Release's folder is the one its file is in, and the Artist's
/// folder is above it: an Artist with one Release keeps its folder image a
/// level up, not the album's cover.
pub fn artistFolder(arena: std.mem.Allocator, library: *database.LibraryDatabase, artist_id: i64) !?[]const u8 {
    const folders = try library.artist_info.releaseFolders(arena, artist_id);
    if (folders.items.len == 0) return null;
    var common: ?[]const u8 = null;
    for (folders.items) |folder| {
        const release_folder = std.fs.path.dirnamePosix(folder.uri) orelse return null;
        const parent = std.fs.path.dirnamePosix(release_folder) orelse return null;
        if (!within(parent, std.mem.trimEnd(u8, folder.root_path, "/"))) return null;
        common = if (common) |so_far| commonFolder(so_far, parent) else parent;
    }
    for (folders.items) |folder|
        if (!within(common.?, std.mem.trimEnd(u8, folder.root_path, "/"))) return null;
    if (try library.artist_info.folderHoldsOtherArtists(arena, artist_id, common.?)) return null;
    return common;
}

fn within(folder: []const u8, root: []const u8) bool {
    if (root.len == 0) return folder.len != 0;
    if (!std.mem.startsWith(u8, folder, root)) return false;
    return folder.len == root.len or folder[root.len] == '/';
}

fn commonFolder(a: []const u8, b: []const u8) []const u8 {
    var end: usize = 0;
    var index: usize = 0;
    while (index < a.len and index < b.len and a[index] == b[index]) : (index += 1) {
        if (a[index] == '/') end = index;
    }
    if (index == a.len and (index == b.len or b[index] == '/')) return a;
    if (index == b.len and a[index] == '/') return b;
    return a[0..end];
}

fn commonsPhotoDetails(image_info: *const wikimedia_commons.ImageInfo) PhotoDetails {
    return .{
        .page_url = image_info.description_url,
        .licence = image_info.licence,
        .licence_url = image_info.licence_url,
        .credit = image_info.credit,
    };
}

fn setPhotoDetails(record: *ArtistInfoRecord, source: ?database.ArtistPhotoSource, details: PhotoDetails) void {
    record.photo_source = source;
    record.photo_url = details.page_url;
    record.photo_licence = details.licence;
    record.photo_licence_url = details.licence_url;
    record.photo_credit = details.credit;
}

pub const Progress = struct {
    failure: ?Outcome = null,
    cancelled: bool = false,

    pub fn step(self: *Progress, result: anytype) ?StepValue(@TypeOf(result)) {
        return switch (result) {
            .value => |value| value,
            .failed => |outcome| {
                if (outcome == .cancelled) self.cancelled = true;
                if (self.failure == null) self.failure = outcome;
                return null;
            },
        };
    }
};

fn StepValue(comptime Result: type) type {
    return @FieldType(Result, "value");
}

fn Step(comptime T: type) type {
    return union(enum) { value: T, failed: Outcome };
}

/// A provider call's value, or the outcome its failure maps to. Errors that
/// are not a provider's answer are returned.
pub fn lookUp(result: anytype) !Step(@typeInfo(@TypeOf(result)).error_union.payload) {
    const value = result catch |err| return .{ .failed = switch (@as(anyerror, err)) {
        error.Canceled => .cancelled,
        error.ProviderBusy => .busy,
        error.Offline => .offline,
        error.NetworkUnavailable, error.Timeout, error.RateLimited, error.ProviderUnavailable => .unavailable,
        error.RedirectRefused,
        error.ProviderRejectedRequest,
        error.InvalidProviderResponse,
        error.ResponseTooLarge,
        error.InvalidWikidataId,
        error.InvalidLanguage,
        error.InvalidCommonsFile,
        error.InvalidArticleTitle,
        error.InvalidMusicBrainzId,
        => .refused,
        else => return err,
    } };
    return .{ .value = value };
}

const testing = std.testing;

test "the common folder of two paths ends at a whole component" {
    try testing.expectEqualStrings("/music/A", commonFolder("/music/A", "/music/A"));
    try testing.expectEqualStrings("/music/A", commonFolder("/music/A", "/music/A/B"));
    try testing.expectEqualStrings("/music/A", commonFolder("/music/A/B", "/music/A"));
    try testing.expectEqualStrings("/music", commonFolder("/music/Abba", "/music/AC"));
    try testing.expectEqualStrings("/music", commonFolder("/music/A", "/music/AB"));
    try testing.expect(within("/music/A", "/music"));
    try testing.expect(within("/music", "/music"));
    try testing.expect(!within("/musicals", "/music"));
}
