//! The words for why Radio picked a Track, from its `PickReason` and the
//! names the reason refers to.

const std = @import("std");
const liborca = @import("liborca");

const ReasonPart = liborca.ReasonPart;
const PickReason = liborca.PickReason;

/// What a reason part names, for the caller to look up.
pub const Lookup = union(enum) {
    none,
    artist: i64,
    genre: i64,
    recording: i64,
};

pub fn lookup(part: ReasonPart) Lookup {
    return switch (part.kind) {
        .same_artist, .related_artist => .{ .artist = part.a },
        .shared_genre => .{ .genre = part.a },
        .often_after => if (part.b == 1) .{ .artist = part.a } else .{ .recording = part.a },
        else => .none,
    };
}

pub const Clock = struct {
    now_s: i64,
    utc_offset_s: i64,
};

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

const LocalMonth = struct {
    year: i64,
    month: u4,

    fn index(self: LocalMonth) i64 {
        return self.year * 12 + (self.month - 1);
    }
};

fn localDay(unix_s: i64, clock: Clock) i64 {
    return @divFloor(unix_s + clock.utc_offset_s, std.time.s_per_day);
}

fn localMonth(unix_s: i64, clock: Clock) LocalMonth {
    const day = localDay(unix_s, clock);
    if (day < 0) return .{ .year = 1970, .month = 1 };
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day) };
    const year_day = epoch_day.calculateYearDay();
    return .{ .year = year_day.year, .month = year_day.calculateMonthDay().month.numeric() };
}

fn writePlayCount(writer: *std.Io.Writer, count: i64) !void {
    switch (count) {
        1 => try writer.writeAll("Played once"),
        2 => try writer.writeAll("Played twice"),
        else => try writer.print("Played {d} times", .{count}),
    }
}

fn writeNotSince(writer: *std.Io.Writer, last_played_s: i64, clock: Clock) !void {
    if (last_played_s <= 0) return;
    const now = localMonth(clock.now_s, clock);
    const last = localMonth(last_played_s, clock);
    const months_ago = now.index() - last.index();
    if (months_ago <= 0) return;
    if (months_ago < 12)
        try writer.print(" · not since {s}", .{month_names[last.month - 1]})
    else
        try writer.print(" · not since {d}", .{last.year});
}

fn writeAgo(writer: *std.Io.Writer, count: i64, unit: []const u8) !void {
    try writer.print("{d} {s}{s} ago", .{ count, unit, if (count == 1) "" else "s" });
}

fn writeAdded(writer: *std.Io.Writer, added_s: i64, clock: Clock) !void {
    const days = localDay(clock.now_s, clock) - localDay(added_s, clock);
    if (days <= 0) return writer.writeAll("Added today");
    if (days == 1) return writer.writeAll("Added yesterday");
    try writer.writeAll("Added ");
    if (days < 7) return writeAgo(writer, days, "day");
    if (days < 30) return writeAgo(writer, @divFloor(days, 7), "week");
    if (days < 365) return writeAgo(writer, @divFloor(days, 30), "month");
    try writeAgo(writer, @divFloor(days, 365), "year");
}

fn writeSounds(writer: *std.Io.Writer, flags: i64) !void {
    const sounds = [_]struct { i64, []const u8 }{
        .{ liborca.radio_sound_tempo, "tempo" },
        .{ liborca.radio_sound_key, "key" },
        .{ liborca.radio_sound_energy, "energy" },
    };
    const total = @popCount(flags & (liborca.radio_sound_tempo | liborca.radio_sound_key | liborca.radio_sound_energy));
    if (total == 0) return writer.writeAll("Similar sound");
    try writer.writeAll("Similar");
    var count: usize = 0;
    for (sounds) |sound| {
        if (flags & sound[0] == 0) continue;
        count += 1;
        const separator = if (count == 1) " " else if (count == total) " and " else ", ";
        try writer.print("{s}{s}", .{ separator, sound[1] });
    }
}

/// Writes one part; `name` is what `lookup` asked for, empty when unknown.
pub fn writePart(writer: *std.Io.Writer, part: ReasonPart, name: []const u8, clock: Clock) !void {
    switch (part.kind) {
        .played => {
            try writePlayCount(writer, part.a);
            try writeNotSince(writer, part.b, clock);
        },
        .loved => try writer.writeAll("Loved"),
        .same_artist => if (name.len == 0)
            try writer.writeAll("Same artist")
        else
            try writer.print("By {s}", .{name}),
        .related_artist => if (name.len == 0)
            try writer.writeAll("Related artist")
        else
            try writer.print("Related to {s}", .{name}),
        .shared_genre => if (name.len == 0)
            try writer.writeAll("Shares a genre")
        else
            try writer.print("Also tagged {s}", .{name}),
        .often_after => if (name.len == 0)
            try writer.writeAll("Often played together")
        else
            try writer.print("Often played after {s}", .{name}),
        .similar_sound => try writeSounds(writer, part.a),
        .never_played => try writer.writeAll("Never played"),
        .rarely_played => try writePlayCount(writer, part.a),
        .added => try writeAdded(writer, part.a, clock),
    }
}

/// Both parts joined with " · ", the second starting in lower case.
pub fn format(buffer: []u8, reason: PickReason, names: [2][]const u8, clock: Clock) [:0]const u8 {
    std.debug.assert(buffer.len != 0);
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    if (reason.first) |part| writePart(&writer, part, names[0], clock) catch {};
    if (reason.second) |part| {
        const start = writer.end;
        if (start != 0) writer.writeAll(" · ") catch {};
        const word = writer.end;
        writePart(&writer, part, names[1], clock) catch {};
        if (start != 0 and word < writer.end and !keepsCapital(part.kind)) buffer[word] = std.ascii.toLower(buffer[word]);
    }
    var end = writer.end;
    while (end != 0 and !std.unicode.utf8ValidateSlice(buffer[0..end])) end -= 1;
    buffer[end] = 0;
    return buffer[0..end :0];
}

fn keepsCapital(kind: liborca.ReasonKind) bool {
    return kind == .same_artist;
}

const testing = std.testing;
const october_7_2026: Clock = .{ .now_s = 1_791_374_400, .utc_offset_s = 0 };
const march_2_2026: i64 = 1_772_452_800;

fn expectReason(expected: []const u8, reason: PickReason, names: [2][]const u8) !void {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, format(&buffer, reason, names, october_7_2026));
}

test "format_playedThisYear_namesTheMonth" {
    try expectReason("Played 42 times · not since March", .{ .first = .{ .kind = .played, .a = 42, .b = march_2_2026 } }, .{ "", "" });
}

test "format_playedOverAYearAgo_namesTheYear" {
    try expectReason("Played 9 times · not since 2024", .{ .first = .{ .kind = .played, .a = 9, .b = 1_717_243_200 } }, .{ "", "" });
}

test "format_playedThisMonth_omitsWhen" {
    try expectReason("Played 3 times", .{ .first = .{ .kind = .played, .a = 3, .b = october_7_2026.now_s - 3600 } }, .{ "", "" });
}

test "format_twoParts_joinsWithLowerCaseSecond" {
    try expectReason("Similar tempo and energy · never played", .{
        .first = .{ .kind = .similar_sound, .a = liborca.radio_sound_tempo | liborca.radio_sound_energy },
        .second = .{ .kind = .never_played },
    }, .{ "", "" });
}

test "format_secondPartByArtist_keepsCapital" {
    try expectReason("Loved · By Aminé", .{ .first = .{ .kind = .loved }, .second = .{ .kind = .same_artist, .a = 4 } }, .{ "", "Aminé" });
}

test "format_namedParts_useTheNames" {
    try expectReason("Related to Aminé", .{ .first = .{ .kind = .related_artist, .a = 1, .b = 2 } }, .{ "Aminé", "" });
    try expectReason("Also tagged Hip Hop", .{ .first = .{ .kind = .shared_genre, .a = 3 } }, .{ "Hip Hop", "" });
    try expectReason("Often played after Caroline", .{ .first = .{ .kind = .often_after, .a = 7 } }, .{ "Caroline", "" });
}

test "format_unknownNames_fallBackToGenericWords" {
    try expectReason("Same artist · related artist", .{
        .first = .{ .kind = .same_artist, .a = 1 },
        .second = .{ .kind = .related_artist, .a = 1 },
    }, .{ "", "" });
}

test "format_rarelyPlayed_countsInWords" {
    try expectReason("Played once", .{ .first = .{ .kind = .rarely_played, .a = 1 } }, .{ "", "" });
    try expectReason("Played twice", .{ .first = .{ .kind = .rarely_played, .a = 2 } }, .{ "", "" });
}

test "format_added_saysHowLongAgo" {
    const day = std.time.s_per_day;
    try expectReason("Added today", .{ .first = .{ .kind = .added, .a = october_7_2026.now_s - 60 } }, .{ "", "" });
    try expectReason("Added yesterday", .{ .first = .{ .kind = .added, .a = october_7_2026.now_s - day } }, .{ "", "" });
    try expectReason("Added 2 weeks ago", .{ .first = .{ .kind = .added, .a = october_7_2026.now_s - 15 * day } }, .{ "", "" });
    try expectReason("Added 1 year ago", .{ .first = .{ .kind = .added, .a = october_7_2026.now_s - 400 * day } }, .{ "", "" });
}

test "format_similarSound_listsEveryFlag" {
    try expectReason("Similar tempo, key and energy", .{ .first = .{ .kind = .similar_sound, .a = 7 } }, .{ "", "" });
    try expectReason("Similar sound", .{ .first = .{ .kind = .similar_sound, .a = 0 } }, .{ "", "" });
}

test "format_noReason_isEmpty" {
    try expectReason("", .{}, .{ "", "" });
}

test "format_smallBuffer_cutsAtACharacterBoundary" {
    var buffer: [11]u8 = undefined;
    const text = format(&buffer, .{ .first = .{ .kind = .same_artist, .a = 1 } }, .{ "Aminéé", "" }, october_7_2026);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expectEqualStrings("By Aminé", text);
}

test "lookup_oftenAfter_asksForRecordingOrArtist" {
    try testing.expectEqual(Lookup{ .recording = 7 }, lookup(.{ .kind = .often_after, .a = 7, .b = 0 }));
    try testing.expectEqual(Lookup{ .artist = 7 }, lookup(.{ .kind = .often_after, .a = 7, .b = 1 }));
    try testing.expectEqual(Lookup.none, lookup(.{ .kind = .loved }));
}
