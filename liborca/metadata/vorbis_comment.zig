const std = @import("std");
const mutation = @import("mutation.zig");

const vendor = "Orca";

pub fn rewrite(
    allocator: std.mem.Allocator,
    payload: []const u8,
    changes: []const mutation.Change,
) ![]u8 {
    try validateChanges(changes);
    var cursor: usize = 0;
    const vendor_text = try takeString(payload, &cursor);
    const count = try takeU32(payload, &cursor);

    for (changes) |change| {
        if (change.before) |expected| {
            var found = false;
            var check_cursor = cursor;
            for (0..count) |_| {
                const entry = try takeString(payload, &check_cursor);
                const parsed = try parseEntry(entry);
                if (fieldMatches(change.field, parsed.key) and
                    std.mem.eql(u8, expected, parsed.value))
                {
                    found = true;
                    break;
                }
            }
            if (!found) return error.MetadataPreconditionChanged;
        }
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendString(&output, allocator, vendor_text);
    const count_offset = output.items.len;
    try appendU32(&output, allocator, 0);
    var output_count: u32 = 0;
    for (0..count) |_| {
        const entry = try takeString(payload, &cursor);
        const parsed = try parseEntry(entry);
        var replaced = false;
        for (changes) |change| {
            if (fieldMatches(change.field, parsed.key)) {
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try appendString(&output, allocator, entry);
            output_count = try std.math.add(u32, output_count, 1);
        }
    }
    if (cursor != payload.len) return error.InvalidVorbisComment;
    for (changes) |change| if (change.after) |value| {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidMetadataText;
        const key = fieldKey(change.field);
        const length = try std.math.add(usize, key.len + 1, value.len);
        try appendU32(&output, allocator, std.math.cast(u32, length) orelse
            return error.MetadataValueTooLong);
        try output.appendSlice(allocator, key);
        try output.append(allocator, '=');
        try output.appendSlice(allocator, value);
        output_count = try std.math.add(u32, output_count, 1);
    };
    std.mem.writeInt(u32, output.items[count_offset..][0..4], output_count, .little);
    return output.toOwnedSlice(allocator);
}

pub fn create(
    allocator: std.mem.Allocator,
    changes: []const mutation.Change,
) ![]u8 {
    for (changes) |change| if (change.before != null)
        return error.MetadataPreconditionChanged;
    var base: [12]u8 = undefined;
    std.mem.writeInt(u32, base[0..4], vendor.len, .little);
    @memcpy(base[4 .. 4 + vendor.len], vendor);
    std.mem.writeInt(u32, base[8..12], 0, .little);
    return rewrite(allocator, &base, changes);
}

const Entry = struct { key: []const u8, value: []const u8 };

fn parseEntry(entry: []const u8) !Entry {
    const delimiter = std.mem.indexOfScalar(u8, entry, '=') orelse
        return error.InvalidVorbisComment;
    const key = entry[0..delimiter];
    if (key.len == 0) return error.InvalidVorbisComment;
    for (key) |byte| if (byte < 0x20 or byte > 0x7d or byte == '=')
        return error.InvalidVorbisComment;
    const value = entry[delimiter + 1 ..];
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidVorbisComment;
    return .{ .key = key, .value = value };
}

fn validateChanges(changes: []const mutation.Change) !void {
    for (changes, 0..) |change, index| {
        for (changes[0..index]) |previous| if (previous.field == change.field)
            return error.DuplicateMetadataFieldChange;
    }
}

fn fieldMatches(field: mutation.Field, key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(fieldKey(field), key);
}

fn fieldKey(field: mutation.Field) []const u8 {
    return switch (field) {
        .title => "TITLE",
        .artist => "ARTIST",
        .album => "ALBUM",
        .track_number => "TRACKNUMBER",
    };
}

fn takeString(payload: []const u8, cursor: *usize) ![]const u8 {
    const length = try takeU32(payload, cursor);
    const end = std.math.add(usize, cursor.*, length) catch
        return error.InvalidVorbisComment;
    if (end > payload.len) return error.InvalidVorbisComment;
    defer cursor.* = end;
    return payload[cursor.*..end];
}

fn takeU32(payload: []const u8, cursor: *usize) !u32 {
    const end = std.math.add(usize, cursor.*, 4) catch
        return error.InvalidVorbisComment;
    if (end > payload.len) return error.InvalidVorbisComment;
    defer cursor.* = end;
    return std.mem.readInt(u32, payload[cursor.*..end][0..4], .little);
}

fn appendString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try appendU32(list, allocator, std.math.cast(u32, text.len) orelse
        return error.MetadataValueTooLong);
    try list.appendSlice(allocator, text);
}

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

test "Vorbis comment rewrite preserves unknown entries and supports UTF-8" {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try appendString(&payload, std.testing.allocator, "Generated");
    try appendU32(&payload, std.testing.allocator, 3);
    try appendString(&payload, std.testing.allocator, "TITLE=Old title");
    try appendString(&payload, std.testing.allocator, "CUSTOM=preserved");
    try appendString(&payload, std.testing.allocator, "ARTIST=Old artist");
    const rewritten = try rewrite(std.testing.allocator, payload.items, &.{
        .{ .field = .title, .before = "Old title", .after = "Néw title" },
        .{ .field = .artist, .before = "Old artist", .after = null },
    });
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "TITLE=Néw title") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "CUSTOM=preserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ARTIST=") == null);
}

test "Vorbis comment rewrite validates preconditions and framing" {
    try std.testing.expectError(
        error.InvalidVorbisComment,
        rewrite(std.testing.allocator, "short", &.{}),
    );
    const created = try create(std.testing.allocator, &.{.{
        .field = .album,
        .before = null,
        .after = "Generated album",
    }});
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "ALBUM=Generated album") != null);
}
