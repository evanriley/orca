//! A Release's description: MusicBrainz gives its release group, whose
//! Wikidata item or Wikipedia link names the article, and Wikipedia gives
//! the article's lead. Unless turned off, the release group's MusicBrainz
//! genres go on the Release's Tracks that have none, and its primary type on
//! a Release whose files state none. Kept in the Library; no media file is
//! written.

const std = @import("std");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const artist_info = @import("artist_info.zig");

const wikidata = providers.wikidata;
const wikipedia = providers.wikipedia;
const musicbrainz = providers.musicbrainz;
const Outcome = artist_info.Outcome;
const Article = artist_info.Article;
const Known = artist_info.Known;
const Progress = artist_info.Progress;
const lookUp = artist_info.lookUp;
const ReleaseInfoRecord = database.ReleaseInfoRecord;

pub const Options = struct {
    /// The Wikipedia whose article is the description, falling back to
    /// English.
    language: []const u8 = "en",
    /// Fetch again even when the stored info is recent.
    force: bool = false,
    /// Make no request; use answers already cached.
    offline: bool = false,
};

/// How long fetched info is kept before a fetch asks again.
pub const refresh_after_s = artist_info.refresh_after_s;

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    services: artist_info.Services,
    /// Unix time in milliseconds.
    wall_clock: network.client.Clock,
    language: []const u8 = "en",
    force: bool = false,
    /// Only fill genres and the release type: no description is fetched or
    /// stored.
    genres_only: bool = false,

    pub fn run(self: *Fetch, release_id: i64) !Outcome {
        const info = &self.library.release_info;
        const subject = try info.subject(release_id) orelse return .not_found;
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        const release_mbid: []const u8 = if (subject.musicbrainz_release_id) |*id| id else {
            if (!self.genres_only) try info.store(release_id, &.{
                .requested_language = self.language,
                .fetched_at = now_s,
                .outcome = @backingInt(Outcome.no_musicbrainz_id),
            });
            return .no_musicbrainz_id;
        };
        var stored = try info.get(self.allocator, release_id);
        defer if (stored) |*row| row.deinit();
        if (!self.force and !self.genres_only) if (stored) |*row| if (self.isCurrent(&row.record, release_mbid, now_s)) return .cached;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var record: ReleaseInfoRecord = .{};
        if (stored) |row| if (std.mem.eql(u8, row.record.musicbrainz_release_id orelse "", release_mbid)) {
            record = row.record;
        };
        record.musicbrainz_release_id = release_mbid;
        record.requested_language = self.language;
        record.fetched_at = now_s;
        var progress: Progress = .{};

        var article: Known(Article) = .unknown;
        const release = progress.step(try lookUp(self.services.musicbrainz.gateway, musicbrainz.MusicBrainz.lookUpRelease, .{ self.services.musicbrainz, arena, release_mbid }));
        if (progress.cancelled) return .cancelled;
        if (release) |found| {
            record.musicbrainz_release_group_id = found.releaseGroupId();
            if (record.musicbrainz_release_group_id == null) article = .none;
        }
        if (record.musicbrainz_release_group_id) |group_mbid| {
            const group = progress.step(try lookUp(self.services.musicbrainz.gateway, musicbrainz.MusicBrainz.lookUpReleaseGroup, .{ self.services.musicbrainz, arena, group_mbid }));
            if (progress.cancelled) return .cancelled;
            if (group) |found| {
                if (found.primary_type) |primary_type| _ = try self.library.releases.fillReleaseType(release_id, primary_type);
                if (found.genres.len != 0 and (self.genres_only or try self.library.settings.flag(database.setting_genre_fill_musicbrainz, true))) {
                    var buffer: [musicbrainz.fill_genres_max][]const u8 = undefined;
                    _ = try self.library.genres.fillFromProvider(self.allocator, .{ .release = release_id }, musicbrainz.topGenres(found.genres, &buffer));
                }
                if (!self.genres_only) article = try self.findArticle(arena, &progress, found);
                if (progress.cancelled) return .cancelled;
            }
        }
        if (self.genres_only) return progress.failure orelse .fetched;

        const description: Known(wikipedia.Summary) = switch (article) {
            .unknown => .unknown,
            .none => .none,
            .some => |found| found: {
                const summary = progress.step(try lookUp(self.services.wikipedia.gateway, wikipedia.summary, .{
                    self.services.wikipedia,
                    arena,
                    self.services.wikipedia_server,
                    found.language,
                    found.title,
                }));
                if (progress.cancelled) return .cancelled;
                break :found if (summary) |maybe_summary| .from(maybe_summary) else .unknown;
            },
        };
        switch (description) {
            .unknown => {},
            .none => {
                record.description = null;
                record.description_source = null;
                record.description_url = null;
                record.description_licence = null;
                record.description_language = null;
            },
            .some => |summary| {
                record.description = summary.extract;
                record.description_source = .wikipedia;
                record.description_url = summary.page_url;
                record.description_licence = wikipedia.licence;
                record.description_language = article.some.language;
            },
        }
        const outcome = progress.failure orelse .fetched;
        record.outcome = @backingInt(outcome);
        try info.store(release_id, &record);
        return outcome;
    }

    /// The article the release group's Wikidata item names in the language,
    /// else in English, or failing an item the group's Wikipedia link.
    fn findArticle(self: *Fetch, arena: std.mem.Allocator, progress: *Progress, group: musicbrainz.ReleaseGroupLookup) !Known(Article) {
        if (group.wikidata_id) |item_id| {
            const found = progress.step(try lookUp(self.services.wikidata.gateway, wikidata.entity, .{
                self.services.wikidata,
                arena,
                self.services.wikidata_server,
                item_id,
                self.language,
            })) orelse return .unknown;
            const entity = found orelse return .none;
            const title = entity.article_title orelse return .none;
            return .{ .some = .{ .title = title, .language = entity.article_language.? } };
        }
        const page_url = group.wikipedia_url orelse return .none;
        const linked = try wikipedia.articleFromUrl(arena, page_url) orelse return .none;
        return .{ .some = .{ .title = linked.title, .language = linked.language } };
    }

    fn isCurrent(self: *const Fetch, record: *const ReleaseInfoRecord, release_mbid: []const u8, now_s: i64) bool {
        if (now_s - record.fetched_at >= refresh_after_s) return false;
        if (!std.mem.eql(u8, record.musicbrainz_release_id orelse "", release_mbid)) return false;
        if (!std.mem.eql(u8, record.requested_language orelse "", self.language)) return false;
        const outcome = std.enums.fromInt(Outcome, record.outcome) orelse return false;
        return outcome == .fetched;
    }
};
