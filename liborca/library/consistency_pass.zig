const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const scanner = @import("scanner.zig");

const genre_alias = metadata.genre_alias;
const sqlite = database.sqlite;

pub const CancellationToken = scanner.CancellationToken;

/// What kind of inconsistency a metadata issue names.
pub const Category = enum(u8) {
    /// A release's tracks state more than one album artist.
    album_artist,
    /// A release's tracks state different dates, or a date that is not
    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD`.
    dates,
    /// A disc's tracks repeat a number or state none.
    track_numbering,
    /// A release's tracks spell one genre more than one way.
    genre_variants,
    /// A release's album, album artist or date differs from the MusicBrainz
    /// release its accepted matches name.
    musicbrainz_differs,
};

/// Where a metadata issue stands.
pub const State = enum(u8) { open, skipped, applied };

/// The value a metadata issue is about.
pub const Field = enum(u8) { album, album_artist, date, track_number, genre };

pub const max_proposals = database.repository.max_page;

pub const Option = struct {
    value: []const u8,
    tracks: u32,
    musicbrainz: bool = false,
    /// The title of the one track stating the value.
    sample: ?[]const u8 = null,
    /// A date every other date of a dates issue is a less precise form of.
    precise: bool = false,
};

pub const Member = struct {
    track_id: i64,
    file_id: i64,
    current: ?[]const u8,
    locked: bool,
    /// The number a track_numbering issue gives this track, when it changes.
    renumbered: ?[]const u8 = null,
    /// Every genre a genre_variants issue's track states, one per part.
    genres: []const []const u8 = &.{},
};

pub const Issue = struct {
    release_id: i64,
    category: Category,
    field: Field,
    /// The folded genre key of a genre_variants issue; empty otherwise.
    key: []const u8 = "",
    fingerprint: i64,
    options: []Option,
    members: []Member,
    /// The lowest number a track_numbering issue fills below the highest
    /// number its disc states.
    gap: ?i64 = null,

    /// The value choosing `value` gives `member`, or null when it keeps its
    /// own.
    pub fn proposed(self: *const Issue, member: Member, value: []const u8) ?[]const u8 {
        if (self.category == .track_numbering) return member.renumbered;
        if (member.current) |current| if (std.mem.eql(u8, current, value)) return null;
        return value;
    }

    pub fn matches(self: *const Issue, category: Category, field: Field, key: []const u8) bool {
        return self.category == category and self.field == field and std.mem.eql(u8, self.key, key);
    }
};

pub const renumber_option = "Next free numbers";

pub const Result = struct {
    releases_seen: u64 = 0,
    /// Open issues the pass wrote.
    issues: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
};

pub const ConsistencyPass = struct {
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    cancellation: ?*const CancellationToken = null,
    /// Releases examined so far.
    progress: ?*std.atomic.Value(u64) = null,
    /// Releases per bounded commit.
    batch_size: usize = 128,

    pub fn run(self: *ConsistencyPass) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        const limit: i64 = @intCast(@min(self.batch_size, database.repository.max_page));
        const db = self.library.database;
        var result: Result = .{};
        var select = try db.prepare("SELECT id FROM releases WHERE id > ?1 ORDER BY id LIMIT ?2;");
        defer select.deinit();
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var cursor: i64 = 0;
        while (true) {
            if (self.isCancelled()) {
                result.cancelled = true;
                break;
            }
            _ = arena.reset(.retain_capacity);
            try select.bindInt64(1, cursor);
            try select.bindInt64(2, limit);
            var first: ?i64 = null;
            var seen: u64 = 0;
            while (try select.step() == .row) {
                const id = select.columnInt64(0);
                if (first == null) first = id;
                cursor = id;
                seen += 1;
            }
            try select.reset();
            const lowest = first orelse break;
            result.issues += try refresh(arena.allocator(), self.library, lowest, cursor);
            result.batches_committed += 1;
            result.releases_seen += seen;
            if (self.progress) |counter| counter.store(result.releases_seen, .release);
        }
        return result;
    }

    fn isCancelled(self: *const ConsistencyPass) bool {
        const token = self.cancellation orelse return false;
        return token.checkpoint();
    }
};

/// Replaces the open issues of the releases with ids in `first..=last` in one
/// transaction, keeping skipped issues whose values have not changed.
/// Returns the open issues written.
pub fn refresh(allocator: std.mem.Allocator, library: *database.LibraryDatabase, first: i64, last: i64) !u64 {
    const db = library.database;
    library.write_lane.acquire();
    defer library.write_lane.release();
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};

    const issues = try detect(allocator, db, first, last);

    const Skipped = struct { id: i64, release_id: i64, category: i64, field: []const u8, key: []const u8, fingerprint: i64 };
    var skipped: std.ArrayList(Skipped) = .empty;
    {
        var statement = try db.prepare(
            \\SELECT id, release_id, category, field, COALESCE(current, ''), fingerprint
            \\FROM metadata_proposals
            \\WHERE release_id BETWEEN ?1 AND ?2 AND state = 1 AND id = group_id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, first);
        try statement.bindInt64(2, last);
        while (try statement.step() == .row) try skipped.append(allocator, .{
            .id = statement.columnInt64(0),
            .release_id = statement.columnInt64(1),
            .category = statement.columnInt64(2),
            .field = try allocator.dupe(u8, statement.columnText(3)),
            .key = try allocator.dupe(u8, statement.columnText(4)),
            .fingerprint = statement.columnInt64(5),
        });
    }
    {
        var statement = try db.prepare(
            "DELETE FROM metadata_proposals WHERE release_id BETWEEN ?1 AND ?2 AND state = 0;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, first);
        try statement.bindInt64(2, last);
        _ = try statement.step();
    }

    const kept = try allocator.alloc(bool, issues.len);
    @memset(kept, false);
    {
        var forget = try db.prepare("DELETE FROM metadata_proposals WHERE group_id = ?1;");
        defer forget.deinit();
        for (skipped.items) |entry| {
            const still = for (issues, 0..) |issue, index| {
                if (issue.release_id == entry.release_id and
                    @backingInt(issue.category) == entry.category and
                    std.mem.eql(u8, @tagName(issue.field), entry.field) and
                    std.mem.eql(u8, issue.key, entry.key) and
                    issue.fingerprint == entry.fingerprint) break index;
            } else null;
            if (still) |index| {
                kept[index] = true;
                continue;
            }
            try forget.bindInt64(1, entry.id);
            _ = try forget.step();
            try forget.reset();
        }
    }

    var writer = try Writer.init(db);
    defer writer.deinit();
    var written: u64 = 0;
    for (issues, kept) |*issue, skip| {
        if (skip) continue;
        try writer.write(allocator, issue);
        written += 1;
    }
    try db.exec("COMMIT;");
    return written;
}

const Writer = struct {
    db: sqlite.Database,
    header: sqlite.Statement,
    link: sqlite.Statement,
    member: sqlite.Statement,

    fn init(db: sqlite.Database) !Writer {
        var header = try db.prepare(
            \\INSERT INTO metadata_proposals(release_id, category, field, current, gap, state, fingerprint, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, unixepoch());
        );
        errdefer header.deinit();
        var link = try db.prepare("UPDATE metadata_proposals SET group_id = id WHERE id = ?1;");
        errdefer link.deinit();
        const member = try db.prepare(
            \\INSERT INTO metadata_proposals(group_id, release_id, category, field, track_id, current, proposed,
            \\    reason, option, tracks, state, fingerprint, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 0, ?11, unixepoch());
        );
        return .{ .db = db, .header = header, .link = link, .member = member };
    }

    fn deinit(self: *Writer) void {
        self.header.deinit();
        self.link.deinit();
        self.member.deinit();
    }

    fn write(self: *Writer, allocator: std.mem.Allocator, issue: *const Issue) !void {
        const field = @tagName(issue.field);
        try self.header.bindInt64(1, issue.release_id);
        try self.header.bindInt64(2, @backingInt(issue.category));
        try self.header.bindText(3, field);
        try self.header.bindOptionalText(4, if (issue.key.len == 0) null else issue.key);
        try self.header.bindOptionalInt64(5, issue.gap);
        try self.header.bindInt64(6, issue.fingerprint);
        if (try self.header.step() != .done) return error.SqlFailed;
        try self.header.reset();
        const group_id = self.db.lastInsertRowId();
        try self.link.bindInt64(1, group_id);
        if (try self.link.step() != .done) return error.SqlFailed;
        try self.link.reset();

        for (issue.options, 0..) |option, index| {
            const reason = try support(allocator, issue.category, option);
            try self.insert(group_id, issue, field, null, null, option.value, reason, @intCast(index), option.tracks);
        }
        const recommended = if (issue.options.len > 0) issue.options[0].value else "";
        var proposals: usize = 0;
        for (issue.members) |member| {
            if (member.locked) continue;
            const value = issue.proposed(member, recommended) orelse continue;
            if (proposals == max_proposals) break;
            proposals += 1;
            try self.insert(group_id, issue, field, member.track_id, member.current, value, null, null, null);
        }
    }

    fn insert(
        self: *Writer,
        group_id: i64,
        issue: *const Issue,
        field: []const u8,
        track_id: ?i64,
        current: ?[]const u8,
        proposed: []const u8,
        reason: ?[]const u8,
        option: ?i64,
        tracks: ?u32,
    ) !void {
        const statement = &self.member;
        try statement.bindInt64(1, group_id);
        try statement.bindInt64(2, issue.release_id);
        try statement.bindInt64(3, @backingInt(issue.category));
        try statement.bindText(4, field);
        try statement.bindOptionalInt64(5, track_id);
        try statement.bindOptionalText(6, current);
        try statement.bindText(7, proposed);
        try statement.bindOptionalText(8, reason);
        try statement.bindOptionalInt64(9, option);
        try statement.bindOptionalInt64(10, if (tracks) |count| @as(i64, count) else null);
        try statement.bindInt64(11, issue.fingerprint);
        if (try statement.step() != .done) return error.SqlFailed;
        try statement.reset();
    }
};

/// "16 tracks · MusicBrainz agrees", "1 track · Solo (Reprise)", "2 tracks",
/// "MusicBrainz", "Year of the dates stated" or "2 tracks renumbered".
pub fn support(allocator: std.mem.Allocator, category: Category, option: Option) ![]const u8 {
    if (option.tracks == 0) return if (option.musicbrainz) "MusicBrainz" else "Year of the dates stated";
    if (option.tracks == 1 and !option.musicbrainz and category != .track_numbering)
        if (option.sample) |title| if (title.len != 0) return std.fmt.allocPrint(allocator, "1 track · {s}", .{title});
    return std.fmt.allocPrint(allocator, "{d} {s}{s}", .{
        option.tracks,
        if (option.tracks == 1) "track" else "tracks",
        if (category == .track_numbering) " renumbered" else if (option.musicbrainz) " · MusicBrainz agrees" else "",
    });
}

const Row = struct {
    track_id: i64,
    release_id: i64,
    file_id: i64,
    path: []const u8,
    album: ?[]const u8,
    album_locked: bool,
    album_artist: ?[]const u8,
    album_artist_locked: bool,
    date: ?[]const u8,
    date_locked: bool,
    track_number: ?i64,
    track_number_locked: bool,
    disc: i64,
    title: []const u8,
    genres: std.ArrayList([]const u8) = .empty,
    musicbrainz: ?Release = null,
};

const Release = struct {
    mbid: []const u8,
    title: ?[]const u8,
    artist: ?[]const u8,
    date: ?[]const u8,
};

const effective_text =
    \\CASE WHEN {0s}.locked = 1 THEN {0s}.value ELSE COALESCE(NULLIF(g.{1s}, ''), {0s}.value) END,
    \\COALESCE({0s}.locked, 0)
;

const rows_sql = std.fmt.comptimePrint(
    \\SELECT t.id, t.release_id, t.preferred_file_id,
    \\    COALESCE((SELECT uri FROM locations WHERE file_id = t.preferred_file_id ORDER BY id LIMIT 1), ''),
    \\    {s}, {s}, {s},
    \\    CASE WHEN n.locked = 1 THEN CAST(n.value AS INTEGER)
    \\        ELSE COALESCE(g.track_number, CAST(n.value AS INTEGER)) END,
    \\    COALESCE(n.locked, 0),
    \\    COALESCE(CASE WHEN d.locked = 1 THEN CAST(d.value AS INTEGER)
    \\        ELSE COALESCE(g.disc_number, CAST(d.value AS INTEGER)) END, 1),
    \\    COALESCE(t.title, '')
    \\FROM tracks t
    \\LEFT JOIN observed_file_tags g ON g.file_id = t.preferred_file_id
    \\LEFT JOIN orca_metadata_values al ON al.file_id = t.preferred_file_id AND al.field = {d}
    \\LEFT JOIN orca_metadata_values aa ON aa.file_id = t.preferred_file_id AND aa.field = {d}
    \\LEFT JOIN orca_metadata_values dt ON dt.file_id = t.preferred_file_id AND dt.field = {d}
    \\LEFT JOIN orca_metadata_values n ON n.file_id = t.preferred_file_id AND n.field = {d}
    \\LEFT JOIN orca_metadata_values d ON d.file_id = t.preferred_file_id AND d.field = {d}
    \\WHERE t.release_id BETWEEN ?1 AND ?2 AND t.preferred_file_id IS NOT NULL
    \\ORDER BY t.release_id, t.id;
, .{
    std.fmt.comptimePrint(effective_text, .{ "al", "album" }),
    std.fmt.comptimePrint(effective_text, .{ "aa", "album_artist" }),
    std.fmt.comptimePrint(effective_text, .{ "dt", "date" }),
    @backingInt(metadata.Field.album),
    @backingInt(metadata.Field.album_artist),
    @backingInt(metadata.Field.date),
    @backingInt(metadata.Field.track_number),
    @backingInt(metadata.Field.disc_number),
});

/// The issues the releases with ids in `first..=last` have now. Every slice
/// is allocated from `allocator`, which is meant to be an arena.
pub fn detect(allocator: std.mem.Allocator, db: sqlite.Database, first: i64, last: i64) ![]Issue {
    var rows: std.ArrayList(Row) = .empty;
    var index_of: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    {
        var statement = try db.prepare(rows_sql);
        defer statement.deinit();
        try statement.bindInt64(1, first);
        try statement.bindInt64(2, last);
        while (try statement.step() == .row) {
            try index_of.put(allocator, statement.columnInt64(0), rows.items.len);
            try rows.append(allocator, .{
                .track_id = statement.columnInt64(0),
                .release_id = statement.columnInt64(1),
                .file_id = statement.columnInt64(2),
                .path = try allocator.dupe(u8, statement.columnText(3)),
                .album = try optionalText(allocator, statement, 4),
                .album_locked = statement.columnInt64(5) != 0,
                .album_artist = try optionalText(allocator, statement, 6),
                .album_artist_locked = statement.columnInt64(7) != 0,
                .date = try optionalText(allocator, statement, 8),
                .date_locked = statement.columnInt64(9) != 0,
                .track_number = if (statement.columnIsNull(10)) null else statement.columnInt64(10),
                .track_number_locked = statement.columnInt64(11) != 0,
                .disc = statement.columnInt64(12),
                .title = try allocator.dupe(u8, statement.columnText(13)),
            });
        }
    }
    if (rows.items.len == 0) return &.{};
    {
        var statement = try db.prepare(
            \\SELECT t.id, o.value FROM tracks t
            \\JOIN observed_file_genres o ON o.file_id = t.preferred_file_id
            \\WHERE t.release_id BETWEEN ?1 AND ?2
            \\  AND NOT EXISTS (SELECT 1 FROM track_genres u WHERE u.track_id = t.id AND u.provenance = 1)
            \\UNION ALL
            \\SELECT t.id, n.name FROM tracks t
            \\JOIN track_genres u ON u.track_id = t.id AND u.provenance = 1
            \\JOIN genres n ON n.id = u.genre_id
            \\WHERE t.release_id BETWEEN ?1 AND ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, first);
        try statement.bindInt64(2, last);
        while (try statement.step() == .row) {
            const index = index_of.get(statement.columnInt64(0)) orelse continue;
            try rows.items[index].genres.append(allocator, try allocator.dupe(u8, statement.columnText(1)));
        }
    }
    {
        var statement = try db.prepare(
            \\SELECT t.id, p.payload FROM tracks t
            \\JOIN identification_proposals p ON p.file_id = t.preferred_file_id AND p.state = ?3
            \\WHERE t.release_id BETWEEN ?1 AND ?2
            \\ORDER BY p.id DESC;
        );
        defer statement.deinit();
        try statement.bindInt64(1, first);
        try statement.bindInt64(2, last);
        try statement.bindInt64(3, @backingInt(database.ProposalState.accepted));
        while (try statement.step() == .row) {
            const index = index_of.get(statement.columnInt64(0)) orelse continue;
            if (rows.items[index].musicbrainz != null) continue;
            const parsed = database.ProposalPayload.parse(allocator, statement.columnBlob(1)) catch |err| switch (err) {
                error.InvalidProposalPayload => continue,
                error.OutOfMemory => return err,
            };
            const payload = parsed.value;
            if (!payload.isEnriched() or !metadata.isMusicBrainzId(payload.release_mbid.?)) continue;
            rows.items[index].musicbrainz = .{
                .mbid = payload.release_mbid.?,
                .title = payload.release_title,
                .artist = payload.release_artist,
                .date = payload.release_date,
            };
        }
    }

    var issues: std.ArrayList(Issue) = .empty;
    var start: usize = 0;
    while (start < rows.items.len) {
        var end = start + 1;
        while (end < rows.items.len and rows.items[end].release_id == rows.items[start].release_id) end += 1;
        try detectRelease(allocator, rows.items[start..end], &issues);
        start = end;
    }
    return issues.items;
}

fn optionalText(allocator: std.mem.Allocator, statement: sqlite.Statement, column: c_int) !?[]const u8 {
    if (statement.columnIsNull(column)) return null;
    const text = statement.columnText(column);
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
}

fn detectRelease(allocator: std.mem.Allocator, rows: []Row, issues: *std.ArrayList(Issue)) !void {
    const release = musicbrainzRelease(rows);
    const artist_issue = try valueIssue(allocator, rows, .album_artist, .album_artist, if (release) |r| r.artist else null);
    if (artist_issue) |issue| try issues.append(allocator, issue);
    const date_issue = try valueIssue(allocator, rows, .dates, .date, if (release) |r| r.date else null);
    if (date_issue) |issue| try issues.append(allocator, issue);
    if (try numberingIssue(allocator, rows)) |issue| try issues.append(allocator, issue);
    try genreIssues(allocator, rows, issues);
    if (release) |found| {
        if (try differsIssue(allocator, rows, .album, found.title)) |issue| try issues.append(allocator, issue);
        if (artist_issue == null)
            if (try differsIssue(allocator, rows, .album_artist, found.artist)) |issue| try issues.append(allocator, issue);
        if (date_issue == null)
            if (try differsIssue(allocator, rows, .date, found.date)) |issue| try issues.append(allocator, issue);
    }
}

/// The MusicBrainz release most of the release's tracks were matched to.
fn musicbrainzRelease(rows: []const Row) ?Release {
    var best: ?Release = null;
    var best_count: usize = 0;
    for (rows) |row| {
        const candidate = row.musicbrainz orelse continue;
        var count: usize = 0;
        for (rows) |other| {
            const named = other.musicbrainz orelse continue;
            if (std.mem.eql(u8, named.mbid, candidate.mbid)) count += 1;
        }
        if (count > best_count) {
            best = candidate;
            best_count = count;
        }
    }
    return best;
}

fn textOf(row: Row, field: Field) ?[]const u8 {
    return switch (field) {
        .album => row.album,
        .album_artist => row.album_artist,
        .date => row.date,
        .track_number, .genre => unreachable,
    };
}

fn lockedOf(row: Row, field: Field) bool {
    return switch (field) {
        .album => row.album_locked,
        .album_artist => row.album_artist_locked,
        .date => row.date_locked,
        .track_number => row.track_number_locked,
        .genre => false,
    };
}

fn addCount(allocator: std.mem.Allocator, options: *std.ArrayList(Option), value: []const u8, title: []const u8) !void {
    for (options.items) |*option| if (std.mem.eql(u8, option.value, value)) {
        option.tracks += 1;
        option.sample = null;
        return;
    };
    try options.append(allocator, .{ .value = value, .tracks = 1, .sample = title });
}

fn markMusicBrainz(allocator: std.mem.Allocator, options: *std.ArrayList(Option), value: ?[]const u8) !void {
    const stated = value orelse return;
    if (stated.len == 0) return;
    for (options.items) |*option| if (std.mem.eql(u8, option.value, stated)) {
        option.musicbrainz = true;
        return;
    };
    try options.append(allocator, .{ .value = stated, .tracks = 0, .musicbrainz = true });
}

fn optionBefore(_: void, a: Option, b: Option) bool {
    if (a.musicbrainz != b.musicbrainz) return a.musicbrainz;
    if (a.precise != b.precise) return a.precise;
    if (a.tracks != b.tracks) return a.tracks > b.tracks;
    return std.mem.lessThan(u8, a.value, b.value);
}

/// Marks the one date every other date is a less precise form of, as
/// `2016-08-20` is of `2016-08` and `2016`.
fn markPrecise(options: []Option) void {
    if (options.len < 2) return;
    var longest: usize = 0;
    for (options, 0..) |option, index| {
        if (option.value.len > options[longest].value.len) longest = index;
    }
    for (options, 0..) |option, index| {
        if (index == longest) continue;
        if (option.value.len == options[longest].value.len) return;
        if (!std.mem.startsWith(u8, options[longest].value, option.value)) return;
    }
    options[longest].precise = true;
}

fn valueIssue(
    allocator: std.mem.Allocator,
    rows: []const Row,
    category: Category,
    field: Field,
    musicbrainz: ?[]const u8,
) !?Issue {
    var options: std.ArrayList(Option) = .empty;
    var invalid = false;
    var missing = false;
    var distinct: usize = 0;
    for (rows) |row| {
        const value = textOf(row, field) orelse {
            missing = true;
            continue;
        };
        if (category == .dates and !validDate(value)) {
            invalid = true;
            continue;
        }
        try addCount(allocator, &options, value, row.title);
    }
    distinct = options.items.len;
    const undated = category == .dates and missing and distinct > 0;
    if (distinct < 2 and !invalid and !undated) return null;
    if (category == .dates) markPrecise(options.items);
    if (category == .dates and distinct == 0) {
        for (rows) |row| {
            const value = row.date orelse continue;
            if (yearIn(value)) |found| {
                for (options.items) |option| {
                    if (std.mem.eql(u8, option.value, found)) break;
                } else try options.append(allocator, .{ .value = found, .tracks = 0 });
            }
        }
    }
    if (category != .dates or (musicbrainz != null and validDate(musicbrainz.?)))
        try markMusicBrainz(allocator, &options, musicbrainz);
    std.mem.sort(Option, options.items, {}, optionBefore);
    return try finish(allocator, rows, category, field, "", options.items);
}

fn differsIssue(allocator: std.mem.Allocator, rows: []const Row, field: Field, musicbrainz: ?[]const u8) !?Issue {
    const stated = musicbrainz orelse return null;
    if (stated.len == 0) return null;
    if (field == .date and !validDate(stated)) return null;
    var options: std.ArrayList(Option) = .empty;
    for (rows) |row| if (textOf(row, field)) |value| try addCount(allocator, &options, value, row.title);
    if (options.items.len > 1) return null;
    if (options.items.len == 1 and std.mem.eql(u8, options.items[0].value, stated)) return null;
    try markMusicBrainz(allocator, &options, stated);
    std.mem.sort(Option, options.items, {}, optionBefore);
    return try finish(allocator, rows, .musicbrainz_differs, field, "", options.items);
}

fn finish(
    allocator: std.mem.Allocator,
    rows: []const Row,
    category: Category,
    field: Field,
    key: []const u8,
    options: []Option,
) !Issue {
    const members = try allocator.alloc(Member, rows.len);
    var hasher = fingerprintStart(category, field, key);
    for (rows, members) |row, *member| {
        member.* = .{
            .track_id = row.track_id,
            .file_id = row.file_id,
            .current = textOf(row, field),
            .locked = lockedOf(row, field),
        };
        hashMember(&hasher, row.file_id, member.current);
    }
    return .{
        .release_id = rows[0].release_id,
        .category = category,
        .field = field,
        .key = key,
        .fingerprint = @bitCast(hasher.final()),
        .options = options,
        .members = members,
    };
}

fn fingerprintStart(category: Category, field: Field, key: []const u8) std.hash.Wyhash {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(&.{ @backingInt(category), @backingInt(field) });
    hasher.update(key);
    hasher.update(&.{0});
    return hasher;
}

fn hashMember(hasher: *std.hash.Wyhash, file_id: i64, value: ?[]const u8) void {
    hasher.update(std.mem.asBytes(&file_id));
    if (value) |text| {
        hasher.update(&.{1});
        hasher.update(text);
        hasher.update(&.{0});
    } else hasher.update(&.{0});
}

/// `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, with a month and day that exist.
pub fn validDate(value: []const u8) bool {
    if (value.len != 4 and value.len != 7 and value.len != 10) return false;
    for (value, 0..) |byte, index| {
        const dash = index == 4 or index == 7;
        if (dash) {
            if (byte != '-') return false;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    if (value.len >= 7) {
        const month = std.fmt.parseUnsigned(u8, value[5..7], 10) catch return false;
        if (month == 0 or month > 12) return false;
        if (value.len == 10) {
            const day = std.fmt.parseUnsigned(u8, value[8..10], 10) catch return false;
            const days_in_month = [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            if (day == 0 or day > days_in_month[month - 1]) return false;
        }
    }
    return true;
}

fn yearIn(value: []const u8) ?[]const u8 {
    if (value.len < 4) return null;
    var index: usize = 0;
    while (index + 4 <= value.len) : (index += 1) {
        const candidate = value[index .. index + 4];
        const digits = for (candidate) |byte| {
            if (!std.ascii.isDigit(byte)) break false;
        } else true;
        if (!digits) continue;
        if (index > 0 and std.ascii.isDigit(value[index - 1])) continue;
        if (index + 4 < value.len and std.ascii.isDigit(value[index + 4])) continue;
        if (candidate[0] == '1' or candidate[0] == '2') return candidate;
    }
    return null;
}

fn positionBefore(rows: []const Row, a: usize, b: usize) bool {
    const left = rows[a];
    const right = rows[b];
    if (left.disc != right.disc) return left.disc < right.disc;
    const order = std.mem.order(u8, left.path, right.path);
    if (order != .eq) return order == .lt;
    return left.track_id < right.track_id;
}

fn numberingIssue(allocator: std.mem.Allocator, rows: []const Row) !?Issue {
    const order = try allocator.alloc(usize, rows.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, rows, positionBefore);

    const renumbered = try allocator.alloc(?i64, rows.len);
    @memset(renumbered, null);
    var used: std.AutoHashMapUnmanaged(i64, void) = .empty;
    var changed: u32 = 0;
    var gap: ?i64 = null;
    var start: usize = 0;
    while (start < order.len) {
        const disc = rows[order[start]].disc;
        var end = start + 1;
        while (end < order.len and rows[order[end]].disc == disc) end += 1;
        used.clearRetainingCapacity();
        var defective: std.ArrayList(usize) = .empty;
        var highest: i64 = 0;
        for (order[start..end]) |index| {
            const number = rows[index].track_number orelse 0;
            if (number <= 0 or used.contains(number)) {
                try defective.append(allocator, index);
            } else {
                try used.put(allocator, number, {});
                highest = @max(highest, number);
            }
        }
        var next: i64 = 1;
        for (defective.items) |index| {
            while (used.contains(next)) next += 1;
            if (gap == null and next < highest) gap = next;
            renumbered[index] = next;
            try used.put(allocator, next, {});
            changed += 1;
        }
        start = end;
    }
    if (changed == 0) return null;

    const members = try allocator.alloc(Member, rows.len);
    var hasher = fingerprintStart(.track_numbering, .track_number, "");
    for (order, 0..) |index, slot| {
        const row = rows[index];
        const current = if (row.track_number) |number| try std.fmt.allocPrint(allocator, "{d}", .{number}) else null;
        members[slot] = .{
            .track_id = row.track_id,
            .file_id = row.file_id,
            .current = current,
            .locked = row.track_number_locked,
            .renumbered = if (renumbered[index]) |number| try std.fmt.allocPrint(allocator, "{d}", .{number}) else null,
        };
        hasher.update(std.mem.asBytes(&row.disc));
        hashMember(&hasher, row.file_id, current);
    }
    const options = try allocator.alloc(Option, 1);
    options[0] = .{ .value = renumber_option, .tracks = changed };
    return .{
        .release_id = rows[0].release_id,
        .category = .track_numbering,
        .field = .track_number,
        .fingerprint = @bitCast(hasher.final()),
        .options = options,
        .members = members,
        .gap = gap,
    };
}

const Spelling = struct { track_id: i64, value: []const u8, title: []const u8 };

fn genreIssues(allocator: std.mem.Allocator, rows: []const Row, issues: *std.ArrayList(Issue)) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    var spellings: std.ArrayList(std.ArrayList(Spelling)) = .empty;
    for (rows) |row| for (row.genres.items) |value| {
        var parts = genre_alias.parts(value);
        while (parts.next()) |part| {
            const folded = try genre_alias.fold(allocator, part);
            if (folded.key.len == 0) continue;
            const slot = for (keys.items, 0..) |key, index| {
                if (std.mem.eql(u8, key, folded.key)) break index;
            } else blk: {
                try keys.append(allocator, folded.key);
                try spellings.append(allocator, .empty);
                break :blk keys.items.len - 1;
            };
            const list = &spellings.items[slot];
            const seen = for (list.items) |spelling| {
                if (spelling.track_id == row.track_id) break true;
            } else false;
            if (!seen) try list.append(allocator, .{
                .track_id = row.track_id,
                .value = std.mem.trim(u8, part, " \t\r\n"),
                .title = row.title,
            });
        }
    };
    for (keys.items, spellings.items) |key, list| {
        var options: std.ArrayList(Option) = .empty;
        for (list.items) |spelling| try addCount(allocator, &options, spelling.value, spelling.title);
        if (options.items.len < 2) continue;
        std.mem.sort(Option, options.items, {}, optionBefore);
        const members = try allocator.alloc(Member, list.items.len);
        var hasher = fingerprintStart(.genre_variants, .genre, key);
        for (list.items, members) |spelling, *member| {
            const row = for (rows) |row| {
                if (row.track_id == spelling.track_id) break row;
            } else unreachable;
            var parts: std.ArrayList([]const u8) = .empty;
            for (row.genres.items) |value| {
                var split = genre_alias.parts(value);
                while (split.next()) |part| {
                    const trimmed = std.mem.trim(u8, part, " \t\r\n");
                    if (trimmed.len != 0) try parts.append(allocator, trimmed);
                }
            }
            member.* = .{
                .track_id = spelling.track_id,
                .file_id = row.file_id,
                .current = spelling.value,
                .locked = false,
                .genres = parts.items,
            };
            hashMember(&hasher, row.file_id, spelling.value);
        }
        try issues.append(allocator, .{
            .release_id = rows[0].release_id,
            .category = .genre_variants,
            .field = .genre,
            .key = key,
            .fingerprint = @bitCast(hasher.final()),
            .options = options.items,
            .members = members,
        });
    }
}

const testing = std.testing;

fn openTestLibrary(name: [:0]const u8) !database.LibraryDatabase {
    return database.LibraryDatabase.open(testing.allocator, testing.io, name);
}

fn observe(library: *database.LibraryDatabase, uri: []const u8, values: metadata.ObservedTags) !i64 {
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = uri,
        .state = .present,
    });
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = values });
    return file_id;
}

fn project(library: *database.LibraryDatabase) !void {
    var projection: @import("projection.zig").Projection = .{ .allocator = testing.allocator, .library = library };
    _ = try projection.run(.all);
}

fn runPass(library: *database.LibraryDatabase) !Result {
    var pass: ConsistencyPass = .{ .allocator = testing.allocator, .library = library, .batch_size = 2 };
    return pass.run();
}

fn openCount(library: *database.LibraryDatabase, category: Category) !i64 {
    var statement = try library.database.prepare(
        "SELECT count(*) FROM metadata_proposals WHERE id = group_id AND state = 0 AND category = ?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(category));
    _ = try statement.step();
    return statement.columnInt64(0);
}

fn optionValues(library: *database.LibraryDatabase, category: Category) ![]const u8 {
    var statement = try library.database.prepare(
        \\SELECT group_concat(m.proposed || '=' || m.reason, '|') FROM (
        \\  SELECT m.proposed, m.reason FROM metadata_proposals m
        \\  JOIN metadata_proposals h ON h.id = m.group_id
        \\  WHERE h.category = ?1 AND h.state = 0 AND m.option IS NOT NULL ORDER BY m.group_id, m.option) m;
    );
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(category));
    _ = try statement.step();
    return testing.allocator.dupe(u8, statement.columnText(0));
}

test "a release whose tracks state two spellings of one album artist yields one album artist issue" {
    var library = try openTestLibrary("file:orca-consistency-album-artist?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Blonde/01.flac", .{ .title = "Nikes", .album = "Blonde", .album_artist = "Frank Ocean", .track_number = 1 });
    _ = try observe(&library, "/m/Blonde/02.flac", .{ .title = "Ivy", .album = "Blonde", .album_artist = "Frank Ocean", .track_number = 2 });
    _ = try observe(&library, "/m/Blonde/03.flac", .{ .title = "Pink", .album = "Blonde", .album_artist = "frank ocean", .track_number = 3 });
    try project(&library);
    const result = try runPass(&library);
    try testing.expectEqual(@as(u64, 1), result.issues);
    try testing.expectEqual(@as(i64, 1), try openCount(&library, .album_artist));
    const options = try optionValues(&library, .album_artist);
    defer testing.allocator.free(options);
    try testing.expectEqualStrings("Frank Ocean=2 tracks|frank ocean=1 track · Pink", options);
}

test "mixed and invalid dates, repeated and missing numbers and genre spellings are each an issue" {
    var library = try openTestLibrary("file:orca-consistency-categories?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/A/01.flac", .{ .title = "One", .album = "A", .album_artist = "X", .track_number = 1, .date = "2016", .genres = &.{"Hip-Hop"} });
    _ = try observe(&library, "/m/A/02.flac", .{ .title = "Two", .album = "A", .album_artist = "X", .track_number = 1, .date = "2016-08-20", .genres = &.{"hip hop; Rock"} });
    _ = try observe(&library, "/m/A/03.flac", .{ .title = "Three", .album = "A", .album_artist = "X", .date = "2016", .genres = &.{"Hip-Hop"} });
    _ = try observe(&library, "/m/B/01.flac", .{ .title = "B1", .album = "B", .album_artist = "Y", .track_number = 1, .date = "20/08/2016" });
    _ = try observe(&library, "/m/B/02.flac", .{ .title = "B2", .album = "B", .album_artist = "Y", .track_number = 2, .date = "20/08/2016" });
    try project(&library);
    _ = try runPass(&library);
    try testing.expectEqual(@as(i64, 2), try openCount(&library, .dates));
    try testing.expectEqual(@as(i64, 1), try openCount(&library, .track_numbering));
    try testing.expectEqual(@as(i64, 1), try openCount(&library, .genre_variants));
    try testing.expectEqual(@as(i64, 0), try openCount(&library, .album_artist));
    const dates = try optionValues(&library, .dates);
    defer testing.allocator.free(dates);
    try testing.expectEqualStrings("2016-08-20=1 track · Two|2016=2 tracks|2016=Year of the dates stated", dates);
    const genres = try optionValues(&library, .genre_variants);
    defer testing.allocator.free(genres);
    try testing.expectEqualStrings("Hip-Hop=2 tracks|hip hop=1 track · Two", genres);
    var statement = try library.database.prepare(
        \\SELECT group_concat(current || '>' || proposed, ',') FROM metadata_proposals
        \\WHERE category = 2 AND track_id IS NOT NULL;
    );
    defer statement.deinit();
    _ = try statement.step();
    try testing.expectEqualStrings("1>2", statement.columnText(0)[0..3]);
}

test "a release whose values differ from its accepted MusicBrainz release says so and names MusicBrainz" {
    var library = try openTestLibrary("file:orca-consistency-musicbrainz?mode=memory&cache=shared");
    defer library.close();
    const first = try observe(&library, "/m/C/01.flac", .{ .title = "One", .album = "Blond", .album_artist = "Frank Ocean", .track_number = 1, .date = "2016" });
    _ = try observe(&library, "/m/C/02.flac", .{ .title = "Two", .album = "Blond", .album_artist = "frank ocean", .track_number = 2, .date = "2016" });
    try project(&library);
    const payload =
        \\{"title":"One","release_mbid":"3e5b4b48-1e4a-4b3a-9b3e-4d3c2b1a0f9e","release_track_mbid":"4e5b4b48-1e4a-4b3a-9b3e-4d3c2b1a0f9e",
        \\"release_title":"Blonde","release_artist":"Frank Ocean","release_date":"2016-08-20"}
    ;
    var insert = try library.database.prepare(
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state)
        \\VALUES (?1, 'musicbrainz', 'r', 1.0, ?2, 1);
    );
    defer insert.deinit();
    try insert.bindInt64(1, first);
    try insert.bindBlob(2, payload);
    _ = try insert.step();
    _ = try runPass(&library);
    const artists = try optionValues(&library, .album_artist);
    defer testing.allocator.free(artists);
    try testing.expectEqualStrings("Frank Ocean=1 track · MusicBrainz agrees|frank ocean=1 track · Two", artists);
    const differs = try optionValues(&library, .musicbrainz_differs);
    defer testing.allocator.free(differs);
    try testing.expectEqualStrings("Blonde=MusicBrainz|Blond=2 tracks|2016-08-20=MusicBrainz|2016=2 tracks", differs);
}

test "running the pass again replaces open issues and keeps a skipped one skipped until its values change" {
    var library = try openTestLibrary("file:orca-consistency-rerun?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/D/01.flac", .{ .title = "One", .album = "D", .album_artist = "Ab", .track_number = 1 });
    const second = try observe(&library, "/m/D/02.flac", .{ .title = "Two", .album = "D", .album_artist = "AB", .track_number = 2 });
    try project(&library);
    _ = try runPass(&library);
    _ = try runPass(&library);
    try testing.expectEqual(@as(i64, 1), try openCount(&library, .album_artist));
    try library.database.exec("UPDATE metadata_proposals SET state = 1;");
    const again = try runPass(&library);
    try testing.expectEqual(@as(u64, 0), again.issues);
    try testing.expectEqual(@as(i64, 0), try openCount(&library, .album_artist));

    try library.observed_tags.upsert(.{ .file_id = second, .values = .{ .title = "Two", .album = "D", .album_artist = "aB", .track_number = 2 } });
    try project(&library);
    const changed = try runPass(&library);
    try testing.expectEqual(@as(u64, 1), changed.issues);
    var statement = try library.database.prepare("SELECT count(*) FROM metadata_proposals WHERE state = 1;");
    defer statement.deinit();
    _ = try statement.step();
    try testing.expectEqual(@as(i64, 0), statement.columnInt64(0));
}

fn issueColumn(library: *database.LibraryDatabase, category: Category, sql: [:0]const u8) ![]const u8 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(category));
    _ = try statement.step();
    return testing.allocator.dupe(u8, statement.columnText(0));
}

test "dates that are less precise forms of one date propose the precise date first" {
    var library = try openTestLibrary("file:orca-consistency-precision?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/E/01.flac", .{ .title = "Nikes", .album = "E", .album_artist = "X", .track_number = 1, .date = "2016-08-20" });
    _ = try observe(&library, "/m/E/02.flac", .{ .title = "Ivy", .album = "E", .album_artist = "X", .track_number = 2, .date = "2016-08-20" });
    _ = try observe(&library, "/m/E/03.flac", .{ .title = "Solo (Reprise)", .album = "E", .album_artist = "X", .track_number = 3, .date = "2016" });
    _ = try observe(&library, "/m/E/04.flac", .{ .title = "Facebook Story", .album = "E", .album_artist = "X", .track_number = 4, .date = "2016-08" });
    try project(&library);
    _ = try runPass(&library);
    const dates = try optionValues(&library, .dates);
    defer testing.allocator.free(dates);
    try testing.expectEqualStrings("2016-08-20=2 tracks|2016=1 track · Solo (Reprise)|2016-08=1 track · Facebook Story", dates);
    const counts = try issueColumn(&library, .dates,
        \\SELECT group_concat(tracks, ',') FROM (SELECT tracks FROM metadata_proposals
        \\WHERE category = ?1 AND option IS NOT NULL ORDER BY option);
    );
    defer testing.allocator.free(counts);
    try testing.expectEqualStrings("2,1,1", counts);
}

test "a release where some tracks state a date and others none has a dates issue proposing it" {
    var library = try openTestLibrary("file:orca-consistency-undated?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/F/01.flac", .{ .title = "Bags", .album = "F", .album_artist = "X", .track_number = 1, .date = "2017-07-28" });
    _ = try observe(&library, "/m/F/02.flac", .{ .title = "Blk Girl Soldier", .album = "F", .album_artist = "X", .track_number = 2 });
    _ = try observe(&library, "/m/G/01.flac", .{ .title = "None", .album = "G", .album_artist = "Y", .track_number = 1 });
    try project(&library);
    _ = try runPass(&library);
    try testing.expectEqual(@as(i64, 1), try openCount(&library, .dates));
    const proposals = try issueColumn(&library, .dates,
        \\SELECT group_concat(COALESCE(current, '-') || '>' || proposed, ',') FROM metadata_proposals
        \\WHERE category = ?1 AND track_id IS NOT NULL;
    );
    defer testing.allocator.free(proposals);
    try testing.expectEqualStrings("->2017-07-28", proposals);
}

test "a repeated track number records the lowest number it fills below the disc's highest" {
    var library = try openTestLibrary("file:orca-consistency-gap?mode=memory&cache=shared");
    defer library.close();
    const numbers = [_]u32{ 1, 2, 3, 4, 5, 5, 7, 8 };
    for (numbers, 0..) |number, index| {
        var uri_buffer: [32]u8 = undefined;
        const uri = try std.fmt.bufPrint(&uri_buffer, "/m/H/{d:0>2}.flac", .{index + 1});
        var title_buffer: [16]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buffer, "Song {d}", .{index + 1});
        _ = try observe(&library, uri, .{ .title = title, .album = "H", .album_artist = "Noname", .track_number = number });
    }
    try project(&library);
    _ = try runPass(&library);
    const gap = try issueColumn(&library, .track_numbering,
        \\SELECT CAST(gap AS TEXT) FROM metadata_proposals WHERE category = ?1 AND id = group_id;
    );
    defer testing.allocator.free(gap);
    try testing.expectEqualStrings("6", gap);
}

test "valid dates are a year, a month or a day that exists" {
    try testing.expect(validDate("2016"));
    try testing.expect(validDate("2016-08"));
    try testing.expect(validDate("2016-08-20"));
    try testing.expect(!validDate("2016-13"));
    try testing.expect(!validDate("2016-02-30"));
    try testing.expect(!validDate("20/08/2016"));
    try testing.expectEqualStrings("2016", yearIn("20/08/2016").?);
}
