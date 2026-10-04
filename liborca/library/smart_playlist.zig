//! Smart playlist rules: a JSON document, version 1, parsed against a
//! whitelist of fields and operators and compiled to one SQL predicate over
//! `tracks` and `tracks.recording_joins`.
//!
//! The SQL text is assembled only from the fragments in this file. Every
//! value a rule carries is bound as a parameter, so a rule can never change
//! the shape of the query it compiles to.
const std = @import("std");
const codec = @import("../codec/decoder.zig");
const genre_alias = @import("../metadata/genre_alias.zig");
const sqlite = @import("../database/sqlite.zig");
const tracks = @import("../database/repository/tracks.zig");
const releases = @import("../database/repository/releases.zig");

pub const version = 1;
pub const max_rules_bytes = 16 * 1024;
pub const max_depth = 4;
pub const max_rules = 32;
pub const max_limit = 10_000;
pub const max_text_bytes = 256;
pub const max_days = 100_000;
pub const max_limit_hours = 10_000;

pub const Match = enum { all, any };

pub const FieldType = enum { text, integer, date, boolean, playlist };

pub const Field = enum {
    title,
    artist,
    album,
    album_artist,
    genre,
    codec,
    release_type,
    year,
    play_count,
    rating,
    duration_ms,
    sample_rate,
    bit_depth,
    added_at,
    last_played_at,
    loved,
    lossless,
    explicit,
    has_artwork,
    in_playlist,

    pub fn fieldType(self: Field) FieldType {
        return switch (self) {
            .title, .artist, .album, .album_artist, .genre, .codec, .release_type => .text,
            .year, .play_count, .rating, .duration_ms, .sample_rate, .bit_depth => .integer,
            .added_at, .last_played_at => .date,
            .loved, .lossless, .explicit, .has_artwork => .boolean,
            .in_playlist => .playlist,
        };
    }
};

pub const Operator = enum {
    is,
    is_not,
    contains,
    starts_with,
    gt,
    gte,
    lt,
    lte,
    between,
    in_last_days,
    not_in_last_days,
    is_set,
    is_not_set,

    pub fn appliesTo(self: Operator, field_type: FieldType) bool {
        return switch (field_type) {
            .text => switch (self) {
                .is, .is_not, .contains, .starts_with, .is_set, .is_not_set => true,
                else => false,
            },
            .integer => switch (self) {
                .is, .is_not, .gt, .gte, .lt, .lte, .between, .is_set, .is_not_set => true,
                else => false,
            },
            .date => switch (self) {
                .gt, .gte, .lt, .lte, .between, .in_last_days, .not_in_last_days, .is_set, .is_not_set => true,
                else => false,
            },
            .boolean, .playlist => self == .is or self == .is_not,
        };
    }
};

pub const Value = union(enum) {
    none,
    text: []const u8,
    integer: i64,
    range: [2]i64,
    boolean: bool,
};

pub const Rule = struct {
    field: Field,
    operator: Operator,
    value: Value,
};

pub const Node = union(enum) {
    rule: Rule,
    group: Group,
};

pub const Group = struct {
    match: Match,
    nodes: []const Node,
};

pub const SortField = union(enum) {
    track: tracks.TrackSort,
    /// A shuffle drawn from `Evaluation.seed`, so one read keeps one order.
    random,
    /// The first position of the Track's Recording in this manual playlist;
    /// Tracks it does not hold sort last.
    playlist_position: i64,
};

/// The order a smart playlist lists its Tracks in. Field names are
/// `TrackSort`'s, plus `added_at`, `last_played_at` and `duration_ms`, the
/// rule field names of the same three orders, `random`, and
/// `playlist_position` with the manual playlist's id as `playlist`.
pub const Sort = struct {
    field: SortField = .{ .track = .id },
    direction: tracks.SortDirection = .ascending,
};

/// How many Tracks a smart playlist keeps, in its order: at most `tracks`
/// of them, or the leading ones whose lengths add up to at most `hours`.
pub const Limit = union(enum) {
    tracks: u32,
    hours: u32,
};

/// What one read of a smart playlist evaluates its rules against: `now`
/// (Unix seconds) anchors relative dates and `seed` draws a random order.
pub const Evaluation = struct {
    now: i64,
    seed: u64,

    /// The evaluation for one stored playlist: its own random order, fixed
    /// for as long as `seed` is.
    pub fn forPlaylist(self: Evaluation, playlist_id: i64) Evaluation {
        var state = self.seed ^ @as(u64, @bitCast(playlist_id));
        return .{ .now = self.now, .seed = splitMix(&state) };
    }
};

pub const Rules = struct {
    arena: std.heap.ArenaAllocator,
    root: Group,
    sort: Sort,
    limit: Limit,

    pub fn deinit(self: *Rules) void {
        self.arena.deinit();
    }
};

pub const Error = error{
    InvalidSmartPlaylistRules,
    UnknownRuleField,
    UnknownRuleOperator,
    RuleOperatorMismatch,
    InvalidRuleValue,
    RuleNestingTooDeep,
    TooManyRules,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, json: []const u8) Error!Rules {
    if (json.len > max_rules_bytes) return error.InvalidSmartPlaylistRules;
    var rules: Rules = .{
        .arena = .init(allocator),
        .root = undefined,
        .sort = .{},
        .limit = .{ .tracks = max_limit },
    };
    errdefer rules.arena.deinit();
    const arena = rules.arena.allocator();
    const document = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSmartPlaylistRules,
    };
    const object = switch (document) {
        .object => |value| value,
        else => return error.InvalidSmartPlaylistRules,
    };
    try onlyKeys(object, &.{ "v", "match", "rules", "sort", "limit", "limit_hours" });
    const declared = object.get("v") orelse return error.InvalidSmartPlaylistRules;
    if (declared != .integer or declared.integer != version) return error.InvalidSmartPlaylistRules;
    var leaves: u32 = 0;
    rules.root = try parseGroup(arena, object, 1, &leaves);
    if (object.get("sort")) |sort| rules.sort = try parseSort(sort);
    const limit = object.get("limit");
    const limit_hours = object.get("limit_hours");
    if (limit != null and limit_hours != null) return error.InvalidSmartPlaylistRules;
    if (limit) |value| {
        if (value != .integer or value.integer < 1 or value.integer > max_limit) return error.InvalidSmartPlaylistRules;
        rules.limit = .{ .tracks = @intCast(value.integer) };
    }
    if (limit_hours) |value| {
        if (value != .integer or value.integer < 1 or value.integer > max_limit_hours) return error.InvalidSmartPlaylistRules;
        rules.limit = .{ .hours = @intCast(value.integer) };
    }
    return rules;
}

/// Parses `json` only to reject what `parse` would.
pub fn validate(allocator: std.mem.Allocator, json: []const u8) Error!void {
    var rules = try parse(allocator, json);
    rules.deinit();
}

fn onlyKeys(object: std.json.ObjectMap, allowed: []const []const u8) Error!void {
    var keys = object.iterator();
    next: while (keys.next()) |entry| {
        for (allowed) |name| if (std.mem.eql(u8, entry.key_ptr.*, name)) continue :next;
        return error.InvalidSmartPlaylistRules;
    }
}

fn parseGroup(arena: std.mem.Allocator, object: std.json.ObjectMap, depth: u32, leaves: *u32) Error!Group {
    if (depth > max_depth) return error.RuleNestingTooDeep;
    const match: Match = if (object.get("match")) |value| switch (value) {
        .string => |name| std.meta.stringToEnum(Match, name) orelse return error.InvalidSmartPlaylistRules,
        else => return error.InvalidSmartPlaylistRules,
    } else .all;
    const items = switch (object.get("rules") orelse return error.InvalidSmartPlaylistRules) {
        .array => |array| array.items,
        else => return error.InvalidSmartPlaylistRules,
    };
    if (items.len > max_rules) return error.TooManyRules;
    const nodes = try arena.alloc(Node, items.len);
    for (items, nodes) |item, *node| {
        const child = switch (item) {
            .object => |value| value,
            else => return error.InvalidSmartPlaylistRules,
        };
        if (child.contains("rules")) {
            try onlyKeys(child, &.{ "match", "rules" });
            node.* = .{ .group = try parseGroup(arena, child, depth + 1, leaves) };
        } else {
            leaves.* += 1;
            if (leaves.* > max_rules) return error.TooManyRules;
            node.* = .{ .rule = try parseRule(child) };
        }
    }
    return .{ .match = match, .nodes = nodes };
}

fn parseRule(object: std.json.ObjectMap) Error!Rule {
    try onlyKeys(object, &.{ "field", "op", "value" });
    const field_name = switch (object.get("field") orelse return error.InvalidSmartPlaylistRules) {
        .string => |name| name,
        else => return error.InvalidSmartPlaylistRules,
    };
    const field = std.meta.stringToEnum(Field, field_name) orelse return error.UnknownRuleField;
    const operator_name = switch (object.get("op") orelse return error.InvalidSmartPlaylistRules) {
        .string => |name| name,
        else => return error.InvalidSmartPlaylistRules,
    };
    const operator = std.meta.stringToEnum(Operator, operator_name) orelse return error.UnknownRuleOperator;
    const field_type = field.fieldType();
    if (!operator.appliesTo(field_type)) return error.RuleOperatorMismatch;
    const raw: std.json.Value = object.get("value") orelse .null;
    const value: Value = switch (operator) {
        .is_set, .is_not_set => if (raw == .null) .none else return error.InvalidRuleValue,
        .between => try rangeValue(raw),
        .in_last_days, .not_in_last_days => days: {
            if (raw != .integer or raw.integer < 1 or raw.integer > max_days) return error.InvalidRuleValue;
            break :days .{ .integer = raw.integer };
        },
        else => switch (field_type) {
            .text => text: {
                if (raw != .string or raw.string.len == 0 or raw.string.len > max_text_bytes) return error.InvalidRuleValue;
                break :text .{ .text = raw.string };
            },
            .integer, .date => if (raw == .integer) .{ .integer = raw.integer } else return error.InvalidRuleValue,
            .playlist => .{ .integer = try parsePlaylistId(raw) },
            .boolean => if (raw == .bool) .{ .boolean = raw.bool } else return error.InvalidRuleValue,
        },
    };
    return .{ .field = field, .operator = operator, .value = value };
}

fn parsePlaylistId(raw: std.json.Value) Error!i64 {
    if (raw != .integer or raw.integer < 1) return error.InvalidRuleValue;
    return raw.integer;
}

fn rangeValue(raw: std.json.Value) Error!Value {
    const items = switch (raw) {
        .array => |array| array.items,
        else => return error.InvalidRuleValue,
    };
    if (items.len != 2 or items[0] != .integer or items[1] != .integer) return error.InvalidRuleValue;
    const low = @min(items[0].integer, items[1].integer);
    const high = @max(items[0].integer, items[1].integer);
    return .{ .range = .{ low, high } };
}

const sort_aliases: std.StaticStringMap(tracks.TrackSort) = .initComptime(.{
    .{ "added_at", .date_added },
    .{ "last_played_at", .last_played },
    .{ "duration_ms", .duration },
});

fn parseSort(raw: std.json.Value) Error!Sort {
    const object = switch (raw) {
        .object => |value| value,
        else => return error.InvalidSmartPlaylistRules,
    };
    try onlyKeys(object, &.{ "field", "descending", "playlist" });
    var sort: Sort = .{};
    if (object.get("field")) |field| {
        const name = switch (field) {
            .string => |value| value,
            else => return error.InvalidSmartPlaylistRules,
        };
        sort.field = if (std.mem.eql(u8, name, "random"))
            .random
        else if (std.mem.eql(u8, name, "playlist_position"))
            .{ .playlist_position = try parsePlaylistId(object.get("playlist") orelse return error.InvalidRuleValue) }
        else
            .{ .track = sort_aliases.get(name) orelse std.meta.stringToEnum(tracks.TrackSort, name) orelse
                return error.UnknownRuleField };
    }
    if (sort.field != .playlist_position and object.get("playlist") != null) return error.InvalidSmartPlaylistRules;
    if (object.get("descending")) |descending| switch (descending) {
        .bool => |value| sort.direction = if (value) .descending else .ascending,
        else => return error.InvalidSmartPlaylistRules,
    };
    return sort;
}

pub const max_referenced_playlists = max_rules + 1;

/// The playlist ids the rules' `in_playlist` rules and `playlist_position`
/// sort name, each once.
pub fn referencedPlaylists(rules: *const Rules, buffer: *[max_referenced_playlists]i64) []const i64 {
    var count: usize = 0;
    collectPlaylists(rules.root, buffer, &count);
    switch (rules.sort.field) {
        .playlist_position => |playlist_id| addPlaylist(buffer, &count, playlist_id),
        .track, .random => {},
    }
    return buffer[0..count];
}

fn collectPlaylists(group: Group, buffer: *[max_referenced_playlists]i64, count: *usize) void {
    for (group.nodes) |node| switch (node) {
        .group => |child| collectPlaylists(child, buffer, count),
        .rule => |leaf| if (leaf.field == .in_playlist) addPlaylist(buffer, count, leaf.value.integer),
    };
}

fn addPlaylist(buffer: *[max_referenced_playlists]i64, count: *usize, playlist_id: i64) void {
    if (std.mem.indexOfScalar(i64, buffer[0..count.*], playlist_id) != null) return;
    buffer[count.*] = playlist_id;
    count.* += 1;
}

pub const Bound = union(enum) {
    text: []const u8,
    integer: i64,
};

/// A predicate over `tracks` joined by `tracks.recording_joins`, the ORDER BY
/// and row limit the rules ask for, and the parameters of the predicate and
/// then of the ORDER BY, in the order their `?` placeholders appear. With `limit_ms` set, `limit` caps the
/// rows read and the reader cuts the list where the lengths pass `limit_ms`.
pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    predicate: []const u8,
    values: []const Bound,
    order: []const u8,
    limit: u32,
    limit_ms: ?i64,

    pub fn deinit(self: *Compiled) void {
        self.arena.deinit();
    }

    /// Binds the predicate's values from parameter `first` on and returns
    /// the number of the next parameter.
    pub fn bind(self: *const Compiled, statement: sqlite.Statement, first: c_int) !c_int {
        var index = first;
        for (self.values) |value| {
            switch (value) {
                .text => |text| try statement.bindText(index, text),
                .integer => |number| try statement.bindInt64(index, number),
            }
            index += 1;
        }
        return index;
    }
};

/// Compiles `rules` into a value that outlives them, evaluated as
/// `evaluation` says.
pub fn compile(allocator: std.mem.Allocator, rules: *const Rules, evaluation: Evaluation) Error!Compiled {
    var compiled: Compiled = .{
        .arena = .init(allocator),
        .predicate = "",
        .values = &.{},
        .order = "",
        .limit = switch (rules.limit) {
            .tracks => |count| count,
            .hours => max_limit,
        },
        .limit_ms = switch (rules.limit) {
            .tracks => null,
            .hours => |hours| @as(i64, hours) * std.time.ms_per_hour,
        },
    };
    errdefer compiled.arena.deinit();
    compiled.order = try orderTerms(compiled.arena.allocator(), rules.sort, evaluation.seed);
    var writer: Writer = .{ .arena = compiled.arena.allocator(), .now = evaluation.now };
    try writer.group(rules.root);
    switch (rules.sort.field) {
        .playlist_position => |playlist_id| try writer.bind(.{ .integer = playlist_id }),
        .track, .random => {},
    }
    compiled.predicate = writer.text.items;
    compiled.values = writer.values.items;
    return compiled;
}

const shuffle_mask = 0xffff_ffff;
const shuffle_multiplier = 0x045d_9f3b;

fn orderTerms(arena: std.mem.Allocator, sort: Sort, seed: u64) Error![]const u8 {
    return switch (sort.direction) {
        inline else => |direction| switch (sort.field) {
            .track => |track_sort| switch (track_sort) {
                inline else => |field| comptime tracks.orderTerms(field, direction),
            },
            .random => try shuffleTerms(arena, seed, if (direction == .descending) " DESC" else ""),
            .playlist_position => comptime playlistPositionTerms(direction),
        },
    };
}

fn playlistPositionTerms(comptime direction: tracks.SortDirection) []const u8 {
    const suffix = if (direction == .descending) " DESC" else "";
    return "(SELECT min(playlist_entries.position) FROM playlist_entries WHERE playlist_entries.playlist_id = ?" ++
        " AND playlist_entries.recording_id = tracks.recording_id)" ++ suffix ++ " NULLS LAST, tracks.id" ++ suffix;
}

fn splitMix(state: *u64) u64 {
    state.* +%= 0x9e37_79b9_7f4a_7c15;
    var value = state.*;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

/// A seeded 32-bit multiply-xorshift hash of the Track id. Every value is
/// masked to 32 bits before it meets the 27-bit multiplier, so no product
/// leaves SQLite's 64-bit integers for floating point and loses the order's
/// determinism.
fn shuffleTerms(arena: std.mem.Allocator, seed: u64, suffix: []const u8) Error![]const u8 {
    var state = seed;
    const first = try std.fmt.allocPrint(
        arena,
        "((((tracks.id & {[m]d}) + {[a]d}) * {[k]d}) & {[m]d})",
        .{ .m = shuffle_mask, .a = splitMix(&state) & shuffle_mask, .k = shuffle_multiplier },
    );
    const second = try std.fmt.allocPrint(
        arena,
        "(((({[x]s}) + {[b]d}) * {[k]d}) & {[m]d})",
        .{ .x = try xorShift(arena, first), .b = splitMix(&state) & shuffle_mask, .k = shuffle_multiplier, .m = shuffle_mask },
    );
    return std.fmt.allocPrint(arena, "{[h]s}{[s]s}, tracks.id{[s]s}", .{ .h = try xorShift(arena, second), .s = suffix });
}

fn xorShift(arena: std.mem.Allocator, value: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "(({[v]s} | ({[v]s} >> 16)) - ({[v]s} & ({[v]s} >> 16)))", .{ .v = value });
}

const lossless_codecs = "('" ++ codec.codec_id.pcm ++ "', '" ++ codec.codec_id.pcm_float ++ "', '" ++
    codec.codec_id.flac ++ "', '" ++ codec.codec_id.alac ++ "')";

fn column(field: Field) []const u8 {
    return switch (field) {
        .title => "tracks.title",
        .artist => "tracks.artist",
        .album => "tracks.album",
        .album_artist => "tracks.album_artist",
        .codec => "play_file.codec",
        .release_type => "track_release.release_type",
        .year => "(" ++ tracks.release_year ++ ")",
        .play_count => "COALESCE(recording_play_stats.play_count, 0)",
        .rating => "ratings.rating",
        .duration_ms => "tracks.duration_ms",
        .sample_rate => "play_file.sample_rate",
        .bit_depth => "play_file.bit_depth",
        .added_at => "play_file.first_seen_at",
        .last_played_at => "recording_play_stats.last_played_at",
        .loved => "COALESCE(feedback.score, 0) = 1",
        .lossless => "COALESCE(play_file.codec IN " ++ lossless_codecs ++ ", 0)",
        .explicit => "tracks.explicit = 2",
        .has_artwork => "(EXISTS (SELECT 1 FROM observed_file_tags WHERE observed_file_tags.file_id = play_file.id" ++
            " AND observed_file_tags.artwork_byte_size IS NOT NULL) OR " ++ releases.releaseCoverSql("track_release") ++ ")",
        .genre, .in_playlist => unreachable,
    };
}

const track_genre_names =
    "SELECT 1 FROM track_genres JOIN genres ON genres.id = track_genres.genre_id WHERE track_genres.track_id = tracks.id AND ";

const Writer = struct {
    arena: std.mem.Allocator,
    now: i64,
    text: std.ArrayList(u8) = .empty,
    values: std.ArrayList(Bound) = .empty,

    fn put(self: *Writer, fragment: []const u8) Error!void {
        try self.text.appendSlice(self.arena, fragment);
    }

    fn bind(self: *Writer, value: Bound) Error!void {
        try self.values.append(self.arena, value);
    }

    fn group(self: *Writer, value: Group) Error!void {
        if (value.nodes.len == 0) return self.put(switch (value.match) {
            .all => "1",
            .any => "0",
        });
        try self.put("(");
        for (value.nodes, 0..) |node, index| {
            if (index != 0) try self.put(switch (value.match) {
                .all => " AND ",
                .any => " OR ",
            });
            switch (node) {
                .rule => |leaf| try self.rule(leaf),
                .group => |child| try self.group(child),
            }
        }
        try self.put(")");
    }

    fn rule(self: *Writer, value: Rule) Error!void {
        switch (value.field.fieldType()) {
            .boolean => {
                const wanted = value.value.boolean == (value.operator == .is);
                try self.put(if (wanted) "(" else "NOT (");
                try self.put(column(value.field));
                try self.put(")");
            },
            .text => if (value.field == .genre) try self.genre(value) else try self.textRule(column(value.field), value),
            .integer, .date => try self.numberRule(column(value.field), value),
            .playlist => {
                try self.put(if (value.operator == .is) "EXISTS (" else "NOT EXISTS (");
                try self.put("SELECT 1 FROM playlist_entries WHERE playlist_entries.playlist_id = ?" ++
                    " AND playlist_entries.recording_id = tracks.recording_id)");
                try self.bind(.{ .integer = value.value.integer });
            },
        }
    }

    fn textRule(self: *Writer, expression: []const u8, value: Rule) Error!void {
        switch (value.operator) {
            .is_set, .is_not_set => {
                try self.put("NULLIF(");
                try self.put(expression);
                try self.put(if (value.operator == .is_set) ", '') IS NOT NULL" else ", '') IS NULL");
                return;
            },
            .is => {
                try self.put(expression);
                try self.put(" = ? COLLATE NOCASE");
            },
            .is_not => {
                try self.put("(");
                try self.put(expression);
                try self.put(" IS NULL OR ");
                try self.put(expression);
                try self.put(" <> ? COLLATE NOCASE)");
            },
            .contains, .starts_with => {
                try self.put("instr(lower(");
                try self.put(expression);
                try self.put(if (value.operator == .contains) "), lower(?)) > 0" else "), lower(?)) = 1");
            },
            else => unreachable,
        }
        try self.bind(.{ .text = try self.arena.dupe(u8, value.value.text) });
    }

    fn genre(self: *Writer, value: Rule) Error!void {
        switch (value.operator) {
            .is_set => return self.put("EXISTS (SELECT 1 FROM track_genres WHERE track_genres.track_id = tracks.id)"),
            .is_not_set => return self.put("NOT EXISTS (SELECT 1 FROM track_genres WHERE track_genres.track_id = tracks.id)"),
            .is, .is_not => {
                const folded = try genre_alias.fold(self.arena, value.value.text);
                if (folded.key.len == 0) return error.InvalidRuleValue;
                try self.put(if (value.operator == .is) "EXISTS (" else "NOT EXISTS (");
                try self.put(track_genre_names ++ "genres.key = ?)");
                try self.bind(.{ .text = folded.key });
            },
            .contains, .starts_with => {
                const key = try genre_alias.searchKey(self.arena, value.value.text);
                if (key.len == 0) return error.InvalidRuleValue;
                try self.put("EXISTS (" ++ track_genre_names ++ "instr(genres.key, ?)");
                try self.put(if (value.operator == .contains) " > 0)" else " = 1)");
                try self.bind(.{ .text = key });
            },
            else => unreachable,
        }
    }

    fn numberRule(self: *Writer, expression: []const u8, value: Rule) Error!void {
        switch (value.operator) {
            .is_set, .is_not_set => {
                try self.put(expression);
                try self.put(if (value.operator == .is_set) " IS NOT NULL" else " IS NULL");
            },
            .between => {
                try self.put(expression);
                try self.put(" BETWEEN ? AND ?");
                try self.bind(.{ .integer = value.value.range[0] });
                try self.bind(.{ .integer = value.value.range[1] });
            },
            .in_last_days => {
                try self.put(expression);
                try self.put(" >= ?");
                try self.bind(.{ .integer = self.since(value.value.integer) });
            },
            .not_in_last_days => {
                try self.put("(");
                try self.put(expression);
                try self.put(" IS NULL OR ");
                try self.put(expression);
                try self.put(" < ?)");
                try self.bind(.{ .integer = self.since(value.value.integer) });
            },
            .is_not => {
                try self.put("(");
                try self.put(expression);
                try self.put(" IS NULL OR ");
                try self.put(expression);
                try self.put(" <> ?)");
                try self.bind(.{ .integer = value.value.integer });
            },
            .is, .gt, .gte, .lt, .lte => {
                try self.put(expression);
                try self.put(switch (value.operator) {
                    .is => " = ?",
                    .gt => " > ?",
                    .gte => " >= ?",
                    .lt => " < ?",
                    .lte => " <= ?",
                    else => unreachable,
                });
                try self.bind(.{ .integer = value.value.integer });
            },
            else => unreachable,
        }
    }

    fn since(self: *const Writer, days: i64) i64 {
        return self.now -| days * std.time.s_per_day;
    }
};

test "the example rules parse into the groups, sort and limit they spell" {
    var rules = try parse(std.testing.allocator,
        \\{"v":1,"match":"all","rules":[
        \\  {"field":"genre","op":"is","value":"Hip Hop"},
        \\  {"match":"any","rules":[{"field":"loved","op":"is","value":true},{"field":"rating","op":"gte","value":80}]},
        \\  {"field":"added_at","op":"in_last_days","value":30}
        \\],"sort":{"field":"added_at","descending":true},"limit":200}
    );
    defer rules.deinit();
    try std.testing.expectEqual(Match.all, rules.root.match);
    try std.testing.expectEqual(@as(usize, 3), rules.root.nodes.len);
    try std.testing.expectEqual(Field.genre, rules.root.nodes[0].rule.field);
    try std.testing.expectEqualStrings("Hip Hop", rules.root.nodes[0].rule.value.text);
    try std.testing.expectEqual(Match.any, rules.root.nodes[1].group.match);
    try std.testing.expectEqual(@as(i64, 80), rules.root.nodes[1].group.nodes[1].rule.value.integer);
    try std.testing.expectEqual(SortField{ .track = .date_added }, rules.sort.field);
    try std.testing.expectEqual(tracks.SortDirection.descending, rules.sort.direction);
    try std.testing.expectEqual(Limit{ .tracks = 200 }, rules.limit);
}

test "rules name only whitelisted fields and operators, with values of the field's type" {
    const cases = [_]struct { json: []const u8, err: Error }{
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"path\",\"op\":\"is\",\"value\":\"x\"}]}", .err = error.UnknownRuleField },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"like\",\"value\":\"x\"}]}", .err = error.UnknownRuleOperator },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"year\",\"op\":\"contains\",\"value\":\"x\"}]}", .err = error.RuleOperatorMismatch },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"loved\",\"op\":\"gt\",\"value\":1}]}", .err = error.RuleOperatorMismatch },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"year\",\"op\":\"is\",\"value\":\"1999\"}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"is\",\"value\":\"\"}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"year\",\"op\":\"between\",\"value\":[1]}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"added_at\",\"op\":\"in_last_days\",\"value\":0}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"is_set\",\"value\":\"x\"}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"uri\"}}", .err = error.UnknownRuleField },
        .{ .json = "{\"v\":2,\"rules\":[]}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"rules\":[]}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[],\"limit\":10001}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[],\"limit\":0}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[],\"limit\":5,\"limit_hours\":1}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[],\"limit_hours\":0}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[],\"limit_hours\":10001}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[],\"limit_hours\":1.5}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"in_playlist\",\"op\":\"gt\",\"value\":1}]}", .err = error.RuleOperatorMismatch },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":0}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":\"1\"}]}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[],\"extra\":1}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"v\":1,\"rules\":[]}", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "[1]", .err = error.InvalidSmartPlaylistRules },
        .{ .json = "{\"v\":1,\"rules\":[", .err = error.InvalidSmartPlaylistRules },
    };
    for (cases) |case| try std.testing.expectError(case.err, parse(std.testing.allocator, case.json));
}

test "rules nest at most four groups deep" {
    try validate(std.testing.allocator,
        \\{"v":1,"rules":[{"rules":[{"rules":[{"rules":[{"field":"loved","op":"is","value":true}]}]}]}]}
    );
    try std.testing.expectError(error.RuleNestingTooDeep, parse(std.testing.allocator,
        \\{"v":1,"rules":[{"rules":[{"rules":[{"rules":[{"rules":[{"field":"loved","op":"is","value":true}]}]}]}]}]}
    ));
}

test "rules hold at most thirty-two leaf rules across every group" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    for (0..2) |round| {
        const leaves: usize = if (round == 0) 32 else 33;
        json.clearRetainingCapacity();
        try json.appendSlice(std.testing.allocator, "{\"v\":1,\"rules\":[{\"match\":\"any\",\"rules\":[");
        for (0..leaves) |index| {
            if (index == 16) try json.appendSlice(std.testing.allocator, "]},{\"rules\":[");
            if (index != 0 and index != 16) try json.append(std.testing.allocator, ',');
            try json.appendSlice(std.testing.allocator, "{\"field\":\"play_count\",\"op\":\"gt\",\"value\":1}");
        }
        try json.appendSlice(std.testing.allocator, "]}]}");
        if (round == 0)
            try validate(std.testing.allocator, json.items)
        else
            try std.testing.expectError(error.TooManyRules, parse(std.testing.allocator, json.items));
    }
}

test "a compiled predicate carries every value as a parameter and none in its text" {
    const hostile = "x') OR 1=1; DROP TABLE tracks; --";
    var rules = try parse(std.testing.allocator,
        \\{"v":1,"match":"any","rules":[
        \\  {"field":"title","op":"is","value":"x') OR 1=1; DROP TABLE tracks; --"},
        \\  {"field":"artist","op":"contains","value":"x') OR 1=1; DROP TABLE tracks; --"},
        \\  {"field":"year","op":"between","value":[2001,1999]},
        \\  {"field":"last_played_at","op":"not_in_last_days","value":7}
        \\]}
    );
    defer rules.deinit();
    var compiled = try compile(std.testing.allocator, &rules, .{ .now = 1_000_000, .seed = 0 });
    defer compiled.deinit();
    try std.testing.expect(std.mem.indexOf(u8, compiled.predicate, "DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, compiled.predicate, "1999") == null);
    try std.testing.expectEqual(@as(usize, 5), compiled.values.len);
    try std.testing.expectEqual(compiled.values.len, std.mem.count(u8, compiled.predicate, "?"));
    try std.testing.expectEqualStrings(hostile, compiled.values[0].text);
    try std.testing.expectEqualStrings(hostile, compiled.values[1].text);
    try std.testing.expectEqual(@as(i64, 1999), compiled.values[2].integer);
    try std.testing.expectEqual(@as(i64, 2001), compiled.values[3].integer);
    try std.testing.expectEqual(@as(i64, 1_000_000 - 7 * std.time.s_per_day), compiled.values[4].integer);
}

test "a random sort, an hour limit and playlist membership parse beside the version 1 keys" {
    var rules = try parse(std.testing.allocator,
        \\{"v":1,"rules":[
        \\  {"field":"in_playlist","op":"is","value":7},
        \\  {"match":"any","rules":[{"field":"in_playlist","op":"is_not","value":9},{"field":"in_playlist","op":"is","value":7}]}
        \\],"sort":{"field":"random"},"limit_hours":2}
    );
    defer rules.deinit();
    try std.testing.expectEqual(SortField.random, rules.sort.field);
    try std.testing.expectEqual(Limit{ .hours = 2 }, rules.limit);
    var buffer: [max_referenced_playlists]i64 = undefined;
    try std.testing.expectEqualSlices(i64, &.{ 7, 9 }, referencedPlaylists(&rules, &buffer));
    var compiled = try compile(std.testing.allocator, &rules, .{ .now = 0, .seed = 42 });
    defer compiled.deinit();
    try std.testing.expectEqual(@as(?i64, 2 * std.time.ms_per_hour), compiled.limit_ms);
    try std.testing.expectEqual(@as(u32, max_limit), compiled.limit);
    try std.testing.expectEqual(compiled.values.len, std.mem.count(u8, compiled.predicate, "?"));
}

test "a random order depends on the seed and on nothing else" {
    var rules = try parse(std.testing.allocator, "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"random\"}}");
    defer rules.deinit();
    var first = try compile(std.testing.allocator, &rules, .{ .now = 0, .seed = 1 });
    defer first.deinit();
    var again = try compile(std.testing.allocator, &rules, .{ .now = 99, .seed = 1 });
    defer again.deinit();
    var other = try compile(std.testing.allocator, &rules, .{ .now = 0, .seed = 0xdead_beef_cafe_f00d });
    defer other.deinit();
    try std.testing.expectEqualStrings(first.order, again.order);
    try std.testing.expect(!std.mem.eql(u8, first.order, other.order));
    try std.testing.expect(std.mem.endsWith(u8, first.order, ", tracks.id"));
}

test "a playlist position sort binds its playlist after the predicate and sorts Tracks it does not hold last" {
    var rules = try parse(std.testing.allocator,
        \\{"v":1,"rules":[{"field":"in_playlist","op":"is","value":7},{"field":"title","op":"contains","value":"a"}],
        \\"sort":{"field":"playlist_position","playlist":3,"descending":true}}
    );
    defer rules.deinit();
    try std.testing.expectEqual(SortField{ .playlist_position = 3 }, rules.sort.field);
    var buffer: [max_referenced_playlists]i64 = undefined;
    try std.testing.expectEqualSlices(i64, &.{ 7, 3 }, referencedPlaylists(&rules, &buffer));
    var compiled = try compile(std.testing.allocator, &rules, .{ .now = 0, .seed = 0 });
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 3), compiled.values.len);
    try std.testing.expectEqual(@as(i64, 3), compiled.values[2].integer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, compiled.order, "?"));
    try std.testing.expect(std.mem.indexOf(u8, compiled.order, " DESC NULLS LAST") != null);
}

test "a playlist position sort needs a playlist id, and no other sort takes one" {
    const cases = [_]struct { json: []const u8, err: Error }{
        .{ .json = "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"playlist_position\"}}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"playlist_position\",\"playlist\":0}}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"playlist_position\",\"playlist\":\"3\"}}", .err = error.InvalidRuleValue },
        .{ .json = "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"title\",\"playlist\":3}}", .err = error.InvalidSmartPlaylistRules },
    };
    for (cases) |case| try std.testing.expectError(case.err, parse(std.testing.allocator, case.json));
}
