const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/model.zig");
const wikidata = @import("wikidata.zig");
const network = @import("../network/root.zig");
const model = @import("model.zig");
const scoring = @import("scoring.zig");
const url_encoding = @import("url.zig");

pub const service = "musicbrainz";
pub const default_server = "https://musicbrainz.org";
const search_limit = 10;

pub const MusicBrainz = struct {
    gateway: *network.Gateway,
    cache: *database.ProviderCacheRepository,
    /// Unix time in milliseconds: cache entries outlive the process.
    wall_clock: network.client.Clock,
    server: []const u8 = default_server,
    cache_ttl_seconds: i64 = 30 * 24 * 60 * 60,
    refusal_ttl_seconds: i64 = 7 * 24 * 60 * 60,
    requests_answered: u64 = 0,
    cache_hits: u64 = 0,

    pub fn provider(self: *MusicBrainz) model.Provider {
        return .{ .id = service, .context = self, .search_fn = searchAdapter };
    }

    pub fn search(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        query: model.Query,
    ) !model.CandidateList {
        if (isBlank(query.title) or isBlank(query.artist)) return error.InsufficientIdentificationEvidence;
        const request_url = try self.searchUrl(allocator, query);
        defer allocator.free(request_url);
        return self.request(model.CandidateList, allocator, request_url, SearchParser{ .album = query.album });
    }

    pub fn lookUpRelease(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        release_mbid: []const u8,
    ) !ReleaseLookup {
        if (!metadata.isMusicBrainzId(release_mbid)) return error.InvalidMusicBrainzId;
        const request_url = try std.fmt.allocPrint(
            allocator,
            "{s}/ws/2/release/{s}?fmt=json&inc=recordings+artist-credits+release-groups",
            .{ std.mem.trimEnd(u8, self.server, "/"), release_mbid },
        );
        defer allocator.free(request_url);
        return self.request(ReleaseLookup, allocator, request_url, ReleaseParser{});
    }

    /// `GET {server}/ws/2/artist/{mbid}?fmt=json&inc=url-rels+genres+artist-rels`,
    /// cached like every other lookup.
    pub fn lookUpArtist(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        artist_mbid: []const u8,
    ) !ArtistLookup {
        if (!metadata.isMusicBrainzId(artist_mbid)) return error.InvalidMusicBrainzId;
        const request_url = try std.fmt.allocPrint(
            allocator,
            "{s}/ws/2/artist/{s}?fmt=json&inc=url-rels+genres+artist-rels",
            .{ std.mem.trimEnd(u8, self.server, "/"), artist_mbid },
        );
        defer allocator.free(request_url);
        return self.request(ArtistLookup, allocator, request_url, ArtistParser{});
    }

    /// `GET {server}/ws/2/release-group/{mbid}?fmt=json&inc=url-rels+genres`,
    /// cached like every other lookup.
    pub fn lookUpReleaseGroup(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        group_mbid: []const u8,
    ) !ReleaseGroupLookup {
        if (!metadata.isMusicBrainzId(group_mbid)) return error.InvalidMusicBrainzId;
        const request_url = try std.fmt.allocPrint(
            allocator,
            "{s}/ws/2/release-group/{s}?fmt=json&inc=url-rels+genres",
            .{ std.mem.trimEnd(u8, self.server, "/"), group_mbid },
        );
        defer allocator.free(request_url);
        return self.request(ReleaseGroupLookup, allocator, request_url, ReleaseGroupParser{});
    }

    /// One cached GET: a fresh cached answer without a request, else the
    /// service, else an expired answer when the service cannot be reached.
    /// An answer is cached only once `parser` accepts it.
    fn request(
        self: *MusicBrainz,
        comptime T: type,
        allocator: std.mem.Allocator,
        request_url: []const u8,
        parser: anytype,
    ) !T {
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        if (try self.cache.get(allocator, service, request_url, now_s, false)) |cached| {
            defer cached.deinit();
            self.cache_hits += 1;
            if (cached.status != 200) return error.ProviderRejectedRequest;
            return parser.parse(allocator, cached.body);
        }
        const response = self.gateway.execute(
            allocator,
            .get,
            request_url,
            null,
            &.{.{ .name = "accept", .value = "application/json" }},
        ) catch |err| switch (err) {
            error.RateLimited, error.NetworkUnavailable, error.Timeout, error.Offline => {
                if (try self.stale(T, allocator, request_url, now_s, parser)) |value| return value;
                return err;
            },
            else => return err,
        };
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 408 or response.status >= 500) {
            if (try self.stale(T, allocator, request_url, now_s, parser)) |value| return value;
            return error.ProviderUnavailable;
        }
        if (response.status != 200) {
            if (network.client.isPermanentRejection(response.status))
                try self.cache.put(service, request_url, response.status, response.body, now_s + self.refusal_ttl_seconds);
            return error.ProviderRejectedRequest;
        }
        const value = try parser.parse(allocator, response.body);
        errdefer value.deinit();
        try self.cache.put(service, request_url, response.status, response.body, now_s + self.cache_ttl_seconds);
        return value;
    }

    fn stale(
        self: *MusicBrainz,
        comptime T: type,
        allocator: std.mem.Allocator,
        request_url: []const u8,
        now_s: i64,
        parser: anytype,
    ) !?T {
        const entry = try self.cache.get(allocator, service, request_url, now_s, true) orelse return null;
        defer entry.deinit();
        if (entry.status != 200) return null;
        return try parser.parse(allocator, entry.body);
    }

    fn searchUrl(self: MusicBrainz, allocator: std.mem.Allocator, query: model.Query) ![]u8 {
        var lucene = std.Io.Writer.Allocating.init(allocator);
        defer lucene.deinit();
        try writeTerm(&lucene.writer, "recording", query.title.?);
        try lucene.writer.writeAll(" AND ");
        try writeTerm(&lucene.writer, "artist", query.artist.?);
        if (!isBlank(query.album)) {
            try lucene.writer.writeAll(" ");
            try writeTerm(&lucene.writer, "release", query.album.?);
        }
        var request_url = std.Io.Writer.Allocating.init(allocator);
        errdefer request_url.deinit();
        try request_url.writer.print("{s}/ws/2/recording?fmt=json&limit={d}&query=", .{
            std.mem.trimEnd(u8, self.server, "/"),
            search_limit,
        });
        try url_encoding.writeEncoded(&request_url.writer, lucene.written());
        var list = request_url.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn searchAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        query: model.Query,
    ) !model.CandidateList {
        const self: *MusicBrainz = @ptrCast(@alignCast(context));
        return self.search(allocator, query);
    }
};

const SearchParser = struct {
    album: ?[]const u8,

    fn parse(self: SearchParser, allocator: std.mem.Allocator, body: []const u8) !model.CandidateList {
        return parseCandidates(allocator, body, self.album);
    }
};

const ReleaseParser = struct {
    fn parse(_: ReleaseParser, allocator: std.mem.Allocator, body: []const u8) !ReleaseLookup {
        const parsed = std.json.parseFromSlice(ReleaseBody, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        if (!metadata.isMusicBrainzId(parsed.value.id)) {
            parsed.deinit();
            return error.InvalidProviderResponse;
        }
        return .{ .parsed = parsed };
    }
};

/// What Orca reads from a MusicBrainz artist. Strings live in `arena`.
pub const ArtistLookup = struct {
    arena: std.heap.ArenaAllocator,
    artist_type: ?[]const u8 = null,
    begin_year: ?i32 = null,
    end_year: ?i32 = null,
    ended: bool = false,
    wikidata_id: ?[]const u8 = null,
    /// The Commons file an `image` relationship names, without `File:`.
    /// An `image` relationship to anywhere else is ignored.
    commons_image_file: ?[]const u8 = null,
    /// The artist's current URL relationships, at most
    /// `database.artist_links_max` of them.
    links: []const database.ArtistLink = &.{},
    /// The genres MusicBrainz users voted for, at most `max_genres`, in the
    /// order MusicBrainz lists them. CC BY-NC-SA 3.0, unlike the CC0 rest.
    genres: []const Genre = &.{},

    pub fn deinit(self: ArtistLookup) void {
        self.arena.deinit();
    }
};

/// A genre and how many MusicBrainz users voted for it.
pub const Genre = struct {
    name: []const u8,
    count: u32,
};

/// The licence of MusicBrainz genres, credited wherever they are shown.
pub const genre_licence = "CC BY-NC-SA 3.0";
/// At most this many genres are read from one artist or release group.
pub const max_genres = 64;

const GenreBody = struct {
    name: []const u8 = "",
    count: i64 = 0,
};

fn readGenres(arena: std.mem.Allocator, listed: []const GenreBody) ![]const Genre {
    var genres: std.ArrayList(Genre) = .empty;
    for (listed) |genre| {
        if (genres.items.len == max_genres) break;
        const name = std.mem.trim(u8, genre.name, " \t");
        if (name.len == 0 or genre.count <= 0) continue;
        try genres.append(arena, .{ .name = name, .count = std.math.cast(u32, genre.count) orelse std.math.maxInt(u32) });
    }
    return genres.items;
}

/// A genre fill writes the three genres with the most votes, and any tied
/// with the third, but never more than `fill_genres_max`.
pub const fill_genres_min = 3;
pub const fill_genres_max = 5;

/// The genres a fill writes, most votes first, ties in MusicBrainz's order.
pub fn topGenres(genres: []const Genre, buffer: *[fill_genres_max][]const u8) []const []const u8 {
    var sorted: [max_genres]Genre = undefined;
    const count = @min(genres.len, max_genres);
    @memcpy(sorted[0..count], genres[0..count]);
    std.sort.insertion(Genre, sorted[0..count], {}, moreVotes);
    var kept: usize = 0;
    for (sorted[0..count]) |genre| {
        if (kept == fill_genres_max) break;
        if (kept >= fill_genres_min and genre.count < sorted[fill_genres_min - 1].count) break;
        buffer[kept] = genre.name;
        kept += 1;
    }
    return buffer[0..kept];
}

fn moreVotes(_: void, a: Genre, b: Genre) bool {
    return a.count > b.count;
}

/// What Orca reads from a MusicBrainz release group. Strings live in
/// `arena`.
pub const ReleaseGroupLookup = struct {
    arena: std.heap.ArenaAllocator,
    wikidata_id: ?[]const u8 = null,
    /// The URL of a current `wikipedia` relationship.
    wikipedia_url: ?[]const u8 = null,
    genres: []const Genre = &.{},
    /// The group's primary type as MusicBrainz names it, such as "Album" or
    /// "EP".
    primary_type: ?[]const u8 = null,

    pub fn deinit(self: ReleaseGroupLookup) void {
        self.arena.deinit();
    }
};

const ReleaseGroupBody = struct {
    id: []const u8 = "",
    @"primary-type": ?[]const u8 = null,
    relations: []const ArtistRelation = &.{},
    genres: []const GenreBody = &.{},
};

const ReleaseGroupParser = struct {
    fn parse(_: ReleaseGroupParser, allocator: std.mem.Allocator, body: []const u8) !ReleaseGroupLookup {
        var result: ReleaseGroupLookup = .{ .arena = .init(allocator) };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(ReleaseGroupBody, arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        if (!metadata.isMusicBrainzId(parsed.id)) return error.InvalidProviderResponse;
        for (parsed.relations) |relation| {
            if (!std.mem.eql(u8, relation.@"target-type", "url")) continue;
            if (relation.ended orelse false) continue;
            const resource = (relation.url orelse continue).resource;
            if (resource.len == 0) continue;
            if (std.mem.eql(u8, relation.type, "wikidata") and result.wikidata_id == null)
                result.wikidata_id = wikidata.itemIdFromUrl(resource);
            if (std.mem.eql(u8, relation.type, "wikipedia") and result.wikipedia_url == null)
                result.wikipedia_url = resource;
        }
        result.genres = try readGenres(arena, parsed.genres);
        result.primary_type = parsed.@"primary-type";
        return result;
    }
};

const ArtistLifeSpan = struct {
    begin: ?[]const u8 = null,
    end: ?[]const u8 = null,
    ended: ?bool = null,
};

const ArtistRelationUrl = struct {
    resource: []const u8 = "",
};

const ArtistRelation = struct {
    type: []const u8 = "",
    @"target-type": []const u8 = "",
    ended: ?bool = null,
    url: ?ArtistRelationUrl = null,
};

const ArtistBody = struct {
    id: []const u8 = "",
    type: ?[]const u8 = null,
    @"life-span": ?ArtistLifeSpan = null,
    relations: []const ArtistRelation = &.{},
    genres: []const GenreBody = &.{},
};

const ArtistParser = struct {
    fn parse(_: ArtistParser, allocator: std.mem.Allocator, body: []const u8) !ArtistLookup {
        var result: ArtistLookup = .{ .arena = .init(allocator) };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(ArtistBody, arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        if (!metadata.isMusicBrainzId(parsed.id)) return error.InvalidProviderResponse;
        if (parsed.type) |kind| if (kind.len != 0) {
            result.artist_type = kind;
        };
        if (parsed.@"life-span") |span| {
            result.begin_year = yearOf(span.begin);
            result.end_year = yearOf(span.end);
            result.ended = (span.ended orelse false) or result.end_year != null;
        }
        var links: std.ArrayList(database.ArtistLink) = .empty;
        for (parsed.relations) |relation| {
            if (!std.mem.eql(u8, relation.@"target-type", "url")) continue;
            if (relation.ended orelse false) continue;
            const resource = (relation.url orelse continue).resource;
            if (resource.len == 0) continue;
            if (std.mem.eql(u8, relation.type, "image")) {
                if (result.commons_image_file == null)
                    result.commons_image_file = try commonsFileName(arena, resource);
                continue;
            }
            if (std.mem.eql(u8, relation.type, "wikidata") and result.wikidata_id == null)
                result.wikidata_id = wikidata.itemIdFromUrl(resource);
            if (links.items.len < database.artist_links_max)
                try links.append(arena, .{ .kind = linkKind(relation.type, resource), .url = resource });
        }
        result.links = links.items;
        result.genres = try readGenres(arena, parsed.genres);
        return result;
    }
};

fn yearOf(date: ?[]const u8) ?i32 {
    const text = date orelse return null;
    if (text.len < 4) return null;
    return std.fmt.parseInt(i32, text[0..4], 10) catch null;
}

/// The file name a `commons.wikimedia.org/wiki/File:…` URL names, decoded,
/// with underscores as spaces. Null for any other URL.
fn commonsFileName(arena: std.mem.Allocator, resource: []const u8) !?[]const u8 {
    const uri = std.Uri.parse(resource) catch return null;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&host_buffer) catch return null).bytes;
    if (!std.ascii.eqlIgnoreCase(host, "commons.wikimedia.org")) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |text| text,
    };
    const prefix = "/wiki/File:";
    if (!std.mem.startsWith(u8, path, prefix) or path.len == prefix.len) return null;
    const decoded = try arena.dupe(u8, path[prefix.len..]);
    const name = std.Uri.percentDecodeInPlace(decoded);
    std.mem.replaceScalar(u8, name, '_', ' ');
    if (!std.unicode.utf8ValidateSlice(name)) return null;
    return name;
}

fn linkKind(relation_type: []const u8, resource: []const u8) database.ArtistLinkKind {
    const by_type = [_]struct { []const u8, database.ArtistLinkKind }{
        .{ "official homepage", .official },
        .{ "wikidata", .wikidata },
        .{ "wikipedia", .wikipedia },
        .{ "discogs", .discogs },
        .{ "last.fm", .lastfm },
        .{ "bandcamp", .bandcamp },
        .{ "soundcloud", .soundcloud },
        .{ "youtube", .youtube },
        .{ "youtube music", .youtube },
        .{ "apple music", .apple_music },
    };
    for (by_type) |entry| if (std.mem.eql(u8, relation_type, entry[0])) return entry[1];
    const uri = std.Uri.parse(resource) catch return .other;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&host_buffer) catch return .other).bytes;
    const by_host = [_]struct { []const u8, database.ArtistLinkKind }{
        .{ "spotify.com", .spotify },
        .{ "music.apple.com", .apple_music },
        .{ "itunes.apple.com", .apple_music },
        .{ "tidal.com", .tidal },
        .{ "deezer.com", .deezer },
        .{ "instagram.com", .instagram },
        .{ "twitter.com", .x },
        .{ "x.com", .x },
        .{ "facebook.com", .facebook },
        .{ "tiktok.com", .tiktok },
        .{ "bandcamp.com", .bandcamp },
        .{ "soundcloud.com", .soundcloud },
        .{ "youtube.com", .youtube },
        .{ "discogs.com", .discogs },
        .{ "last.fm", .lastfm },
    };
    for (by_host) |entry| if (hostWithin(host, entry[0])) return entry[1];
    return .other;
}

fn hostWithin(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    return host.len > domain.len and host[host.len - domain.len - 1] == '.' and
        std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain);
}

pub const max_release_mbids = 25;

const CreditedArtist = struct {
    id: []const u8 = "",
};

const ReleaseCredit = struct {
    name: []const u8 = "",
    joinphrase: []const u8 = "",
    artist: ?CreditedArtist = null,
};

const ReleaseRecording = struct {
    id: []const u8 = "",
};

const ReleaseTrack = struct {
    id: []const u8 = "",
    position: ?u32 = null,
    title: []const u8 = "",
    @"artist-credit": []const ReleaseCredit = &.{},
    recording: ?ReleaseRecording = null,
};

const ReleaseMedium = struct {
    position: ?u32 = null,
    tracks: []const ReleaseTrack = &.{},
};

const ReleaseGroup = struct {
    id: []const u8 = "",
};

const ReleaseBody = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    date: ?[]const u8 = null,
    @"artist-credit": []const ReleaseCredit = &.{},
    @"release-group": ?ReleaseGroup = null,
    media: []const ReleaseMedium = &.{},
};

/// A looked-up release. Strings it hands out live as long as it does.
pub const ReleaseLookup = struct {
    parsed: std.json.Parsed(ReleaseBody),

    pub fn deinit(self: ReleaseLookup) void {
        self.parsed.deinit();
    }

    pub fn id(self: *const ReleaseLookup) []const u8 {
        return self.parsed.value.id;
    }

    pub fn releaseGroupId(self: *const ReleaseLookup) ?[]const u8 {
        const group = self.parsed.value.@"release-group" orelse return null;
        return validId(group.id);
    }

    /// What the release says about the track holding `recording_mbid`: the
    /// one at `tagged_track_number` when the recording appears more than
    /// once, else the first. Null when the release does not hold it.
    pub fn enrichment(
        self: *const ReleaseLookup,
        recording_mbid: []const u8,
        tagged_track_number: ?u32,
    ) !?database.ReleaseEnrichment {
        const release = self.parsed.value;
        var first: ?Placed = null;
        var at_tagged: ?Placed = null;
        for (release.media) |*medium| {
            for (medium.tracks) |*track| {
                const recording = track.recording orelse continue;
                if (!std.mem.eql(u8, recording.id, recording_mbid)) continue;
                if (!metadata.isMusicBrainzId(track.id)) continue;
                const placed: Placed = .{ .medium = medium, .track = track };
                if (first == null) first = placed;
                if (at_tagged == null and tagged_track_number != null and track.position == tagged_track_number) at_tagged = placed;
            }
        }
        const chosen = at_tagged orelse first orelse return null;
        const arena = self.parsed.arena.allocator();
        const release_credit = release.@"artist-credit";
        return .{
            .track_title = nonEmpty(chosen.track.title),
            .track_artist = nonEmpty(try creditedArtist(arena, chosen.track.@"artist-credit")),
            .release_title = nonEmpty(release.title),
            .release_artist = nonEmpty(try creditedArtist(arena, release_credit)),
            .release_artist_mbid = if (release_credit.len == 1) soleArtistId(release_credit[0]) else null,
            .release_date = nonEmpty(release.date orelse ""),
            .release_group_mbid = if (release.@"release-group") |group| validId(group.id) else null,
            .release_track_mbid = chosen.track.id,
            .track_number = chosen.track.position,
            .disc_number = chosen.medium.position,
        };
    }

    const Placed = struct { medium: *const ReleaseMedium, track: *const ReleaseTrack };
};

fn soleArtistId(credit: ReleaseCredit) ?[]const u8 {
    const artist = credit.artist orelse return null;
    return validId(artist.id);
}

fn validId(text: []const u8) ?[]const u8 {
    return if (metadata.isMusicBrainzId(text)) text else null;
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    return if (std.mem.trim(u8, text, " \t").len == 0) null else text;
}

fn isBlank(text: ?[]const u8) bool {
    const value = text orelse return true;
    return std.mem.trim(u8, value, " \t").len == 0;
}

fn writeTerm(writer: *std.Io.Writer, field: []const u8, value: []const u8) !void {
    try writer.print("{s}:\"", .{field});
    for (value) |byte| {
        if (std.mem.indexOfScalar(u8, "+-&|!(){}[]^\"~*?:\\/", byte) != null) try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

const ArtistCredit = struct {
    name: []const u8 = "",
    joinphrase: []const u8 = "",
};

const Track = struct {
    number: []const u8 = "",
};

const Medium = struct {
    @"track-offset": ?u32 = null,
    track: []const Track = &.{},
};

const Release = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    status: ?[]const u8 = null,
    date: ?[]const u8 = null,
    @"track-count": ?u32 = null,
    media: []const Medium = &.{},
};

const Recording = struct {
    id: []const u8,
    title: []const u8 = "",
    score: ?u32 = null,
    length: ?u64 = null,
    @"artist-credit": []const ArtistCredit = &.{},
    releases: []const Release = &.{},
};

fn parseCandidates(
    allocator: std.mem.Allocator,
    body: []const u8,
    album: ?[]const u8,
) !model.CandidateList {
    const Envelope = struct { recordings: []const Recording = &.{} };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderResponse,
    };
    defer parsed.deinit();
    var candidates: std.ArrayList(model.Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit();
        candidates.deinit(allocator);
    }
    for (parsed.value.recordings) |recording| {
        if (!metadata.isMusicBrainzId(recording.id)) continue;
        const artist = try creditedArtist(allocator, recording.@"artist-credit");
        defer allocator.free(artist);
        const release: ?Release = if (try bestRelease(allocator, recording.releases, album)) |index|
            recording.releases[index]
        else
            null;
        var candidate = try model.Candidate.init(
            allocator,
            service,
            recording.id,
            recording.title,
            artist,
            if (release) |chosen| chosen.title else "",
        );
        errdefer candidate.deinit();
        candidate.duration_ms = recording.length;
        candidate.mb_score = if (recording.score) |score| @intCast(@min(score, 100)) else null;
        if (release) |chosen| {
            candidate.track_number = trackNumber(chosen);
            if (metadata.isMusicBrainzId(chosen.id)) candidate.release_mbid = try allocator.dupe(u8, chosen.id);
        }
        candidate.release_mbids = try releaseIds(allocator, recording.releases);
        candidate.release_facts = try releaseFacts(allocator, recording.releases);
        try candidates.append(allocator, candidate);
    }
    return .{ .allocator = allocator, .items = try candidates.toOwnedSlice(allocator) };
}

fn creditedArtist(allocator: std.mem.Allocator, credits: anytype) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (credits) |credit| {
        try joined.appendSlice(allocator, credit.name);
        try joined.appendSlice(allocator, credit.joinphrase);
    }
    return joined.toOwnedSlice(allocator);
}

fn releaseIds(allocator: std.mem.Allocator, releases: []const Release) ![][]u8 {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ids.items) |value| allocator.free(value);
        ids.deinit(allocator);
    }
    for (releases) |release| {
        if (ids.items.len == max_release_mbids) break;
        if (!metadata.isMusicBrainzId(release.id)) continue;
        const seen = for (ids.items) |value| {
            if (std.mem.eql(u8, value, release.id)) break true;
        } else false;
        if (seen) continue;
        try ids.ensureUnusedCapacity(allocator, 1);
        ids.appendAssumeCapacity(try allocator.dupe(u8, release.id));
    }
    return ids.toOwnedSlice(allocator);
}

fn releaseFacts(allocator: std.mem.Allocator, releases: []const Release) ![]database.ReleaseFact {
    var facts: std.ArrayList(database.ReleaseFact) = .empty;
    errdefer {
        for (facts.items) |fact| model.freeReleaseFact(allocator, fact);
        facts.deinit(allocator);
    }
    for (releases) |release| {
        if (facts.items.len == max_release_mbids) break;
        if (!metadata.isMusicBrainzId(release.id)) continue;
        const seen = for (facts.items) |fact| {
            if (std.mem.eql(u8, fact.mbid, release.id)) break true;
        } else false;
        if (seen) continue;
        try facts.ensureUnusedCapacity(allocator, 1);
        const mbid = try allocator.dupe(u8, release.id);
        errdefer allocator.free(mbid);
        const status = try dupeOptional(allocator, release.status);
        errdefer if (status) |value| allocator.free(value);
        const date = try dupeOptional(allocator, release.date);
        facts.appendAssumeCapacity(.{ .mbid = mbid, .status = status, .date = date, .track_count = release.@"track-count" });
    }
    return facts.toOwnedSlice(allocator);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn bestRelease(allocator: std.mem.Allocator, releases: []const Release, album: ?[]const u8) !?usize {
    if (releases.len == 0) return null;
    if (isBlank(album)) return 0;
    var best: usize = 0;
    var best_similarity: f64 = -1;
    for (releases, 0..) |release, index| {
        const similarity = try scoring.textSimilarity(allocator, album.?, release.title);
        if (similarity > best_similarity) {
            best = index;
            best_similarity = similarity;
        }
    }
    return best;
}

fn trackNumber(release: Release) ?u32 {
    for (release.media) |medium| {
        for (medium.track) |track| {
            if (std.fmt.parseUnsigned(u32, track.number, 10)) |number| return number else |_| {}
        }
        if (medium.@"track-offset") |offset| return std.math.add(u32, offset, 1) catch null;
    }
    return null;
}

const testing = std.testing;
const fixture_path = "fixtures/providers/musicbrainz-recording-search.json";

fn readFixture() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, fixture_path, testing.allocator, .limited(1 << 20));
}

fn findCandidate(list: model.CandidateList, recording_mbid: []const u8) ?model.Candidate {
    for (list.items) |candidate| {
        if (std.mem.eql(u8, candidate.provider_id, recording_mbid)) return candidate;
    }
    return null;
}

test "a recording search yields the score, the whole artist credit and the release the album names" {
    const body = try readFixture();
    defer testing.allocator.free(body);
    const list = try parseCandidates(testing.allocator, body, "Hot Space");
    defer list.deinit();

    try testing.expectEqual(@as(usize, 4), list.items.len);
    const duet = list.items[0];
    try testing.expectEqualStrings("a6d3063b-c34f-46c7-b61c-dda4d94195a9", duet.provider_id);
    try testing.expectEqualStrings("Under Pressure", duet.title);
    try testing.expectEqualStrings("Queen & David Bowie", duet.artist);
    try testing.expectEqualStrings("Hot Space", duet.album);
    try testing.expectEqualStrings("047a4aae-27f8-4f2d-92fb-214fd8dc865a", duet.release_mbid.?);
    try testing.expectEqual(@as(?u32, 7), duet.track_number);
    try testing.expectEqual(@as(?u64, 266_920), duet.duration_ms);
    try testing.expectEqual(@as(?u8, 100), duet.mb_score);
    const unmeasured = findCandidate(list, "af59c0c3-f3da-4bc2-ae24-dd2aa93021a4").?;
    try testing.expectEqual(@as(?u64, null), unmeasured.duration_ms);
    try testing.expectEqual(@as(?u8, 68), unmeasured.mb_score);
}

test "the release closest to the album is chosen, and a side-numbered track falls back to its place on the medium" {
    const body = try readFixture();
    defer testing.allocator.free(body);
    const live = "e3a15a94-41d6-45c0-bbc1-aae6137bcb7a";

    const named = try parseCandidates(testing.allocator, body, "Live USA");
    defer named.deinit();
    const chosen = findCandidate(named, live).?;
    try testing.expectEqualStrings("Live USA", chosen.album);
    try testing.expectEqualStrings("786a6852-4b41-44c9-a585-c65f9caa54a1", chosen.release_mbid.?);
    try testing.expectEqual(@as(?u32, 6), chosen.track_number);

    const unnamed = try parseCandidates(testing.allocator, body, null);
    defer unnamed.deinit();
    const first = findCandidate(unnamed, live).?;
    try testing.expectEqualStrings("Live USA, Vol. 2", first.album);
    try testing.expectEqual(@as(?u32, 11), first.track_number);
}

test "an answer that is not a recording search is refused as invalid" {
    try testing.expectError(error.InvalidProviderResponse, parseCandidates(testing.allocator, "<html>", null));
    const empty = try parseCandidates(testing.allocator, "{\"recordings\":[]}", null);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.items.len);
}

const empty_answer = "{\"recordings\":[]}";

const Rig = struct {
    library: database.LibraryDatabase,
    net: network.testing.TestGateway,
    adapter: MusicBrainz,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.net.init(.{ .now_ms = 1_800_000_000_000 });
        self.respond(200, empty_answer);
        self.adapter = .{
            .gateway = &self.net.gateway,
            .cache = &self.library.provider_cache,
            .wall_clock = self.net.clock.wallClock(),
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }

    fn respond(self: *Rig, status: u16, body: []const u8) void {
        self.net.transport.otherwise = .{ .respond = .{ .status = status, .body = body } };
    }

    fn search(self: *Rig, query: model.Query) !model.CandidateList {
        return self.adapter.search(testing.allocator, query);
    }
};

test "a title with quotes and brackets is escaped for Lucene and then for the URL" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-escape?mode=memory&cache=shared");
    defer rig.deinit();
    rig.adapter.server = "http://127.0.0.1:5000/";

    const list = try rig.search(.{ .title = "Say \"Hello\" (Remix)", .artist = "AC/DC", .album = "Live: 1+1" });
    defer list.deinit();

    try testing.expectEqualStrings(
        "http://127.0.0.1:5000/ws/2/recording?fmt=json&limit=10&query=" ++
            "recording%3A%22Say%20%5C%22Hello%5C%22%20%5C%28Remix%5C%29%22" ++
            "%20AND%20artist%3A%22AC%5C%2FDC%22" ++
            "%20release%3A%22Live%5C%3A%201%5C%2B1%22",
        rig.net.transport.lastUrl(),
    );
}

test "a search without a title or an artist makes no request" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-insufficient?mode=memory&cache=shared");
    defer rig.deinit();

    try testing.expectError(error.InsufficientIdentificationEvidence, rig.search(.{ .title = "Orca", .artist = "" }));
    try testing.expectError(error.InsufficientIdentificationEvidence, rig.search(.{ .title = " ", .artist = "Artist" }));
    try testing.expectEqual(@as(u32, 0), rig.net.transport.requestCount());
}

test "answers are cached for thirty days, empty ones too, and an expired one stands in when the service is down" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-cache?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try readFixture();
    defer testing.allocator.free(body);
    rig.respond(200, body);

    const first = try rig.search(.{ .title = "Under Pressure", .artist = "Queen", .album = "Hot Space" });
    defer first.deinit();
    const again = try rig.search(.{ .title = "Under Pressure", .artist = "Queen", .album = "Hot Space" });
    defer again.deinit();
    rig.respond(200, empty_answer);
    const nothing = try rig.search(.{ .title = "Unknown", .artist = "Nobody" });
    defer nothing.deinit();
    const still_nothing = try rig.search(.{ .title = "Unknown", .artist = "Nobody" });
    defer still_nothing.deinit();

    try testing.expectEqual(@as(u32, 2), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 2), rig.adapter.requests_answered);
    try testing.expectEqual(@as(u64, 2), rig.adapter.cache_hits);
    try testing.expectEqual(@as(usize, 0), still_nothing.items.len);

    rig.net.clock.advance((rig.adapter.cache_ttl_seconds + 1) * 1000);
    rig.respond(503, empty_answer);
    const stale = try rig.search(.{ .title = "Under Pressure", .artist = "Queen", .album = "Hot Space" });
    defer stale.deinit();
    try testing.expectEqualStrings("Hot Space", stale.items[0].album);
    try testing.expectEqual(@as(u32, 3), rig.net.transport.requestCount());
}

test "an unavailable service is reported apart from a refused query, and a refusal the query did not cause is not cached" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-failures?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.gateway.config.minimum_interval_ms = 0;
    const query: model.Query = .{ .title = "Orca", .artist = "Artist" };

    rig.respond(503, empty_answer);
    try testing.expectError(error.ProviderUnavailable, rig.search(query));
    for ([_]u16{ 401, 403, 408 }) |status| {
        rig.respond(status, empty_answer);
        try testing.expectError(if (status == 408) error.ProviderUnavailable else error.ProviderRejectedRequest, rig.search(query));
    }
    rig.net.transport.otherwise = .{ .fail = error.ConnectionRefused };
    try testing.expectError(error.NetworkUnavailable, rig.search(query));
    rig.respond(429, empty_answer);
    try testing.expectError(error.RateLimited, rig.search(query));
    try testing.expectError(error.RateLimited, rig.search(query));

    try testing.expectEqual(@as(u32, 6), rig.net.transport.requestCount());
    try testing.expect(try rig.library.provider_cache.get(testing.allocator, service, rig.net.transport.lastUrl(), 0, true) == null);
}

test "a query MusicBrainz refused is refused without a request for seven days, and asked again after" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-refused?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.gateway.config.minimum_interval_ms = 0;
    const query: model.Query = .{ .title = "Orca", .artist = "Artist" };
    rig.respond(400, "{\"error\":\"Invalid query\"}");
    try testing.expectError(error.ProviderRejectedRequest, rig.search(query));

    rig.respond(200, empty_answer);
    try testing.expectError(error.ProviderRejectedRequest, rig.search(query));
    rig.net.clock.advance((rig.adapter.refusal_ttl_seconds - 1) * 1000);
    try testing.expectError(error.ProviderRejectedRequest, rig.search(query));
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 2), rig.adapter.cache_hits);

    rig.net.clock.advance(1000);
    rig.respond(503, empty_answer);
    try testing.expectError(error.ProviderUnavailable, rig.search(query));
    rig.respond(200, empty_answer);
    const answered = try rig.search(query);
    defer answered.deinit();
    try testing.expectEqual(@as(u32, 3), rig.net.transport.requestCount());
    try testing.expectEqual(@as(usize, 0), answered.items.len);
}

const release_fixture_path = "fixtures/providers/musicbrainz-release-lookup.json";
const hot_space_mbid = "047a4aae-27f8-4f2d-92fb-214fd8dc865a";
const duet_mbid = "a6d3063b-c34f-46c7-b61c-dda4d94195a9";

fn readReleaseFixture() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, release_fixture_path, testing.allocator, .limited(1 << 20));
}

fn parseRelease(body: []const u8) !ReleaseLookup {
    return (ReleaseParser{}).parse(testing.allocator, body);
}

test "a release lookup yields the recording's track by position, with its own credit, and the release's title, artist, date and IDs" {
    const body = try readReleaseFixture();
    defer testing.allocator.free(body);
    const release = try parseRelease(body);
    defer release.deinit();

    try testing.expectEqualStrings(hot_space_mbid, release.id());
    const duet = (try release.enrichment(duet_mbid, null)).?;
    try testing.expectEqualStrings("Under Pressure", duet.track_title.?);
    try testing.expectEqualStrings("Queen & David Bowie", duet.track_artist.?);
    try testing.expectEqualStrings("Hot Space", duet.release_title.?);
    try testing.expectEqualStrings("Queen", duet.release_artist.?);
    try testing.expectEqualStrings("0383dadf-2a4e-4d10-a46a-e9e041da8eb3", duet.release_artist_mbid.?);
    try testing.expectEqualStrings("2014", duet.release_date.?);
    try testing.expectEqualStrings("3918b90b-340e-3779-9d7e-ba1593653498", duet.release_group_mbid.?);
    try testing.expectEqualStrings("6a31811e-e7ac-44d9-8345-7a6918130bf7", duet.release_track_mbid);
    try testing.expectEqual(@as(?u32, 7), duet.track_number);
    try testing.expectEqual(@as(?u32, 2), duet.disc_number);
    try testing.expectEqual(@as(?database.ReleaseEnrichment, null), try release.enrichment("af59c0c3-f3da-4bc2-ae24-dd2aa93021a4", null));
}

const twice_release =
    \\{"id":"047a4aae-27f8-4f2d-92fb-214fd8dc865a","title":"Twice","artist-credit":[
    \\  {"name":"James Blake","joinphrase":" & ","artist":{"id":"0383dadf-2a4e-4d10-a46a-e9e041da8eb3"}},
    \\  {"name":"Rosalía","joinphrase":"","artist":{"id":"5441c29d-3602-4898-b1a1-b77fa23b8e50"}}],
    \\ "media":[{"position":1,"tracks":[
    \\  {"id":"7938be9a-8cd9-40d0-b17f-9555cf5168c2","position":1,"number":"A1","title":"Song","recording":{"id":"a6d3063b-c34f-46c7-b61c-dda4d94195a9"}},
    \\  {"id":"23600855-11bc-4dca-89bd-b71cf2232d25","position":5,"number":"B2","title":"Song (reprise)","recording":{"id":"a6d3063b-c34f-46c7-b61c-dda4d94195a9"}}]}]}
;

test "a recording on a release twice takes the track at the file's tagged number, else the first, by position not vinyl number" {
    const release = try parseRelease(twice_release);
    defer release.deinit();

    const tagged = (try release.enrichment(duet_mbid, 5)).?;
    try testing.expectEqualStrings("23600855-11bc-4dca-89bd-b71cf2232d25", tagged.release_track_mbid);
    try testing.expectEqual(@as(?u32, 5), tagged.track_number);
    const untagged = (try release.enrichment(duet_mbid, null)).?;
    try testing.expectEqualStrings("7938be9a-8cd9-40d0-b17f-9555cf5168c2", untagged.release_track_mbid);
    try testing.expectEqual(@as(?u32, 1), untagged.track_number);
    const elsewhere = (try release.enrichment(duet_mbid, 9)).?;
    try testing.expectEqual(@as(?u32, 1), elsewhere.track_number);
}

test "a release credited to two artists names them both and gives no album-artist ID, and blanks stay unset" {
    const release = try parseRelease(twice_release);
    defer release.deinit();
    const track = (try release.enrichment(duet_mbid, null)).?;
    try testing.expectEqualStrings("James Blake & Rosalía", track.release_artist.?);
    try testing.expectEqual(@as(?[]const u8, null), track.release_artist_mbid);
    try testing.expectEqual(@as(?[]const u8, null), track.track_artist);
    try testing.expectEqual(@as(?[]const u8, null), track.release_date);
    try testing.expectEqual(@as(?[]const u8, null), track.release_group_mbid);
}

test "an answer that is not a release is refused as invalid" {
    try testing.expectError(error.InvalidProviderResponse, parseRelease("<html>"));
    try testing.expectError(error.InvalidProviderResponse, parseRelease("{\"recordings\":[]}"));
}

test "a release lookup asks for its recordings, credits and release group, is cached for thirty days, and a missing release is cached as refused" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-release?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.gateway.config.minimum_interval_ms = 0;
    rig.adapter.server = "http://127.0.0.1:5000/";
    const body = try readReleaseFixture();
    defer testing.allocator.free(body);
    rig.respond(200, body);

    try testing.expectError(error.InvalidMusicBrainzId, rig.adapter.lookUpRelease(testing.allocator, "Hot Space"));
    const first = try rig.adapter.lookUpRelease(testing.allocator, hot_space_mbid);
    defer first.deinit();
    try testing.expectEqualStrings(
        "http://127.0.0.1:5000/ws/2/release/" ++ hot_space_mbid ++ "?fmt=json&inc=recordings+artist-credits+release-groups",
        rig.net.transport.lastUrl(),
    );
    rig.net.clock.advance((rig.adapter.cache_ttl_seconds - 1) * 1000);
    const again = try rig.adapter.lookUpRelease(testing.allocator, hot_space_mbid);
    defer again.deinit();
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 1), rig.adapter.cache_hits);

    const missing = "aaaaaaaa-0000-4000-8000-000000000000";
    rig.respond(404, "{\"error\":\"Not Found\"}");
    try testing.expectError(error.ProviderRejectedRequest, rig.adapter.lookUpRelease(testing.allocator, missing));
    try testing.expectError(error.ProviderRejectedRequest, rig.adapter.lookUpRelease(testing.allocator, missing));
    try testing.expectEqual(@as(u32, 2), rig.net.transport.requestCount());
    rig.respond(503, "");
    try testing.expectError(error.ProviderUnavailable, rig.adapter.lookUpRelease(testing.allocator, "bbbbbbbb-0000-4000-8000-000000000000"));
}

test "a search keeps every release it lists for a recording, each once" {
    const body = try readFixture();
    defer testing.allocator.free(body);
    const list = try parseCandidates(testing.allocator, body, null);
    defer list.deinit();
    const live = findCandidate(list, "e3a15a94-41d6-45c0-bbc1-aae6137bcb7a").?;
    try testing.expectEqual(@as(usize, 3), live.release_mbids.len);
    try testing.expectEqualStrings("786a6852-4b41-44c9-a585-c65f9caa54a1", live.release_mbids[1]);
}

test "a search keeps each listed release's status, date and track count" {
    const body = try readFixture();
    defer testing.allocator.free(body);
    const list = try parseCandidates(testing.allocator, body, null);
    defer list.deinit();
    const fact = found: for (list.items) |candidate| {
        for (candidate.release_facts) |listed| {
            if (std.mem.eql(u8, listed.mbid, "047a4aae-27f8-4f2d-92fb-214fd8dc865a")) break :found listed;
        }
    } else null;
    try testing.expectEqualStrings("Official", fact.?.status.?);
    try testing.expectEqualStrings("2014", fact.?.date.?);
    try testing.expectEqual(@as(?u32, 19), fact.?.track_count);
    for (list.items) |candidate| try testing.expectEqual(candidate.release_mbids.len, candidate.release_facts.len);
}

const amine_mbid = "12398bf3-1b99-47b7-930c-f3956773f35a";

fn readArtistFixture() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/providers/musicbrainz-artist-lookup.json", testing.allocator, .limited(64 * 1024));
}

test "an artist lookup yields the life span, type, Wikidata item, Commons image and links by kind" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-artist?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try readArtistFixture();
    defer testing.allocator.free(body);
    rig.respond(200, body);

    const artist = try rig.adapter.lookUpArtist(testing.allocator, amine_mbid);
    defer artist.deinit();
    try testing.expectEqualStrings(
        "https://musicbrainz.org/ws/2/artist/" ++ amine_mbid ++ "?fmt=json&inc=url-rels+genres+artist-rels",
        rig.net.transport.lastUrl(),
    );
    try testing.expectEqualStrings("Person", artist.artist_type.?);
    try testing.expectEqual(@as(?i32, 1994), artist.begin_year);
    try testing.expectEqual(@as(?i32, null), artist.end_year);
    try testing.expect(!artist.ended);
    try testing.expectEqualStrings("Q27830860", artist.wikidata_id.?);
    try testing.expectEqualStrings("Amine performing on Jimmy Fallon in 2017 (crop).png", artist.commons_image_file.?);
    try testing.expectEqual(@as(usize, 19), artist.links.len);
    var seen: std.EnumSet(database.ArtistLinkKind) = .initEmpty();
    for (artist.links) |link| seen.insert(link.kind);
    for ([_]database.ArtistLinkKind{
        .official, .wikidata, .discogs,   .lastfm, .soundcloud, .youtube, .spotify, .apple_music,
        .tidal,    .deezer,   .instagram, .x,      .facebook,   .tiktok,  .other,
    }) |kind| try testing.expect(seen.contains(kind));
    try testing.expectError(error.InvalidMusicBrainzId, rig.adapter.lookUpArtist(testing.allocator, "Aminé"));
    try testing.expectEqual(@as(usize, 5), artist.genres.len);
    try testing.expectEqualStrings("hip hop", artist.genres[0].name);
    try testing.expectEqual(@as(u32, 2), artist.genres[0].count);
}

test "a release group lookup asks for URL relations and genres and yields the current Wikidata and Wikipedia links" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-release-group?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/providers/musicbrainz-release-group-lookup.json", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(body);
    rig.respond(200, body);

    const group_mbid = "3918b90b-340e-3779-9d7e-ba1593653498";
    const group = try rig.adapter.lookUpReleaseGroup(testing.allocator, group_mbid);
    defer group.deinit();
    try testing.expectEqualStrings(
        "https://musicbrainz.org/ws/2/release-group/" ++ group_mbid ++ "?fmt=json&inc=url-rels+genres",
        rig.net.transport.lastUrl(),
    );
    try testing.expectEqualStrings("Q1193613", group.wikidata_id.?);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Hot_Space", group.wikipedia_url.?);
    try testing.expectEqual(@as(usize, 6), group.genres.len);
    try testing.expectEqualStrings("synth-pop", group.genres[3].name);
    try testing.expectEqualStrings("Album", group.primary_type.?);
    var buffer: [fill_genres_max][]const u8 = undefined;
    const top = topGenres(group.genres, &buffer);
    try testing.expectEqual(@as(usize, 4), top.len);
    try testing.expectEqualStrings("rock", top[0]);
    try testing.expectEqualStrings("synth-pop", top[3]);
    try testing.expectError(error.InvalidMusicBrainzId, rig.adapter.lookUpReleaseGroup(testing.allocator, "Hot Space"));
}

test "an image relationship off Commons is ignored, and an ended relationship is no link" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-artist-image?mode=memory&cache=shared");
    defer rig.deinit();
    rig.respond(200,
        \\{"id":"12398bf3-1b99-47b7-930c-f3956773f35a","life-span":{"begin":"1968","end":"1974-11-25","ended":true},
        \\ "relations":[
        \\  {"type":"image","target-type":"url","url":{"resource":"https://example.org/wiki/File:Fake.jpg"}},
        \\  {"type":"image","target-type":"url","url":{"resource":"https://commons.wikimedia.org/wiki/Category:Nick_Drake"}},
        \\  {"type":"social network","target-type":"url","ended":true,"url":{"resource":"https://twitter.com/old"}},
        \\  {"type":"member of band","target-type":"artist"}]}
    );
    const artist = try rig.adapter.lookUpArtist(testing.allocator, amine_mbid);
    defer artist.deinit();
    try testing.expectEqual(@as(?[]const u8, null), artist.commons_image_file);
    try testing.expectEqual(@as(usize, 0), artist.links.len);
    try testing.expectEqual(@as(?i32, 1968), artist.begin_year);
    try testing.expectEqual(@as(?i32, 1974), artist.end_year);
    try testing.expect(artist.ended);
    try testing.expectEqual(@as(?[]const u8, null), artist.artist_type);
}

test "a genre fill keeps the three most voted genres and those tied with the third, at most five" {
    var buffer: [fill_genres_max][]const u8 = undefined;
    const tied = [_]Genre{
        .{ .name = "a", .count = 1 }, .{ .name = "b", .count = 2 }, .{ .name = "c", .count = 1 },
        .{ .name = "d", .count = 1 }, .{ .name = "e", .count = 1 }, .{ .name = "f", .count = 1 },
        .{ .name = "g", .count = 1 },
    };
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "b", "a", "c", "d", "e" }), topGenres(&tied, &buffer));
    const distinct = [_]Genre{
        .{ .name = "a", .count = 9 }, .{ .name = "b", .count = 8 }, .{ .name = "c", .count = 7 }, .{ .name = "d", .count = 6 },
    };
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b", "c" }), topGenres(&distinct, &buffer));
    try testing.expectEqual(@as(usize, 0), topGenres(&.{}, &buffer).len);
}
