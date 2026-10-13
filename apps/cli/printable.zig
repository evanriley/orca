const std = @import("std");

const Writer = std.Io.Writer;

pub fn printable(text: []const u8) std.fmt.Alt([]const u8, writeLine) {
    return .{ .data = text };
}

pub fn printableText(text: []const u8) std.fmt.Alt([]const u8, writeText) {
    return .{ .data = text };
}

fn writeLine(text: []const u8, writer: *Writer) Writer.Error!void {
    try writeEscaped(text, writer, false);
}

fn writeText(text: []const u8, writer: *Writer) Writer.Error!void {
    try writeEscaped(text, writer, true);
}

fn writeEscaped(text: []const u8, writer: *Writer, keep_layout: bool) Writer.Error!void {
    var clean_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = safeLength(text[index..], keep_layout);
        if (length != 0) {
            index += length;
            continue;
        }
        try writer.writeAll(text[clean_start..index]);
        try writer.print("\\x{X:0>2}", .{text[index]});
        index += 1;
        clean_start = index;
    }
    try writer.writeAll(text[clean_start..]);
}

fn safeLength(rest: []const u8, keep_layout: bool) usize {
    const first = rest[0];
    if (first == '\n' or first == '\t') return if (keep_layout) 1 else 0;
    if (first < 0x20 or first == 0x7F) return 0;
    if (first < 0x80) return 1;
    const length = std.unicode.utf8ByteSequenceLength(first) catch return 0;
    if (length > rest.len) return 0;
    const code_point = std.unicode.utf8Decode(rest[0..length]) catch return 0;
    if (code_point >= 0x80 and code_point <= 0x9F) return 0;
    return length;
}

fn expectEscaped(expected: []const u8, text: []const u8, keep_layout: bool) !void {
    var buffer: [128]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try writeEscaped(text, &writer, keep_layout);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "printable escapes an operating-system command sequence" {
    try expectEscaped("\\x1B]0;x\\x07", "\x1b]0;x\x07", false);
}

test "printable escapes DEL, NUL, newline and tab" {
    try expectEscaped("a\\x7F\\x00\\x0A\\x09b", "a\x7f\x00\n\tb", false);
}

test "printable escapes a C1 control in UTF-8 form and keeps its neighbours" {
    try expectEscaped("\\xC2\\x9B31m\xc2\xa0", "\xc2\x9b" ++ "31m\xc2\xa0", false);
}

test "printable escapes invalid and truncated UTF-8 byte by byte" {
    try expectEscaped("\\xFF\\xC3", "\xff\xc3", false);
    try expectEscaped("\\xE2\\x82x", "\xe2\x82x", false);
}

test "printable passes valid non-ASCII text unchanged" {
    try expectEscaped("Björk 音楽 🎵", "Björk 音楽 🎵", false);
}

test "printableText keeps newline and tab and still escapes other controls" {
    try expectEscaped("one\n\ttwo\\x1B[2J", "one\n\ttwo\x1b[2J", true);
}
