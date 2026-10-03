const std = @import("std");
const dsp = @import("dsp.zig");

const Filter = dsp.Filter;
const FilterKind = dsp.FilterKind;
const ParametricEqualizer = dsp.ParametricEqualizer;

/// The Q of a filter line that names none, and of the plain `LS` and `HS`
/// shelves, which have no Q.
pub const default_q: f32 = 0.707;

const Tokens = std.mem.TokenIterator(u8, .any);

const type_names = [_]struct { []const u8, FilterKind }{
    .{ "PK", .peak },
    .{ "PEQ", .peak },
    .{ "LSC", .low_shelf },
    .{ "LS", .low_shelf },
    .{ "HSC", .high_shelf },
    .{ "HS", .high_shelf },
    .{ "LP", .low_pass },
    .{ "HP", .high_pass },
    .{ "NO", .notch },
};

/// Reads an EqualizerAPO configuration: `Preamp:` lines, which add up, and
/// up to sixteen `Filter:` lines of type PK, PEQ, LS, LSC, HS, HSC, LP, HP or
/// NO, each with `Fc`, and `Gain` and `Q` or `BW Oct` where they apply.
/// Blank lines and `#` comments are skipped; any other line is rejected,
/// since ignoring a `Channel:` or `Include:` would apply filters meant for
/// something else. The result is validated.
pub fn parseEqualizerApo(text: []const u8) !ParametricEqualizer {
    var result: ParametricEqualizer = .{};
    const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidEqualizerApo;
        const command = std.mem.trim(u8, line[0..colon], " \t");
        var tokens = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t\r");
        if (std.ascii.eqlIgnoreCase(command, "Preamp")) {
            result.preamp_db += try number(tokens.next());
            skipUnit(&tokens, "dB");
            if (tokens.next() != null) return error.InvalidEqualizerApo;
        } else if (isFilterCommand(command)) {
            if (result.count == dsp.max_parametric_filters) return error.TooManyFilters;
            result.filters[result.count] = try parseFilter(&tokens);
            result.count += 1;
        } else return error.InvalidEqualizerApo;
    }
    try result.validate();
    return result;
}

/// Writes `equalizer` as EqualizerAPO text that `parseEqualizerApo` reads
/// back to the same filters: shelves as LSC and HSC, `Gain` only on the peak
/// and shelves, and `Q` on every filter.
pub fn writeEqualizerApo(writer: *std.Io.Writer, equalizer: ParametricEqualizer) std.Io.Writer.Error!void {
    try writer.print("Preamp: {d} dB\n", .{equalizer.preamp_db});
    for (equalizer.filterList(), 1..) |filter, position| {
        try writer.print("Filter {d}: {s} {s} Fc {d} Hz", .{
            position,
            if (filter.enabled) "ON" else "OFF",
            typeName(filter.kind),
            filter.frequency_hz,
        });
        if (filter.usesGain()) try writer.print(" Gain {d} dB", .{filter.gain_db});
        try writer.print(" Q {d}\n", .{filter.q});
    }
}

/// The Q of a bandwidth of `octaves`, by the analog relation
/// Q = 2^(N/2) / (2^N - 1).
pub fn qFromOctaves(octaves: f32) f32 {
    const ratio = std.math.pow(f64, 2, octaves);
    return @floatCast(@sqrt(ratio) / (ratio - 1));
}

fn isFilterCommand(command: []const u8) bool {
    if (command.len < "Filter".len or !std.ascii.eqlIgnoreCase(command[0.."Filter".len], "Filter"))
        return false;
    const label = std.mem.trimStart(u8, command["Filter".len..], " \t");
    for (label) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn parseFilter(tokens: *Tokens) !Filter {
    const state = tokens.next() orelse return error.InvalidEqualizerApo;
    const enabled = if (std.ascii.eqlIgnoreCase(state, "ON"))
        true
    else if (std.ascii.eqlIgnoreCase(state, "OFF"))
        false
    else
        return error.InvalidEqualizerApo;
    const kind = try filterKind(tokens.next() orelse return error.InvalidEqualizerApo);
    if (kind == .low_shelf or kind == .high_shelf) {
        if (tokens.peek()) |slope| {
            if (slope.len > 2 and std.ascii.endsWithIgnoreCase(slope, "dB")) return error.UnsupportedFilterType;
        }
    }

    var frequency_hz: ?f32 = null;
    var gain_db: ?f32 = null;
    var q: ?f32 = null;
    while (tokens.next()) |key| {
        if (std.ascii.eqlIgnoreCase(key, "Fc")) {
            if (frequency_hz != null) return error.InvalidEqualizerApo;
            frequency_hz = try number(tokens.next());
            skipUnit(tokens, "Hz");
        } else if (std.ascii.eqlIgnoreCase(key, "Gain")) {
            if (gain_db != null) return error.InvalidEqualizerApo;
            gain_db = try number(tokens.next());
            skipUnit(tokens, "dB");
        } else if (std.ascii.eqlIgnoreCase(key, "Q")) {
            if (q != null) return error.InvalidEqualizerApo;
            q = try number(tokens.next());
        } else if (std.ascii.eqlIgnoreCase(key, "BW")) {
            if (q != null) return error.InvalidEqualizerApo;
            const unit = tokens.next() orelse return error.InvalidEqualizerApo;
            if (!std.ascii.eqlIgnoreCase(unit, "Oct")) return error.InvalidEqualizerApo;
            q = qFromOctaves(try number(tokens.next()));
        } else return error.InvalidEqualizerApo;
    }

    var filter: Filter = .{
        .kind = kind,
        .frequency_hz = frequency_hz orelse return error.InvalidEqualizerApo,
        .q = q orelse default_q,
        .enabled = enabled,
    };
    if (filter.usesGain()) filter.gain_db = gain_db orelse 0;
    return filter;
}

fn filterKind(token: []const u8) !FilterKind {
    for (type_names) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    }
    return error.UnsupportedFilterType;
}

fn typeName(kind: FilterKind) []const u8 {
    return switch (kind) {
        .peak => "PK",
        .low_shelf => "LSC",
        .high_shelf => "HSC",
        .low_pass => "LP",
        .high_pass => "HP",
        .notch => "NO",
    };
}

fn number(token: ?[]const u8) !f32 {
    return std.fmt.parseFloat(f32, token orelse return error.InvalidEqualizerApo) catch
        error.InvalidEqualizerApo;
}

fn skipUnit(tokens: *Tokens, unit: []const u8) void {
    if (tokens.peek()) |next| {
        if (std.ascii.eqlIgnoreCase(next, unit)) _ = tokens.next();
    }
}

const hd650_text =
    \\Preamp: -3 dB
    \\Filter 1: ON LSC Fc 105 Hz Gain 3.0 dB Q 0.71
    \\Filter 2: ON PK Fc 1000 Hz Gain -2.0 dB Q 1.41
    \\Filter 3: ON PK Fc 3000 Hz Gain 2.5 dB Q 2.0
    \\Filter 4: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71
    \\
;

fn expectSameEqualizer(expected: ParametricEqualizer, actual: ParametricEqualizer) !void {
    try std.testing.expectEqual(expected.preamp_db, actual.preamp_db);
    try std.testing.expectEqualSlices(Filter, expected.filterList(), actual.filterList());
}

fn written(buffer: []u8, equalizer: ParametricEqualizer) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writeEqualizerApo(&writer, equalizer);
    return writer.buffered();
}

test "an EqualizerAPO file reads back to the same filters it was written from" {
    const parsed = try parseEqualizerApo(hd650_text);
    try std.testing.expectEqual(@as(f32, -3), parsed.preamp_db);
    try std.testing.expectEqualSlices(Filter, &.{
        .{ .kind = .low_shelf, .frequency_hz = 105, .gain_db = 3, .q = 0.71 },
        .{ .kind = .peak, .frequency_hz = 1000, .gain_db = -2, .q = 1.41 },
        .{ .kind = .peak, .frequency_hz = 3000, .gain_db = 2.5, .q = 2 },
        .{ .kind = .high_shelf, .frequency_hz = 10_000, .gain_db = -1.5, .q = 0.71 },
    }, parsed.filterList());

    var buffer: [2048]u8 = undefined;
    const text = try written(&buffer, parsed);
    try std.testing.expectEqualStrings(
        \\Preamp: -3 dB
        \\Filter 1: ON LSC Fc 105 Hz Gain 3 dB Q 0.71
        \\Filter 2: ON PK Fc 1000 Hz Gain -2 dB Q 1.41
        \\Filter 3: ON PK Fc 3000 Hz Gain 2.5 dB Q 2
        \\Filter 4: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71
        \\
    , text);
    try expectSameEqualizer(parsed, try parseEqualizerApo(text));

    const passes = try parseEqualizerApo(
        \\Filter 1: OFF LP Fc 18000 Hz Q 0.5
        \\Filter 2: ON HP Fc 25 Hz
        \\Filter 3: ON NO Fc 60 Hz Gain 9 dB Q 8
        \\Filter 4: ON PEQ Fc 2000 Hz Gain 0.1 dB Q 4.5
    );
    const passes_text = try written(&buffer, passes);
    try std.testing.expectEqualStrings(
        \\Preamp: 0 dB
        \\Filter 1: OFF LP Fc 18000 Hz Q 0.5
        \\Filter 2: ON HP Fc 25 Hz Q 0.707
        \\Filter 3: ON NO Fc 60 Hz Q 8
        \\Filter 4: ON PK Fc 2000 Hz Gain 0.1 dB Q 4.5
        \\
    , passes_text);
    try expectSameEqualizer(passes, try parseEqualizerApo(passes_text));
    try std.testing.expectEqual(@as(f32, 0), passes.filters[2].gain_db);
}

test "a BW Oct bandwidth becomes the equivalent Q" {
    const parsed = try parseEqualizerApo(
        \\Filter 1: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1
        \\Filter 2: ON PK Fc 1000 Hz Gain 3 dB BW Oct 2
        \\Filter 3: ON NO Fc 1000 Hz bw oct 0.5
    );
    try std.testing.expectApproxEqAbs(@as(f32, std.math.sqrt2), parsed.filters[0].q, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), parsed.filters[1].q, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.871), parsed.filters[2].q, 1e-5);
    var buffer: [512]u8 = undefined;
    try expectSameEqualizer(parsed, try parseEqualizerApo(try written(&buffer, parsed)));
    try std.testing.expectError(error.FilterQOutOfRange, parseEqualizerApo("Filter: ON PK Fc 1000 Hz BW Oct 0"));
    try std.testing.expectError(error.InvalidEqualizerApo, parseEqualizerApo("Filter: ON PK Fc 1000 Hz BW 1"));
    try std.testing.expectError(error.InvalidEqualizerApo, parseEqualizerApo("Filter: ON PK Fc 1000 Hz Q 1 BW Oct 1"));
}

test "plain LS and HS shelves import with a Q of 0.707" {
    const parsed = try parseEqualizerApo(
        \\Filter 1: ON LS Fc 100 Hz Gain 4 dB
        \\Filter 2: ON HS Fc 8000 Hz Gain -2 dB
        \\Filter 3: ON LSC Fc 100 Hz Gain 4 dB Q 1.2
    );
    try std.testing.expectEqualSlices(Filter, &.{
        .{ .kind = .low_shelf, .frequency_hz = 100, .gain_db = 4, .q = 0.707 },
        .{ .kind = .high_shelf, .frequency_hz = 8000, .gain_db = -2, .q = 0.707 },
        .{ .kind = .low_shelf, .frequency_hz = 100, .gain_db = 4, .q = 1.2 },
    }, parsed.filterList());
}

test "a filter switched OFF is kept, disabled, and written back OFF" {
    const parsed = try parseEqualizerApo(
        \\Preamp: -2 dB
        \\Filter 1: OFF PK Fc 1000 Hz Gain 6 dB Q 1
        \\Filter 2: ON PK Fc 2000 Hz Gain 2 dB Q 1
    );
    try std.testing.expectEqual(@as(u8, 2), parsed.count);
    try std.testing.expect(!parsed.filters[0].enabled);
    try std.testing.expect(parsed.filters[1].enabled);
    try std.testing.expectEqual(@as(f32, 6), parsed.filters[0].gain_db);
    try std.testing.expectEqual(@as(f32, -2), parsed.suggestedPreamp());
    var buffer: [512]u8 = undefined;
    const text = try written(&buffer, parsed);
    try std.testing.expect(std.mem.indexOf(u8, text, "Filter 1: OFF PK Fc 1000 Hz Gain 6 dB Q 1\n") != null);
}

test "CRLF line endings, comments, a byte order mark and spacing read like plain LF" {
    const crlf = try parseEqualizerApo(
        "\xEF\xBB\xBF# AutoEq export\r\n\r\nPreamp: -3 dB\r\n" ++
            "Filter 1: ON LSC Fc 105 Hz Gain 3.0 dB Q 0.71\r\n" ++
            "filter2 :  on  pk fc 1000 hz gain -2.0 db q 1.41\r\n" ++
            "\tFilter 3: ON PK Fc 3000 Hz Gain 2.5 dB Q 2.0   \r\n" ++
            "Filter 4: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71",
    );
    try expectSameEqualizer(try parseEqualizerApo(hd650_text), crlf);
    try std.testing.expectEqual(@as(f32, -5), (try parseEqualizerApo("Preamp: -2 dB\nPreamp: -3\n")).preamp_db);
    const empty = try parseEqualizerApo("# nothing\n\n");
    try std.testing.expectEqual(@as(u8, 0), empty.count);
    try std.testing.expect(empty.isIdentity());
}

test "an unsupported filter type is rejected as unsupported, not skipped" {
    for ([_][]const u8{
        "Filter 1: ON BP Fc 1000 Hz Q 1",
        "Filter 1: ON LPQ Fc 1000 Hz Q 1",
        "Filter 1: ON AP Fc 1000 Hz Q 1",
        "Filter 1: ON LS 6dB Fc 100 Hz Gain 3 dB",
        "Filter 1: ON HS 12dB Fc 8000 Hz Gain 3 dB",
        "Preamp: -1 dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1\nFilter 2: OFF IIR Fc 100 Hz",
    }) |text| try std.testing.expectError(error.UnsupportedFilterType, parseEqualizerApo(text));
}

test "more than sixteen filters are rejected" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (1..dsp.max_parametric_filters + 1) |position|
        try writer.print("Filter {d}: ON PK Fc {d} Hz Gain 1 dB Q 1\n", .{ position, position * 100 });
    const sixteen = try parseEqualizerApo(writer.buffered());
    try std.testing.expectEqual(@as(u8, dsp.max_parametric_filters), sixteen.count);
    try writer.writeAll("Filter 17: OFF PK Fc 1700 Hz Gain 1 dB Q 1\n");
    try std.testing.expectError(error.TooManyFilters, parseEqualizerApo(writer.buffered()));
}

test "malformed lines and out-of-range values are rejected" {
    const Case = struct { text: []const u8, err: anyerror };
    for ([_]Case{
        .{ .text = "Device: all", .err = error.InvalidEqualizerApo },
        .{ .text = "Channel: L\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1 ON PK Fc 1000 Hz Gain 3 dB Q 1", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1: ON PK Gain 3 dB Q 1", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1: PK Fc 1000 Hz Gain 3 dB Q 1", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1: ON", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1: ON PK Fc abc Hz", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1: ON PK Fc 1000 Hz Fc 2000 Hz", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1 Slope 2", .err = error.InvalidEqualizerApo },
        .{ .text = "Filter A: ON PK Fc 1000 Hz", .err = error.InvalidEqualizerApo },
        .{ .text = "Preamp: -3 dB extra", .err = error.InvalidEqualizerApo },
        .{ .text = "Preamp:", .err = error.InvalidEqualizerApo },
        .{ .text = "Preamp: 7 dB", .err = error.ParametricPreampOutOfRange },
        .{ .text = "Preamp: nan dB", .err = error.ParametricPreampOutOfRange },
        .{ .text = "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 0", .err = error.FilterQOutOfRange },
        .{ .text = "Filter 1: ON LSC Fc 100 Hz Gain 3 dB Q 3", .err = error.FilterQOutOfRange },
        .{ .text = "Filter 1: ON PK Fc 1000 Hz Gain 25 dB Q 1", .err = error.FilterGainOutOfRange },
        .{ .text = "Filter 1: ON PK Fc inf Hz Gain 3 dB Q 1", .err = error.FilterFrequencyOutOfRange },
        .{ .text = "Filter 1: ON PK Fc 22000 Hz Gain 3 dB Q 1", .err = error.FilterFrequencyOutOfRange },
    }) |case| try std.testing.expectError(case.err, parseEqualizerApo(case.text));
}

test "the sample correction's response at 1 kHz matches the hand-computed cascade" {
    const text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "fixtures/eq/hd650.txt",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(text);
    const parsed = try parseEqualizerApo(text);
    try expectSameEqualizer(try parseEqualizerApo(hd650_text), parsed);
    var gain_db: [1]f32 = undefined;
    parsed.response(44_100, &.{1000}, &gain_db);
    try std.testing.expectApproxEqAbs(@as(f32, -4.9167), gain_db[0], 0.05);
}
