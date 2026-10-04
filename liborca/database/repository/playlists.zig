const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const text_key = @import("../text_key.zig");
const tracks = @import("tracks.zig");
const smart_playlist = @import("../../library/smart_playlist.zig");

const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const TrackSummary = tracks.TrackSummary;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const max_playlist_entries = 10_000;
pub const max_playlist_tags = 8;
pub const max_playlist_tag_bytes = 64;
pub const max_playlist_description_bytes = 4096;
pub const playlist_top_genres = 3;
pub const max_playlist_codecs = 32;
const info_tolerance_ms = 2 * std.time.ms_per_s;
const Evaluation = smart_playlist.Evaluation;

pub const PlaylistKind = enum(u8) {
    /// Entries the user placed, in the order they placed them.
    manual = 0,
    /// Tracks chosen by stored rules, evaluated each time they are read.
    smart = 1,
};

pub const PlaylistCreator = enum(u8) {
    user = 0,
    /// Created by importing an M3U file.
    imported = 1,
};

pub const PlaylistSort = enum {
    name,
    recently_updated,
    created,
    /// Manual playlists by entry count, most first, then smart playlists,
    /// whose count is evaluated rather than stored, by name.
    entries,

    fn terms(self: PlaylistSort) [:0]const u8 {
        return switch (self) {
            .name => "ORDER BY playlists.name COLLATE NOCASE, playlists.id\n",
            .recently_updated => "ORDER BY playlists.updated_at DESC, playlists.id DESC\n",
            .created => "ORDER BY playlists.created_at DESC, playlists.id DESC\n",
            .entries => "ORDER BY playlists.kind, entry_count DESC, playlists.name COLLATE NOCASE, playlists.id\n",
        };
    }
};

/// One bounded request for a page of playlists.
pub const PlaylistQuery = struct {
    /// Keeps the playlists whose name contains this, ignoring ASCII case.
    filter: []const u8 = "",
    kind: ?PlaylistKind = null,
    pinned_only: bool = false,
    created_by: ?PlaylistCreator = null,
    sort: PlaylistSort = .recently_updated,
    limit: u32 = max_page,
    offset: u32 = 0,
};

/// The metadata `PlaylistRepository.update` changes; null leaves a value as
/// it is.
pub const PlaylistUpdate = struct {
    description: ?[]const u8 = null,
    pinned: ?bool = null,
    loved: ?bool = null,
    /// Replaces every tag. Each is trimmed; at most eight, each at most 64
    /// bytes; repeats are kept once.
    tags: ?[]const []const u8 = null,
};

pub const PlaylistSummary = struct {
    id: i64,
    name: []u8,
    /// For a smart playlist, the Tracks its rules match now, up to its limit.
    entries: u32,
    available: u32,
    duration_ms: i64,
    created_at: i64,
    updated_at: i64,
    description: []u8,
    pinned: bool,
    loved: bool,
    kind: PlaylistKind,
    creator: PlaylistCreator,
    tags: [][]u8,
    /// The available entries name more than one Artist.
    mixed_artists: bool,
    /// How many distinct Artists the available entries name.
    artist_count: u64,
    /// The genres the most available entries carry, most first, at most
    /// three.
    top_genres: [][]u8,

    pub fn deinit(self: PlaylistSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        freeStrings(allocator, self.tags);
        freeStrings(allocator, self.top_genres);
    }
};

/// How many of a playlist's available entries play a file in one codec.
pub const CodecCount = struct {
    /// The codec id, as `TrackSummary.codec` names it.
    codec: []u8,
    count: u64,
};

/// The codecs a playlist's available entries play, most used first, and how
/// many of those entries have a loudness measurement for their file's
/// current bytes.
pub const PlaylistFormats = struct {
    codecs: []CodecCount,
    analyzed: u64,
    unanalyzed: u64,

    pub fn deinit(self: PlaylistFormats, allocator: std.mem.Allocator) void {
        for (self.codecs) |item| allocator.free(item.codec);
        allocator.free(self.codecs);
    }
};

/// What a smart playlist's rules select now: how many Tracks, their total
/// length, and the first of them in the rules' order.
pub const SmartPlaylistPreview = struct {
    count: u64,
    duration_ms: u64,
    sample: []TrackSummary,

    pub fn deinit(self: SmartPlaylistPreview, allocator: std.mem.Allocator) void {
        for (self.sample) |track| track.deinit(allocator);
        allocator.free(self.sample);
    }
};

fn freeStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

pub const PlaylistPage = struct {
    allocator: std.mem.Allocator,
    items: []PlaylistSummary,

    pub fn deinit(self: PlaylistPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const PlaylistEntry = struct {
    position: u32,
    recording_id: i64,
    track: ?TrackSummary,

    pub fn deinit(self: PlaylistEntry, allocator: std.mem.Allocator) void {
        if (self.track) |track| track.deinit(allocator);
    }
};

pub const PlaylistEntryPage = struct {
    allocator: std.mem.Allocator,
    items: []PlaylistEntry,

    pub fn deinit(self: PlaylistEntryPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const PlaylistInsertion = struct {
    added: u32 = 0,
    skipped: u32 = 0,
};

pub const PlaylistExportRow = struct {
    title: []u8,
    artist: []u8,
    duration_ms: ?i64,
    uri: []u8,

    pub fn deinit(self: PlaylistExportRow, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.uri);
    }
};

pub const PlaylistExportRows = struct {
    allocator: std.mem.Allocator,
    items: []PlaylistExportRow,
    unavailable: u32,

    pub fn deinit(self: PlaylistExportRows) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

const entry_track =
    "(SELECT min(candidate.id) FROM tracks AS candidate " ++
    "WHERE candidate.recording_id = playlist_entries.recording_id)";

const summary_sql =
    "SELECT playlists.id, playlists.name, playlists.created_at, playlists.updated_at,\n" ++
    "       (SELECT count(*) FROM playlist_entries WHERE playlist_entries.playlist_id = playlists.id) AS entry_count,\n" ++
    "       (SELECT count(*) FROM playlist_entries WHERE playlist_entries.playlist_id = playlists.id\n" ++
    "          AND EXISTS (SELECT 1 FROM tracks WHERE tracks.recording_id = playlist_entries.recording_id)),\n" ++
    "       (SELECT COALESCE(sum(tracks.duration_ms), 0) FROM playlist_entries\n" ++
    "          JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
    "          WHERE playlist_entries.playlist_id = playlists.id),\n" ++
    "       playlists.description, playlists.pinned_at IS NOT NULL, playlists.loved_at IS NOT NULL,\n" ++
    "       playlists.kind, playlists.creator, playlists.rules,\n" ++
    "       (SELECT count(DISTINCT tracks.artist_id) FROM playlist_entries\n" ++
    "          JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
    "          WHERE playlist_entries.playlist_id = playlists.id)\n" ++
    "FROM playlists\n";

const page_filter =
    "WHERE (?3 = '' OR instr(lower(playlists.name), lower(?3)) > 0)\n" ++
    "  AND (?4 IS NULL OR playlists.kind = ?4)\n" ++
    "  AND (?5 = 0 OR playlists.pinned_at IS NOT NULL)\n" ++
    "  AND (?6 IS NULL OR playlists.creator = ?6)\n";

const manual_top_genres =
    "SELECT genres.name FROM playlist_entries\n" ++
    "JOIN track_genres ON track_genres.track_id = " ++ entry_track ++ "\n" ++
    "JOIN genres ON genres.id = track_genres.genre_id\n" ++
    "WHERE playlist_entries.playlist_id = ?1\n" ++
    "GROUP BY genres.id ORDER BY count(*) DESC, genres.name COLLATE NOCASE, genres.id LIMIT ?2;";

/// The Tracks a smart playlist can list: one per recording, the one a manual
/// playlist's entry would play, so a recording with several files appears
/// once.
const smart_from =
    "FROM tracks\n" ++ tracks.recording_joins ++
    "WHERE tracks.recording_id IS NOT NULL\n" ++
    "  AND tracks.id = (SELECT min(candidate.id) FROM tracks AS candidate WHERE candidate.recording_id = tracks.recording_id)\n" ++
    "  AND ";

/// `columns` from every Track `compiled` matches, in its order, followed by
/// `tail`. The predicate's values bind from parameter 1.
fn smartSql(
    allocator: std.mem.Allocator,
    comptime select: []const u8,
    compiled: *const smart_playlist.Compiled,
    comptime tail: []const u8,
) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}{s}\nORDER BY {s}\n{s}",
        .{ select ++ "\n" ++ smart_from, compiled.predicate, compiled.order, tail },
        0,
    );
}

const formats_from_entries =
    "FROM playlist_entries\n" ++
    "JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
    tracks.recording_joins ++
    "WHERE playlist_entries.playlist_id = ?1\n" ++
    "LIMIT ?2";

const format_columns = "SELECT play_file.codec AS codec, " ++ tracks.play_file_loudness ++ " IS NOT NULL AS analyzed";

const codec_counts_head = "SELECT codec, count(*) FROM (";
const codec_counts_tail = std.fmt.comptimePrint(") AS chosen WHERE NULLIF(codec, '') IS NOT NULL\n" ++
    "GROUP BY codec ORDER BY count(*) DESC, codec LIMIT {d};", .{max_playlist_codecs});
const analyzed_head = "SELECT count(*), COALESCE(sum(analyzed), 0) FROM (";
const analyzed_tail = ") AS chosen;";

pub const PlaylistRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn create(self: *PlaylistRepository, name: []const u8) !i64 {
        return self.createKind(name, null);
    }

    /// Creates a smart playlist; `rules_json` must parse as
    /// `smart_playlist.parse` requires and is stored as given.
    pub fn createSmart(self: *PlaylistRepository, allocator: std.mem.Allocator, name: []const u8, rules_json: []const u8) !i64 {
        try self.validateRules(allocator, rules_json);
        return self.createKind(name, rules_json);
    }

    fn createKind(self: *PlaylistRepository, name: []const u8, rules_json: ?[]const u8) !i64 {
        const trimmed = try playlistName(name);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        if (try self.nameTaken(trimmed, null)) return error.PlaylistNameTaken;
        var statement = try self.db.prepare(
            \\INSERT INTO playlists(name, created_at, updated_at, kind, rules)
            \\VALUES (?1, unixepoch(), unixepoch(), ?2 IS NOT NULL, ?2)
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, trimmed);
        try statement.bindOptionalText(2, rules_json);
        if (try statement.step() != .row) return error.SqlFailed;
        const id = statement.columnInt64(0);
        if (try statement.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
        return id;
    }

    /// Replaces a smart playlist's rules. `error.PlaylistIsManual` for a
    /// manual playlist.
    pub fn setRules(self: *PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64, rules_json: []const u8) !void {
        try self.validateRules(allocator, rules_json);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        if (try self.playlistKind(playlist_id) != .smart) return error.PlaylistIsManual;
        var update_rules = try self.db.prepare("UPDATE playlists SET rules=?2, updated_at=unixepoch() WHERE id=?1;");
        defer update_rules.deinit();
        try update_rules.bindInt64(1, playlist_id);
        try update_rules.bindText(2, rules_json);
        if (try update_rules.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
    }

    /// A smart playlist's rules as stored; null for a manual playlist.
    pub fn rules(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64) !?[]u8 {
        var statement = try self.db.prepare("SELECT kind, rules FROM playlists WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .row) return error.UnknownPlaylist;
        if (statement.columnInt64(0) != @intFromEnum(PlaylistKind.smart)) return null;
        return try allocator.dupe(u8, statement.columnText(1));
    }

    /// How many Tracks `rules_json` matches now, up to its limit.
    pub fn smartCount(self: *const PlaylistRepository, allocator: std.mem.Allocator, rules_json: []const u8, evaluation: Evaluation) !u64 {
        var compiled = try self.compileChecked(allocator, rules_json, evaluation);
        defer compiled.deinit();
        return self.countCompiled(allocator, &compiled);
    }

    /// How many Tracks `rules_json` matches now, up to its limit, their total
    /// length, and the first `sample_limit` of them in the rules' order, all
    /// from one evaluation.
    pub fn smartPreview(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        rules_json: []const u8,
        sample_limit: u32,
        evaluation: Evaluation,
    ) !SmartPlaylistPreview {
        if (sample_limit > max_page) return error.PageOutOfRange;
        var compiled = try self.compileChecked(allocator, rules_json, evaluation);
        defer compiled.deinit();
        const totals = try self.smartTotals(allocator, &compiled);
        var entries_page = try self.smartEntries(allocator, &compiled, sample_limit, 0);
        defer entries_page.deinit();
        const sample = try allocator.alloc(TrackSummary, entries_page.items.len);
        for (sample, entries_page.items) |*track, *entry| {
            track.* = entry.track.?;
            entry.track = null;
        }
        return .{ .count = totals.count, .duration_ms = totals.duration_ms, .sample = sample };
    }

    const SmartTotals = struct { count: u64, duration_ms: u64, artist_count: u64 };

    fn smartTotals(self: *const PlaylistRepository, allocator: std.mem.Allocator, compiled: *const smart_playlist.Compiled) !SmartTotals {
        const sql = try smartSql(
            allocator,
            "SELECT count(*), COALESCE(sum(duration_ms), 0), count(DISTINCT artist_id) FROM (" ++
                "SELECT tracks.duration_ms AS duration_ms, tracks.artist_id AS artist_id",
            compiled,
            "LIMIT ?);",
        );
        defer allocator.free(sql);
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        const next = try compiled.bind(statement, 1);
        try statement.bindInt64(next, compiled.limit);
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .count = @intCast(statement.columnInt64(0)),
            .duration_ms = std.math.cast(u64, statement.columnInt64(1)) orelse 0,
            .artist_count = @intCast(statement.columnInt64(2)),
        };
    }

    /// Compiles rules a caller gives, refusing an `in_playlist` rule that
    /// names no manual playlist.
    fn compileChecked(self: *const PlaylistRepository, allocator: std.mem.Allocator, rules_json: []const u8, evaluation: Evaluation) !smart_playlist.Compiled {
        var parsed = try smart_playlist.parse(allocator, rules_json);
        defer parsed.deinit();
        try self.checkReferences(&parsed);
        var compiled = try smart_playlist.compile(allocator, &parsed, evaluation);
        errdefer compiled.deinit();
        try self.cutAtDuration(allocator, &compiled);
        return compiled;
    }

    fn validateRules(self: *const PlaylistRepository, allocator: std.mem.Allocator, rules_json: []const u8) !void {
        var parsed = try smart_playlist.parse(allocator, rules_json);
        defer parsed.deinit();
        try self.checkReferences(&parsed);
    }

    fn checkReferences(self: *const PlaylistRepository, parsed: *const smart_playlist.Rules) !void {
        var buffer: [smart_playlist.max_referenced_playlists]i64 = undefined;
        for (smart_playlist.referencedPlaylists(parsed, &buffer)) |playlist_id| {
            const kind = self.playlistKind(playlist_id) catch |err| switch (err) {
                error.UnknownPlaylist => return error.InvalidRulePlaylist,
                else => return err,
            };
            if (kind != .manual) return error.InvalidRulePlaylist;
        }
    }

    /// Compiles rules as stored. An `in_playlist` rule whose playlist has
    /// since gone matches nothing.
    fn compileStored(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        playlist_id: i64,
        rules_json: []const u8,
        evaluation: Evaluation,
    ) !smart_playlist.Compiled {
        var parsed = smart_playlist.parse(allocator, rules_json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStoredPlaylist,
        };
        defer parsed.deinit();
        var compiled = try smart_playlist.compile(allocator, &parsed, evaluation.forPlaylist(playlist_id));
        errdefer compiled.deinit();
        try self.cutAtDuration(allocator, &compiled);
        return compiled;
    }

    /// Turns an hour limit into the number of leading Tracks, in the rules'
    /// order, whose lengths add up to at most it; a Track with no length
    /// counts as none.
    fn cutAtDuration(self: *const PlaylistRepository, allocator: std.mem.Allocator, compiled: *smart_playlist.Compiled) !void {
        const limit_ms = compiled.limit_ms orelse return;
        const sql = try smartSql(allocator, "SELECT COALESCE(tracks.duration_ms, 0)", compiled, "LIMIT ?;");
        defer allocator.free(sql);
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        const next = try compiled.bind(statement, 1);
        try statement.bindInt64(next, compiled.limit);
        var total_ms: i64 = 0;
        var kept: u32 = 0;
        while (try statement.step() == .row) {
            total_ms +|= @max(statement.columnInt64(0), 0);
            if (total_ms > limit_ms) break;
            kept += 1;
        }
        compiled.limit = kept;
        compiled.limit_ms = null;
    }

    /// The codecs a playlist's available entries play and how many of them
    /// are analyzed; a smart playlist's entries are its rules evaluated now.
    pub fn formats(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64, evaluation: Evaluation) !PlaylistFormats {
        var compiled_rules = try self.compiledRules(allocator, playlist_id, evaluation);
        defer if (compiled_rules) |*compiled| compiled.deinit();
        var codec_statement = if (compiled_rules) |*compiled|
            try self.smartFormatStatement(allocator, compiled, codec_counts_head, codec_counts_tail)
        else
            try self.manualFormatStatement(playlist_id, codec_counts_head, codec_counts_tail);
        defer codec_statement.deinit();
        var codecs: std.ArrayList(CodecCount) = .empty;
        errdefer {
            for (codecs.items) |item| allocator.free(item.codec);
            codecs.deinit(allocator);
        }
        while (try codec_statement.step() == .row) {
            const codec = try allocator.dupe(u8, codec_statement.columnText(0));
            errdefer allocator.free(codec);
            try codecs.append(allocator, .{ .codec = codec, .count = @intCast(codec_statement.columnInt64(1)) });
        }
        var analyzed_statement = if (compiled_rules) |*compiled|
            try self.smartFormatStatement(allocator, compiled, analyzed_head, analyzed_tail)
        else
            try self.manualFormatStatement(playlist_id, analyzed_head, analyzed_tail);
        defer analyzed_statement.deinit();
        if (try analyzed_statement.step() != .row) return error.SqlFailed;
        const total: u64 = @intCast(analyzed_statement.columnInt64(0));
        const analyzed: u64 = @intCast(analyzed_statement.columnInt64(1));
        return .{ .codecs = try codecs.toOwnedSlice(allocator), .analyzed = analyzed, .unanalyzed = total - analyzed };
    }

    fn smartFormatStatement(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        compiled: *const smart_playlist.Compiled,
        comptime head: []const u8,
        comptime tail: []const u8,
    ) !sqlite.Statement {
        const sql = try smartSql(allocator, head ++ format_columns, compiled, "LIMIT ?" ++ tail);
        defer allocator.free(sql);
        const statement = try self.db.prepare(sql);
        errdefer statement.deinit();
        const next = try compiled.bind(statement, 1);
        try statement.bindInt64(next, compiled.limit);
        return statement;
    }

    fn manualFormatStatement(self: *const PlaylistRepository, playlist_id: i64, comptime head: []const u8, comptime tail: []const u8) !sqlite.Statement {
        const statement = try self.db.prepare(head ++ format_columns ++ "\n" ++ formats_from_entries ++ tail);
        errdefer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, max_playlist_entries);
        return statement;
    }

    fn countCompiled(self: *const PlaylistRepository, allocator: std.mem.Allocator, compiled: *const smart_playlist.Compiled) !u64 {
        const sql = try std.fmt.allocPrintSentinel(
            allocator,
            "SELECT count(*) FROM (SELECT tracks.id\n" ++ smart_from ++ "{s}\nLIMIT ?);",
            .{compiled.predicate},
            0,
        );
        defer allocator.free(sql);
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        const next = try compiled.bind(statement, 1);
        try statement.bindInt64(next, compiled.limit);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Changes a playlist's description, pin, love or tags. A description or
    /// tag change moves `updated_at`; pinning and loving do not.
    pub fn update(self: *PlaylistRepository, playlist_id: i64, change: PlaylistUpdate) !void {
        const description = if (change.description) |text| try playlistDescription(text) else null;
        var tag_buffer: [max_playlist_tags][]const u8 = undefined;
        const new_tags = if (change.tags) |values| try playlistTags(&tag_buffer, values) else null;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        _ = try self.playlistKind(playlist_id);
        var statement = try self.db.prepare(
            \\UPDATE playlists SET
            \\    description = COALESCE(?2, description),
            \\    pinned_at = CASE ?3 WHEN 1 THEN COALESCE(pinned_at, unixepoch()) WHEN 0 THEN NULL ELSE pinned_at END,
            \\    loved_at = CASE ?4 WHEN 1 THEN COALESCE(loved_at, unixepoch()) WHEN 0 THEN NULL ELSE loved_at END,
            \\    updated_at = CASE WHEN ?5 THEN unixepoch() ELSE updated_at END
            \\WHERE id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindOptionalText(2, description);
        try statement.bindOptionalInt64(3, if (change.pinned) |pinned| @intFromBool(pinned) else null);
        try statement.bindOptionalInt64(4, if (change.loved) |loved| @intFromBool(loved) else null);
        try statement.bindInt64(5, @intFromBool(description != null or new_tags != null));
        if (try statement.step() != .done) return error.SqlFailed;
        if (new_tags) |values| {
            var clear = try self.db.prepare("DELETE FROM playlist_tags WHERE playlist_id=?1;");
            defer clear.deinit();
            try clear.bindInt64(1, playlist_id);
            if (try clear.step() != .done) return error.SqlFailed;
            var add = try self.db.prepare("INSERT INTO playlist_tags(playlist_id, ordinal, tag) VALUES (?1, ?2, ?3);");
            defer add.deinit();
            for (values, 0..) |tag, ordinal| {
                try add.bindInt64(1, playlist_id);
                try add.bindInt64(2, @intCast(ordinal));
                try add.bindText(3, tag);
                if (try add.step() != .done) return error.SqlFailed;
                try add.reset();
            }
        }
        try self.db.exec("COMMIT;");
    }

    pub fn rename(self: *PlaylistRepository, playlist_id: i64, name: []const u8) !void {
        const trimmed = try playlistName(name);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requirePlaylist(playlist_id);
        if (try self.nameTaken(trimmed, playlist_id)) return error.PlaylistNameTaken;
        var rename_statement = try self.db.prepare("UPDATE playlists SET name=?2, updated_at=unixepoch() WHERE id=?1;");
        defer rename_statement.deinit();
        try rename_statement.bindInt64(1, playlist_id);
        try rename_statement.bindText(2, trimmed);
        if (try rename_statement.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
    }

    pub fn delete(self: *PlaylistRepository, playlist_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM playlists WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 0) return error.UnknownPlaylist;
    }

    pub fn list(self: *const PlaylistRepository, allocator: std.mem.Allocator, limit: u32, offset: u32, evaluation: Evaluation) !PlaylistPage {
        return self.page(allocator, .{ .sort = .name, .limit = limit, .offset = offset }, evaluation);
    }

    /// A page of playlists, smart playlists evaluated as `evaluation` says.
    pub fn page(self: *const PlaylistRepository, allocator: std.mem.Allocator, query: PlaylistQuery, evaluation: Evaluation) !PlaylistPage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        var statement = switch (query.sort) {
            inline else => |sort| try self.db.prepare(summary_sql ++ page_filter ++ comptime sort.terms() ++ "LIMIT ?1 OFFSET ?2;"),
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        try self.bindPageFilter(statement, query);
        var results: std.ArrayList(PlaylistSummary) = .empty;
        errdefer {
            for (results.items) |item| item.deinit(allocator);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const item = try self.readSummary(allocator, statement, evaluation);
            errdefer item.deinit(allocator);
            try results.append(allocator, item);
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    /// How many playlists `query` selects, ignoring its sort and page.
    pub fn pageCount(self: *const PlaylistRepository, query: PlaylistQuery) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM playlists\n" ++ page_filter ++ ";");
        defer statement.deinit();
        try self.bindPageFilter(statement, query);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// One playlist's summary.
    pub fn summary(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64, evaluation: Evaluation) !PlaylistSummary {
        var statement = try self.db.prepare(summary_sql ++ "WHERE playlists.id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .row) return error.UnknownPlaylist;
        return self.readSummary(allocator, statement, evaluation);
    }

    fn bindPageFilter(self: *const PlaylistRepository, statement: sqlite.Statement, query: PlaylistQuery) !void {
        _ = self;
        try statement.bindText(3, query.filter);
        try statement.bindOptionalInt64(4, if (query.kind) |kind| @intFromEnum(kind) else null);
        try statement.bindInt64(5, @intFromBool(query.pinned_only));
        try statement.bindOptionalInt64(6, if (query.created_by) |creator| @intFromEnum(creator) else null);
    }

    fn readSummary(self: *const PlaylistRepository, allocator: std.mem.Allocator, statement: sqlite.Statement, evaluation: Evaluation) !PlaylistSummary {
        const id = statement.columnInt64(0);
        const kind = std.enums.fromInt(PlaylistKind, statement.columnInt64(10)) orelse return error.InvalidStoredPlaylist;
        const creator = std.enums.fromInt(PlaylistCreator, statement.columnInt64(11)) orelse return error.InvalidStoredPlaylist;
        const name = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, statement.columnText(7));
        errdefer allocator.free(description);
        const tag_list = try self.readTags(allocator, id);
        errdefer freeStrings(allocator, tag_list);
        var result: PlaylistSummary = .{
            .id = id,
            .name = name,
            .created_at = statement.columnInt64(2),
            .updated_at = statement.columnInt64(3),
            .entries = std.math.cast(u32, statement.columnInt64(4)) orelse return error.InvalidStoredPlaylist,
            .available = std.math.cast(u32, statement.columnInt64(5)) orelse return error.InvalidStoredPlaylist,
            .duration_ms = statement.columnInt64(6),
            .description = description,
            .pinned = statement.columnInt64(8) != 0,
            .loved = statement.columnInt64(9) != 0,
            .kind = kind,
            .creator = creator,
            .tags = tag_list,
            .mixed_artists = statement.columnInt64(13) > 1,
            .artist_count = @intCast(statement.columnInt64(13)),
            .top_genres = &.{},
        };
        switch (kind) {
            .manual => {
                var genres = try self.db.prepare(manual_top_genres);
                defer genres.deinit();
                try genres.bindInt64(1, id);
                try genres.bindInt64(2, playlist_top_genres);
                result.top_genres = try readStrings(allocator, genres, 0);
            },
            .smart => {
                var compiled = try self.compileStored(allocator, id, statement.columnText(12), evaluation);
                defer compiled.deinit();
                try self.smartStats(allocator, &compiled, &result);
            },
        }
        return result;
    }

    fn smartStats(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        compiled: *const smart_playlist.Compiled,
        result: *PlaylistSummary,
    ) !void {
        {
            const totals = try self.smartTotals(allocator, compiled);
            const matched = std.math.cast(u32, totals.count) orelse return error.InvalidStoredPlaylist;
            result.entries = matched;
            result.available = matched;
            result.duration_ms = std.math.cast(i64, totals.duration_ms) orelse return error.InvalidStoredPlaylist;
            result.mixed_artists = totals.artist_count > 1;
            result.artist_count = totals.artist_count;
        }
        const sql = try smartSql(allocator, "SELECT genres.name FROM (SELECT tracks.id AS track_id", compiled, "LIMIT ?) AS matched\n" ++
            "JOIN track_genres ON track_genres.track_id = matched.track_id\n" ++
            "JOIN genres ON genres.id = track_genres.genre_id\n" ++
            "GROUP BY genres.id ORDER BY count(*) DESC, genres.name COLLATE NOCASE, genres.id LIMIT ?;");
        defer allocator.free(sql);
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        const next = try compiled.bind(statement, 1);
        try statement.bindInt64(next, compiled.limit);
        try statement.bindInt64(next + 1, playlist_top_genres);
        result.top_genres = try readStrings(allocator, statement, 0);
    }

    /// A playlist's tags in the order they were given.
    pub fn tags(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64) ![][]u8 {
        try self.requirePlaylist(playlist_id);
        return self.readTags(allocator, playlist_id);
    }

    fn readTags(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64) ![][]u8 {
        var statement = try self.db.prepare("SELECT tag FROM playlist_tags WHERE playlist_id=?1 ORDER BY ordinal;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        return readStrings(allocator, statement, 0);
    }

    pub fn entries(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        playlist_id: i64,
        limit: u32,
        offset: u32,
        evaluation: Evaluation,
    ) !PlaylistEntryPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        if (try self.compiledRules(allocator, playlist_id, evaluation)) |compiled_rules| {
            var compiled = compiled_rules;
            defer compiled.deinit();
            return self.smartEntries(allocator, &compiled, limit, offset);
        }
        var statement = try self.db.prepare(tracks.track_columns ++
            ", playlist_entries.position, playlist_entries.recording_id\n" ++
            "FROM playlist_entries\n" ++
            "LEFT JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
            tracks.recording_joins ++
            "WHERE playlist_entries.playlist_id = ?1\n" ++
            "ORDER BY playlist_entries.position\n" ++
            "LIMIT ?2 OFFSET ?3;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);
        var results: std.ArrayList(PlaylistEntry) = .empty;
        errdefer {
            for (results.items) |item| item.deinit(allocator);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const track: ?TrackSummary = if (statement.columnIsNull(0))
                null
            else
                try tracks.readTrackSummary(allocator, statement);
            errdefer if (track) |value| value.deinit(allocator);
            try results.append(allocator, .{
                .position = std.math.cast(u32, statement.columnInt64(tracks.track_column_count)) orelse return error.InvalidStoredPlaylist,
                .recording_id = statement.columnInt64(tracks.track_column_count + 1),
                .track = track,
            });
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    fn smartEntries(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        compiled: *const smart_playlist.Compiled,
        limit: u32,
        offset: u32,
    ) !PlaylistEntryPage {
        if (offset >= compiled.limit) return .{ .allocator = allocator, .items = &.{} };
        const sql = try smartSql(allocator, tracks.track_columns ++ ", tracks.recording_id", compiled, "LIMIT ? OFFSET ?;");
        defer allocator.free(sql);
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        const next = try compiled.bind(statement, 1);
        try statement.bindInt64(next, @min(limit, compiled.limit - offset));
        try statement.bindInt64(next + 1, offset);
        var results: std.ArrayList(PlaylistEntry) = .empty;
        errdefer {
            for (results.items) |item| item.deinit(allocator);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const track = try tracks.readTrackSummary(allocator, statement);
            errdefer track.deinit(allocator);
            try results.append(allocator, .{
                .position = offset + @as(u32, @intCast(results.items.len)),
                .recording_id = statement.columnInt64(tracks.track_column_count),
                .track = track,
            });
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    pub fn trackIds(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64, evaluation: Evaluation) ![]i64 {
        var compiled_rules = try self.compiledRules(allocator, playlist_id, evaluation);
        defer if (compiled_rules) |*compiled| compiled.deinit();
        var statement = if (compiled_rules) |*compiled| smart: {
            const sql = try smartSql(allocator, "SELECT tracks.id", compiled, "LIMIT ?;");
            defer allocator.free(sql);
            const statement = try self.db.prepare(sql);
            errdefer statement.deinit();
            const next = try compiled.bind(statement, 1);
            try statement.bindInt64(next, compiled.limit);
            break :smart statement;
        } else manual: {
            const statement = try self.db.prepare(
                "SELECT " ++ entry_track ++ " FROM playlist_entries\n" ++
                    "WHERE playlist_entries.playlist_id = ?1\n" ++
                    "ORDER BY playlist_entries.position\n" ++
                    "LIMIT ?2;",
            );
            errdefer statement.deinit();
            try statement.bindInt64(1, playlist_id);
            try statement.bindInt64(2, max_playlist_entries);
            break :manual statement;
        };
        defer statement.deinit();
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) {
            if (optionalInt64(statement, 0)) |track_id| try ids.append(allocator, track_id);
        }
        return ids.toOwnedSlice(allocator);
    }

    /// A smart playlist's compiled rules; null for a manual playlist.
    fn compiledRules(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64, evaluation: Evaluation) !?smart_playlist.Compiled {
        const stored = try self.rules(allocator, playlist_id) orelse return null;
        defer allocator.free(stored);
        return try self.compileStored(allocator, playlist_id, stored, evaluation);
    }

    pub fn insert(self: *PlaylistRepository, playlist_id: i64, track_ids: []const i64, at: ?u32) !PlaylistInsertion {
        if (track_ids.len > max_page) return error.PageOutOfRange;
        var recordings: [max_page]i64 = undefined;
        var insertion: PlaylistInsertion = .{};
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requireManual(playlist_id);
        const count = try self.entryCount(playlist_id);
        const position = at orelse count;
        if (position > count) return error.PositionOutOfRange;
        {
            var find = try self.db.prepare("SELECT recording_id FROM tracks WHERE id=?1;");
            defer find.deinit();
            for (track_ids) |track_id| {
                try find.bindInt64(1, track_id);
                const recording_id = if (try find.step() == .row) optionalInt64(find, 0) else null;
                try find.reset();
                if (recording_id) |recording| {
                    recordings[insertion.added] = recording;
                    insertion.added += 1;
                } else insertion.skipped += 1;
            }
        }
        if (count + insertion.added > max_playlist_entries) return error.PlaylistFull;
        if (insertion.added != 0) {
            try self.shiftRange(playlist_id, position, count, insertion.added);
            var add = try self.db.prepare(
                "INSERT INTO playlist_entries(playlist_id, position, recording_id, added_at) VALUES (?1, ?2, ?3, unixepoch());",
            );
            defer add.deinit();
            for (recordings[0..insertion.added], position..) |recording, entry_position| {
                try add.bindInt64(1, playlist_id);
                try add.bindInt64(2, @intCast(entry_position));
                try add.bindInt64(3, recording);
                if (try add.step() != .done) return error.SqlFailed;
                try add.reset();
            }
            try self.touch(playlist_id);
        }
        try self.db.exec("COMMIT;");
        return insertion;
    }

    pub fn remove(self: *PlaylistRepository, playlist_id: i64, positions: []const u32) !u32 {
        if (positions.len > max_page) return error.PageOutOfRange;
        var buffer: [max_page]u32 = undefined;
        const sorted = buffer[0..positions.len];
        @memcpy(sorted, positions);
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        var unique: usize = 0;
        for (sorted) |position| {
            if (unique != 0 and sorted[unique - 1] == position) continue;
            sorted[unique] = position;
            unique += 1;
        }
        const removed = sorted[0..unique];
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requireManual(playlist_id);
        const count = try self.entryCount(playlist_id);
        if (removed.len != 0 and removed[removed.len - 1] >= count) return error.PositionOutOfRange;
        {
            var drop = try self.db.prepare("DELETE FROM playlist_entries WHERE playlist_id=?1 AND position=?2;");
            defer drop.deinit();
            for (removed) |position| {
                try drop.bindInt64(1, playlist_id);
                try drop.bindInt64(2, position);
                if (try drop.step() != .done) return error.SqlFailed;
                try drop.reset();
            }
        }
        for (removed, 0..) |position, index| {
            const end = if (index + 1 < removed.len) removed[index + 1] else count;
            try self.shiftRange(playlist_id, position + 1, end, -@as(i64, @intCast(index + 1)));
        }
        if (removed.len != 0) try self.touch(playlist_id);
        try self.db.exec("COMMIT;");
        return @intCast(removed.len);
    }

    pub fn move(self: *PlaylistRepository, playlist_id: i64, from: u32, to: u32) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requireManual(playlist_id);
        const count = try self.entryCount(playlist_id);
        if (from >= count or to >= count) return error.PositionOutOfRange;
        if (from != to) {
            const parked = -@as(i64, count) - 1;
            try self.setPosition(playlist_id, from, parked);
            if (from < to)
                try self.shiftRange(playlist_id, from + 1, to + 1, -1)
            else
                try self.shiftRange(playlist_id, to, from, 1);
            try self.setPosition(playlist_id, parked, to);
            try self.touch(playlist_id);
        }
        try self.db.exec("COMMIT;");
    }

    /// The recording of the file at `uri`, preferring a present location,
    /// then an unverified one, then a missing one.
    pub fn resolvePath(self: *const PlaylistRepository, uri: []const u8) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT files.recording_id FROM locations
            \\JOIN files ON files.id = locations.file_id
            \\WHERE locations.uri = ?1 AND files.recording_id IS NOT NULL
            \\ORDER BY CASE locations.state
            \\    WHEN 'present' THEN 0 WHEN 'unverified' THEN 1 ELSE 2 END, locations.id
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindText(1, uri);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// The one recording with a Track whose folded title and artist equal
    /// these and whose length is within two seconds of `seconds`; null when
    /// none or several match.
    pub fn resolveInfo(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        artist: []const u8,
        title: []const u8,
        seconds: u32,
    ) !?i64 {
        const artist_key = try text_key.normalizeKey(allocator, artist);
        defer allocator.free(artist_key);
        const title_key = try text_key.normalizeKey(allocator, title);
        defer allocator.free(title_key);
        var statement = try self.db.prepare(
            \\SELECT recording_id, title, artist FROM tracks
            \\WHERE recording_id IS NOT NULL AND duration_ms BETWEEN ?1 AND ?2;
        );
        defer statement.deinit();
        const center_ms = @as(i64, seconds) * std.time.ms_per_s;
        try statement.bindInt64(1, center_ms - info_tolerance_ms);
        try statement.bindInt64(2, center_ms + info_tolerance_ms);
        var found: ?i64 = null;
        while (try statement.step() == .row) {
            const recording_id = statement.columnInt64(0);
            if (found == recording_id) continue;
            if (!try foldsTo(allocator, statement.columnText(1), title_key)) continue;
            if (!try foldsTo(allocator, statement.columnText(2), artist_key)) continue;
            if (found != null) return null;
            found = recording_id;
        }
        return found;
    }

    /// Every Track's folded artist and title mapped to its recording, read in
    /// one pass, for matching credits that carry no length.
    pub fn recordingsByCredit(self: *const PlaylistRepository, allocator: std.mem.Allocator) !RecordingsByCredit {
        var index: RecordingsByCredit = .{ .allocator = allocator, .keys = .init(allocator) };
        errdefer index.deinit();
        var statement = try self.db.prepare("SELECT recording_id, title, artist FROM tracks WHERE recording_id IS NOT NULL;");
        defer statement.deinit();
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(allocator);
        while (try statement.step() == .row) {
            const recording_id = statement.columnInt64(0);
            try creditKey(allocator, &key, statement.columnText(2), statement.columnText(1));
            const slot = try index.recordings.getOrPut(allocator, key.items);
            if (!slot.found_existing) {
                slot.key_ptr.* = try index.keys.allocator().dupe(u8, key.items);
                slot.value_ptr.* = .{ .unique = recording_id };
            } else switch (slot.value_ptr.*) {
                .unique => |existing| if (existing != recording_id) {
                    slot.value_ptr.* = .ambiguous;
                },
                .ambiguous => {},
            }
        }
        return index;
    }

    /// Creates a playlist holding `recording_ids` in order, named `name` or,
    /// when that is taken, `name (2)`, `name (3)` and so on.
    pub fn createWithRecordings(
        self: *PlaylistRepository,
        allocator: std.mem.Allocator,
        name: []const u8,
        recording_ids: []const i64,
    ) !i64 {
        if (recording_ids.len > max_playlist_entries) return error.PlaylistFull;
        const trimmed = try playlistName(name);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var candidate = try allocator.dupe(u8, trimmed);
        defer allocator.free(candidate);
        var suffix: u32 = 1;
        while (try self.nameTaken(candidate, null)) {
            suffix += 1;
            const next = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ trimmed, suffix });
            allocator.free(candidate);
            candidate = next;
        }
        var create_statement = try self.db.prepare(
            \\INSERT INTO playlists(name, created_at, updated_at, creator) VALUES (?1, unixepoch(), unixepoch(), 1)
            \\RETURNING id;
        );
        defer create_statement.deinit();
        try create_statement.bindText(1, candidate);
        if (try create_statement.step() != .row) return error.SqlFailed;
        const playlist_id = create_statement.columnInt64(0);
        if (try create_statement.step() != .done) return error.SqlFailed;
        var add = try self.db.prepare(
            "INSERT INTO playlist_entries(playlist_id, position, recording_id, added_at) VALUES (?1, ?2, ?3, unixepoch());",
        );
        defer add.deinit();
        for (recording_ids, 0..) |recording_id, position| {
            try add.bindInt64(1, playlist_id);
            try add.bindInt64(2, @intCast(position));
            try add.bindInt64(3, recording_id);
            if (try add.step() != .done) return error.SqlFailed;
            try add.reset();
        }
        try self.db.exec("COMMIT;");
        return playlist_id;
    }

    /// Each entry's Track and the location `TrackRepository.playableLocation`
    /// picks, in order; entries with no Track or no location are counted as
    /// unavailable. A smart playlist exports the Tracks its rules match now.
    pub fn exportRows(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64, evaluation: Evaluation) !PlaylistExportRows {
        var compiled_rules = try self.compiledRules(allocator, playlist_id, evaluation);
        defer if (compiled_rules) |*compiled| compiled.deinit();
        var statement = if (compiled_rules) |*compiled| smart: {
            const sql = try smartSql(allocator, "SELECT tracks.id, tracks.title, tracks.artist, tracks.duration_ms", compiled, "LIMIT ?;");
            defer allocator.free(sql);
            const statement = try self.db.prepare(sql);
            errdefer statement.deinit();
            const next = try compiled.bind(statement, 1);
            try statement.bindInt64(next, compiled.limit);
            break :smart statement;
        } else manual: {
            const statement = try self.db.prepare(
                "SELECT tracks.id, tracks.title, tracks.artist, tracks.duration_ms FROM playlist_entries\n" ++
                    "LEFT JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
                    "WHERE playlist_entries.playlist_id = ?1\n" ++
                    "ORDER BY playlist_entries.position\n" ++
                    "LIMIT ?2;",
            );
            errdefer statement.deinit();
            try statement.bindInt64(1, playlist_id);
            try statement.bindInt64(2, max_playlist_entries);
            break :manual statement;
        };
        defer statement.deinit();
        const track_repository: tracks.TrackRepository = .{ .db = self.db, .write_lane = self.write_lane };
        var rows: std.ArrayList(PlaylistExportRow) = .empty;
        errdefer {
            for (rows.items) |row| row.deinit(allocator);
            rows.deinit(allocator);
        }
        var unavailable: u32 = 0;
        while (try statement.step() == .row) {
            const track_id = optionalInt64(statement, 0) orelse {
                unavailable += 1;
                continue;
            };
            const location = try track_repository.playableLocation(allocator, track_id) orelse {
                unavailable += 1;
                continue;
            };
            defer location.deinit();
            const uri = try allocator.dupe(u8, location.uri);
            errdefer allocator.free(uri);
            const title = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(title);
            const artist = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(artist);
            try rows.append(allocator, .{
                .title = title,
                .artist = artist,
                .duration_ms = optionalInt64(statement, 3),
                .uri = uri,
            });
        }
        return .{ .allocator = allocator, .items = try rows.toOwnedSlice(allocator), .unavailable = unavailable };
    }

    fn requirePlaylist(self: *const PlaylistRepository, playlist_id: i64) !void {
        _ = try self.playlistKind(playlist_id);
    }

    fn requireManual(self: *const PlaylistRepository, playlist_id: i64) !void {
        if (try self.playlistKind(playlist_id) == .smart) return error.PlaylistIsSmart;
    }

    fn playlistKind(self: *const PlaylistRepository, playlist_id: i64) !PlaylistKind {
        var statement = try self.db.prepare("SELECT kind FROM playlists WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .row) return error.UnknownPlaylist;
        return std.enums.fromInt(PlaylistKind, statement.columnInt64(0)) orelse error.InvalidStoredPlaylist;
    }

    fn nameTaken(self: *const PlaylistRepository, name: []const u8, except: ?i64) !bool {
        var statement = try self.db.prepare("SELECT 1 FROM playlists WHERE name=?1 AND id IS NOT ?2;");
        defer statement.deinit();
        try statement.bindText(1, name);
        try statement.bindOptionalInt64(2, except);
        return try statement.step() == .row;
    }

    fn entryCount(self: *const PlaylistRepository, playlist_id: i64) !u32 {
        var statement = try self.db.prepare("SELECT count(*) FROM playlist_entries WHERE playlist_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return std.math.cast(u32, statement.columnInt64(0)) orelse error.InvalidStoredPlaylist;
    }

    fn touch(self: *PlaylistRepository, playlist_id: i64) !void {
        var statement = try self.db.prepare("UPDATE playlists SET updated_at=unixepoch() WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    fn setPosition(self: *PlaylistRepository, playlist_id: i64, from: i64, to: i64) !void {
        var statement = try self.db.prepare("UPDATE playlist_entries SET position=?3 WHERE playlist_id=?1 AND position=?2;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, from);
        try statement.bindInt64(3, to);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    fn shiftRange(self: *PlaylistRepository, playlist_id: i64, start: u32, end: u32, delta: i64) !void {
        if (start >= end) return;
        // The primary key is checked row by row, so a shift in place collides
        // with a neighbour that has not moved yet; park the range on negative
        // positions first.
        var park = try self.db.prepare(
            \\UPDATE playlist_entries SET position = -(position + 1)
            \\WHERE playlist_id=?1 AND position >= ?2 AND position < ?3;
        );
        defer park.deinit();
        try park.bindInt64(1, playlist_id);
        try park.bindInt64(2, start);
        try park.bindInt64(3, end);
        if (try park.step() != .done) return error.SqlFailed;
        var land = try self.db.prepare(
            \\UPDATE playlist_entries SET position = -position - 1 + ?4
            \\WHERE playlist_id=?1 AND position <= -(?2 + 1) AND position >= -?3;
        );
        defer land.deinit();
        try land.bindInt64(1, playlist_id);
        try land.bindInt64(2, start);
        try land.bindInt64(3, end);
        try land.bindInt64(4, delta);
        if (try land.step() != .done) return error.SqlFailed;
    }
};

const CreditCandidate = union(enum) {
    unique: i64,
    ambiguous,
};

pub const RecordingsByCredit = struct {
    allocator: std.mem.Allocator,
    keys: std.heap.ArenaAllocator,
    recordings: std.StringHashMapUnmanaged(CreditCandidate) = .empty,

    pub fn deinit(self: *RecordingsByCredit) void {
        self.recordings.deinit(self.allocator);
        self.keys.deinit();
    }

    /// The one recording credited to this artist and title; null when none
    /// or several are.
    pub fn lookup(self: *const RecordingsByCredit, allocator: std.mem.Allocator, artist: []const u8, title: []const u8) !?i64 {
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(allocator);
        try creditKey(allocator, &key, artist, title);
        return switch (self.recordings.get(key.items) orelse return null) {
            .unique => |recording_id| recording_id,
            .ambiguous => null,
        };
    }
};

fn creditKey(allocator: std.mem.Allocator, key: *std.ArrayList(u8), artist: []const u8, title: []const u8) !void {
    const artist_key = try text_key.normalizeKey(allocator, artist);
    defer allocator.free(artist_key);
    const title_key = try text_key.normalizeKey(allocator, title);
    defer allocator.free(title_key);
    key.clearRetainingCapacity();
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, artist_key.len, .little);
    try key.appendSlice(allocator, &length);
    try key.appendSlice(allocator, artist_key);
    try key.appendSlice(allocator, title_key);
}

fn foldsTo(allocator: std.mem.Allocator, text: []const u8, key: []const u8) !bool {
    const folded = try text_key.normalizeKey(allocator, text);
    defer allocator.free(folded);
    return std.mem.eql(u8, folded, key);
}

fn playlistName(name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.InvalidPlaylistName;
    return trimmed;
}

fn playlistDescription(description: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, description, &std.ascii.whitespace);
    if (trimmed.len > max_playlist_description_bytes) return error.PlaylistDescriptionTooLong;
    return trimmed;
}

fn playlistTags(buffer: *[max_playlist_tags][]const u8, values: []const []const u8) ![]const []const u8 {
    var len: usize = 0;
    next: for (values) |value| {
        const tag = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (tag.len == 0 or tag.len > max_playlist_tag_bytes) return error.InvalidPlaylistTag;
        for (buffer[0..len]) |kept| if (std.mem.eql(u8, kept, tag)) continue :next;
        if (len == max_playlist_tags) return error.TooManyPlaylistTags;
        buffer[len] = tag;
        len += 1;
    }
    return buffer[0..len];
}

fn readStrings(allocator: std.mem.Allocator, statement: sqlite.Statement, column: c_int) ![][]u8 {
    var strings: std.ArrayList([]u8) = .empty;
    errdefer {
        for (strings.items) |string| allocator.free(string);
        strings.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const string = try allocator.dupe(u8, statement.columnText(column));
        errdefer allocator.free(string);
        try strings.append(allocator, string);
    }
    return strings.toOwnedSlice(allocator);
}
