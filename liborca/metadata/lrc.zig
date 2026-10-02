//! LRC lyrics: `[mm:ss.xx]` timed lines, ID tags, and plain text.
//!
//! The one parser for every lyrics text Orca reads: `.lrc` sidecars, embedded
//! lyrics frames and comments, and provider responses. Timestamps terminate
//! here; everything above sees milliseconds.

const std = @import("std");
const lyrics = @import("lyrics.zig");

const Line = lyrics.Line;
const Content = lyrics.Content;

const TimedLine = struct {
    start_ms: i64,
    text: []const u8,
};

const Timestamp = union(enum) {
    valid: i64,
    invalid,
    not_timestamp,
};

/// Parse LRC or plain text into lines allocated with `allocator`, which should
/// be an arena: on success nothing is freed separately. Null when the text
/// exceeds the bounds, is not UTF-8, or carries no lyric text.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !?Content {
    if (input.len > lyrics.max_text_bytes) return null;
    var text = input;
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text = text[3..];
    if (!std.unicode.utf8ValidateSlice(text)) return null;

    var timed: std.ArrayList(TimedLine) = .empty;
    defer timed.deinit(allocator);
    var plain: std.ArrayList([]const u8) = .empty;
    defer plain.deinit(allocator);
    var offset_ms: i64 = 0;
    var any_text = false;

    var rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |raw| {
        const row = std.mem.trim(u8, raw, " \t\r");
        if (row.len > 0 and row[0] == '#') continue;

        var rest = row;
        var stamps: [lyrics.max_lines]i64 = undefined;
        var stamp_count: usize = 0;
        var dropped = false;
        var tag_only = false;
        while (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
            const inner = rest[1..close];
            switch (parseTimestamp(inner)) {
                .valid => |ms| {
                    if (stamp_count == stamps.len) return null;
                    stamps[stamp_count] = ms;
                    stamp_count += 1;
                },
                .invalid => dropped = true,
                .not_timestamp => {
                    if (stamp_count == 0 and !dropped and isIdTag(inner) and
                        std.mem.trim(u8, rest[close + 1 ..], " \t").len == 0)
                    {
                        if (tagValue(inner, "offset")) |value| {
                            offset_ms = std.fmt.parseInt(i64, std.mem.trim(u8, value, " "), 10) catch offset_ms;
                        }
                        tag_only = true;
                    }
                    break;
                },
            }
            rest = rest[close + 1 ..];
            if (dropped) break;
        }
        if (tag_only or dropped) continue;

        if (stamp_count > 0) {
            const line_text = try stripWordStamps(allocator, std.mem.trim(u8, rest, " \t"));
            if (line_text.len > 0) any_text = true;
            for (stamps[0..stamp_count]) |stamp| {
                if (timed.items.len == lyrics.max_lines) return null;
                try timed.append(allocator, .{ .start_ms = stamp, .text = line_text });
            }
        } else {
            if (row.len > 0) any_text = true;
            if (plain.items.len == lyrics.max_lines) return null;
            try plain.append(allocator, row);
        }
    }

    if (!any_text) return null;

    if (timed.items.len > 0) {
        const lines = try allocator.alloc(Line, timed.items.len);
        for (timed.items, lines) |entry, *line| {
            const start = std.math.clamp(entry.start_ms -| offset_ms, 0, std.math.maxInt(u32));
            line.* = .{ .start_ms = @intCast(start), .text = entry.text };
        }
        lyrics.sortLines(lines);
        return .{ .kind = .synced, .lines = lines };
    }

    var first: usize = 0;
    var last: usize = plain.items.len;
    while (first < last and plain.items[first].len == 0) first += 1;
    while (last > first and plain.items[last - 1].len == 0) last -= 1;
    const lines = try allocator.alloc(Line, last - first);
    for (plain.items[first..last], lines) |row, *line| {
        line.* = .{ .start_ms = null, .text = try allocator.dupe(u8, row) };
    }
    return .{ .kind = .plain, .lines = lines };
}

fn parseTimestamp(inner: []const u8) Timestamp {
    if (inner.len == 0 or !std.ascii.isDigit(inner[0])) return .not_timestamp;
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return .not_timestamp;
    const minutes_text = inner[0..colon];
    const after = inner[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, after, '.');
    const seconds_text = if (dot) |index| after[0..index] else after;
    const fraction_text = if (dot) |index| after[index + 1 ..] else "";
    if (!allDigits(minutes_text) or seconds_text.len == 0 or !allDigits(seconds_text) or !allDigits(fraction_text))
        return .not_timestamp;
    if (dot != null and (fraction_text.len == 0 or fraction_text.len > 3)) return .invalid;
    const minutes = std.fmt.parseInt(u32, minutes_text, 10) catch return .invalid;
    const seconds = std.fmt.parseInt(u32, seconds_text, 10) catch return .invalid;
    if (seconds >= 60) return .invalid;
    var fraction: i64 = if (fraction_text.len == 0) 0 else std.fmt.parseInt(u16, fraction_text, 10) catch return .invalid;
    var digits = fraction_text.len;
    while (digits < 3 and fraction_text.len > 0) : (digits += 1) fraction *= 10;
    const total = (@as(i64, minutes) * 60 + seconds) * 1000 + fraction;
    if (total > std.math.maxInt(u32)) return .invalid;
    return .{ .valid = total };
}

fn allDigits(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isIdTag(inner: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return false;
    if (colon == 0) return false;
    for (inner[0..colon]) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    return true;
}

fn tagValue(inner: []const u8, key: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return null;
    if (!std.ascii.eqlIgnoreCase(inner[0..colon], key)) return null;
    return inner[colon + 1 ..];
}

fn stripWordStamps(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '<') {
            if (std.mem.indexOfScalarPos(u8, text, index, '>')) |close| {
                if (parseTimestamp(text[index + 1 .. close]) != .not_timestamp) {
                    index = close + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    const owned = try out.toOwnedSlice(allocator);
    return std.mem.trim(u8, owned, " \t");
}

const testing = std.testing;

fn expectParsed(input: []const u8) !struct { std.heap.ArenaAllocator, ?Content } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const content = try parse(arena.allocator(), input);
    return .{ arena, content };
}

test "a line with two leading timestamps becomes one line at each" {
    var arena, const content = try expectParsed("[00:12.40][01:30.00]Chorus\n[00:20.00]Verse\n");
    defer arena.deinit();
    const parsed = content.?;
    try testing.expectEqual(lyrics.Kind.synced, parsed.kind);
    try testing.expectEqual(@as(usize, 3), parsed.lines.len);
    try testing.expectEqual(@as(?u32, 12400), parsed.lines[0].start_ms);
    try testing.expectEqualStrings("Chorus", parsed.lines[0].text);
    try testing.expectEqual(@as(?u32, 20000), parsed.lines[1].start_ms);
    try testing.expectEqual(@as(?u32, 90000), parsed.lines[2].start_ms);
    try testing.expectEqualStrings("Chorus", parsed.lines[2].text);
}

test "a positive offset moves lines earlier and clamps at zero" {
    var arena, const content = try expectParsed("[offset:+500]\n[00:00.20]Early\n[00:01.00]Second\n");
    defer arena.deinit();
    const parsed = content.?;
    try testing.expectEqual(@as(?u32, 0), parsed.lines[0].start_ms);
    try testing.expectEqual(@as(?u32, 500), parsed.lines[1].start_ms);
}

test "a negative offset moves lines later" {
    var arena, const content = try expectParsed("[00:01.00]Line\n[offset:-250]\n");
    defer arena.deinit();
    try testing.expectEqual(@as(?u32, 1250), content.?.lines[0].start_ms);
}

test "an offset at the limits of its type clamps instead of overflowing" {
    var arena, const content = try expectParsed("[offset:-9223372036854775808]\n[00:01.00]Late\n");
    defer arena.deinit();
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), content.?.lines[0].start_ms);
    var arena_max, const early = try expectParsed("[offset:9223372036854775807]\n[00:01.00]Early\n");
    defer arena_max.deinit();
    try testing.expectEqual(@as(?u32, 0), early.?.lines[0].start_ms);
}

test "one fractional digit is tenths and single-digit minutes are accepted" {
    var arena, const content = try expectParsed("[1:02.5]Tenths\n[00:03.123]Millis\n[00:04]Whole\n");
    defer arena.deinit();
    const parsed = content.?;
    try testing.expectEqual(@as(?u32, 3123), parsed.lines[0].start_ms);
    try testing.expectEqual(@as(?u32, 4000), parsed.lines[1].start_ms);
    try testing.expectEqual(@as(?u32, 62500), parsed.lines[2].start_ms);
}

test "a timestamp with sixty or more seconds drops only its own line" {
    var arena, const content = try expectParsed("[00:61.00]Bad\n[00:02.00]Good\n");
    defer arena.deinit();
    const parsed = content.?;
    try testing.expectEqual(@as(usize, 1), parsed.lines.len);
    try testing.expectEqualStrings("Good", parsed.lines[0].text);
}

test "text with only ID tags and comments carries no lyrics" {
    var arena, const content = try expectParsed("[ar:Artist]\r\n[ti:Title]\r\n# a comment\r\n[length:03:20]\r\n");
    defer arena.deinit();
    try testing.expect(content == null);
}

test "enhanced word stamps are removed from the line text" {
    var arena, const content = try expectParsed("[00:01.00]<00:01.00>Hello <00:01.50>world\n");
    defer arena.deinit();
    try testing.expectEqualStrings("Hello world", content.?.lines[0].text);
}

test "text without timestamps is plain, one line per row, with BOM and CRLF tolerated" {
    var arena, const content = try expectParsed("\xef\xbb\xbf\r\n[ar:Someone]\r\nFirst row\r\n\r\n[Chorus]\r\nSecond row\r\n\r\n");
    defer arena.deinit();
    const parsed = content.?;
    try testing.expectEqual(lyrics.Kind.plain, parsed.kind);
    try testing.expectEqual(@as(usize, 4), parsed.lines.len);
    try testing.expectEqualStrings("First row", parsed.lines[0].text);
    try testing.expectEqualStrings("", parsed.lines[1].text);
    try testing.expectEqualStrings("[Chorus]", parsed.lines[2].text);
    try testing.expectEqual(@as(?u32, null), parsed.lines[3].start_ms);
}

test "timed lines win over untimed rows in the same text" {
    var arena, const content = try expectParsed("Title row\n[00:05.00]Five\n[00:01.00]One\n");
    defer arena.deinit();
    const parsed = content.?;
    try testing.expectEqual(lyrics.Kind.synced, parsed.kind);
    try testing.expectEqual(@as(usize, 2), parsed.lines.len);
    try testing.expectEqualStrings("One", parsed.lines[0].text);
}

test "text that is not UTF-8 is not lyrics" {
    var arena, const content = try expectParsed("[00:01.00]caf\xe9\n");
    defer arena.deinit();
    try testing.expect(content == null);
}

test "more lines than the bound is not lyrics" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..lyrics.max_lines + 1) |_| try text.appendSlice(testing.allocator, "la\n");
    var arena, const content = try expectParsed(text.items);
    defer arena.deinit();
    try testing.expect(content == null);
}
