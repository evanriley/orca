//! iTunes-style metadata in MP4/M4A files: the `moov/udta/meta/ilst` atoms.
//!
//! Atom codes, the `----` freeform convention, `gnre`'s ID3v1 numbering and
//! `trkn`'s binary packing stop here; callers see only canonical tags.

const std = @import("std");
const model = @import("model.zig");
const id3v1 = @import("id3v1.zig");
const source = @import("../storage/source.zig");
const bmff = @import("../storage/iso_bmff.zig");

/// `data` atom type indicators, from Apple's well-known types.
const DataType = enum(u24) {
    binary = 0,
    utf8 = 1,
    utf16 = 2,
    jpeg = 13,
    png = 14,
    signed_integer = 21,
    unsigned_integer = 22,
    bmp = 27,
    _,
};

const Value = struct {
    kind: DataType,
    bytes: []const u8,
};

/// Canonical tags from the item list, or null when the file carries none.
/// Text is allocated from `allocator`; callers pass an arena.
pub fn read(allocator: std.mem.Allocator, readable: source.ReadableSource) !?model.ObservedTags {
    const movie = try bmff.readMovie(allocator, readable);
    defer allocator.free(movie);
    const items = try itemList(movie) orelse return null;

    var tags: model.ObservedTags = .{};
    var genres: std.ArrayList([]const u8) = .empty;
    defer genres.deinit(allocator);
    var any = false;
    var boxes = bmff.Iterator.init(items);
    while (try boxes.next()) |item| {
        if (item.is("covr")) {
            const value = try firstValue(item.body) orelse continue;
            if (tags.artwork == null) tags.artwork = .{
                .mime_type = model.sniffImageMimeType(value.bytes) orelse "",
                .byte_size = value.bytes.len,
                .kind = .front_cover,
            };
            any = true;
            continue;
        }
        if (item.is("----")) {
            any = try assignFreeform(allocator, item.body, &tags) or any;
            continue;
        }
        const value = try firstValue(item.body) orelse continue;
        any = try assign(allocator, item.kind, value, &tags, &genres) or any;
    }
    if (!any) return null;
    tags.genres = try genres.toOwnedSlice(allocator);
    return tags;
}

/// The cover image, or null when the file has none.
pub fn readPicture(allocator: std.mem.Allocator, readable: source.ReadableSource) !?model.EmbeddedImage {
    const movie = try bmff.readMovie(allocator, readable);
    defer allocator.free(movie);
    const items = try itemList(movie) orelse return null;
    const cover = try bmff.Iterator.find(items, "covr") orelse return null;
    const value = try firstValue(cover.body) orelse return null;
    if (value.bytes.len > model.max_image_bytes) return error.ArtworkTooLarge;
    const bytes = try allocator.dupe(u8, value.bytes);
    errdefer allocator.free(bytes);
    return try model.adoptImage(allocator, bytes, .front_cover);
}

fn itemList(movie: []const u8) !?[]const u8 {
    const meta = try bmff.descend(movie, &.{ "udta", "meta" }) orelse return null;
    // `meta` is a full box: version and flags precede its children.
    if (meta.body.len < 4) return error.InvalidMp4;
    const list = try bmff.Iterator.find(meta.body[4..], "ilst") orelse return null;
    return list.body;
}

/// The first `data` atom of an item: type(4), locale(4), payload.
fn firstValue(item: []const u8) !?Value {
    const data = try bmff.Iterator.find(item, "data") orelse return null;
    if (data.body.len < 8) return error.InvalidMp4;
    return .{
        .kind = @enumFromInt(std.mem.readInt(u24, data.body[1..4], .big)),
        .bytes = data.body[8..],
    };
}

fn assign(
    allocator: std.mem.Allocator,
    code: [4]u8,
    value: Value,
    tags: *model.ObservedTags,
    genres: *std.ArrayList([]const u8),
) !bool {
    const Text = struct { code: *const [4]u8, field: []const u8 };
    const text_items = [_]Text{
        .{ .code = "\xa9nam", .field = "title" },
        .{ .code = "\xa9ART", .field = "artist" },
        .{ .code = "aART", .field = "album_artist" },
        .{ .code = "\xa9alb", .field = "album" },
        .{ .code = "\xa9wrt", .field = "composer" },
    };
    inline for (text_items) |entry| {
        if (std.mem.eql(u8, &code, entry.code)) {
            return setText(allocator, &@field(tags, entry.field), text(value) orelse return false);
        }
    }
    if (std.mem.eql(u8, &code, "\xa9day")) {
        const date = text(value) orelse return false;
        // iTunes writes a full timestamp; the canonical date stops at the day.
        const day = date[0 .. std.mem.indexOfScalar(u8, date, 'T') orelse date.len];
        return setText(allocator, &tags.date, day);
    }
    if (std.mem.eql(u8, &code, "\xa9gen")) {
        const name = text(value) orelse return false;
        try genres.append(allocator, try allocator.dupe(u8, name));
        return true;
    }
    if (std.mem.eql(u8, &code, "gnre")) {
        // An ID3v1 genre number plus one.
        if (value.bytes.len < 2) return false;
        const number = std.mem.readInt(u16, value.bytes[0..2], .big);
        if (number == 0 or number > 256) return false;
        const name = id3v1.genreName(@intCast(number - 1)) orelse return false;
        try genres.append(allocator, try allocator.dupe(u8, name));
        return true;
    }
    if (std.mem.eql(u8, &code, "trkn")) return setPair(value, &tags.track_number, &tags.track_total);
    if (std.mem.eql(u8, &code, "disk")) return setPair(value, &tags.disc_number, &tags.disc_total);
    if (std.mem.eql(u8, &code, "cpil")) {
        if (value.bytes.len == 0 or tags.compilation != null) return false;
        tags.compilation = value.bytes[0] != 0;
        return true;
    }
    return false;
}

/// `----` items: a reverse-DNS `mean`, a `name`, then the value. Taggers such
/// as Picard use them for identifiers that have no four-character code.
fn assignFreeform(allocator: std.mem.Allocator, item: []const u8, tags: *model.ObservedTags) !bool {
    const name_box = try bmff.Iterator.find(item, "name") orelse return false;
    if (name_box.body.len < 4) return error.InvalidMp4;
    const name = name_box.body[4..];
    const value = try firstValue(item) orelse return false;
    const string = text(value) orelse return false;

    const Freeform = struct { names: []const []const u8, field: []const u8 };
    const freeform = [_]Freeform{
        .{ .names = &.{"MusicBrainz Track Id"}, .field = "musicbrainz_recording_id" },
        .{ .names = &.{"MusicBrainz Album Id"}, .field = "musicbrainz_release_id" },
        .{ .names = &.{"MusicBrainz Release Group Id"}, .field = "musicbrainz_release_group_id" },
        .{ .names = &.{"MusicBrainz Release Track Id"}, .field = "musicbrainz_release_track_id" },
        .{ .names = &.{"MusicBrainz Artist Id"}, .field = "musicbrainz_artist_id" },
        .{ .names = &.{"MusicBrainz Album Artist Id"}, .field = "musicbrainz_album_artist_id" },
        .{ .names = &.{"MusicBrainz Album Release Country"}, .field = "release_country" },
        .{ .names = &.{"MusicBrainz Album Type"}, .field = "release_type" },
        .{ .names = &.{"MusicBrainz Album Status"}, .field = "release_status" },
        .{ .names = &.{"ISRC"}, .field = "isrc" },
        .{ .names = &.{ "LABEL", "publisher" }, .field = "label" },
        .{ .names = &.{"MEDIA"}, .field = "media" },
        .{ .names = &.{ "originaldate", "ORIGINAL YEAR", "originalyear" }, .field = "original_date" },
    };
    inline for (freeform) |entry| {
        for (entry.names) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate))
                return setText(allocator, &@field(tags, entry.field), string);
        }
    }
    return false;
}

fn text(value: Value) ?[]const u8 {
    if (value.kind != .utf8) return null;
    const trimmed = std.mem.trim(u8, value.bytes, " \t\r\n\x00");
    if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) return null;
    return trimmed;
}

/// First occurrence wins, as for every other container.
fn setText(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) !bool {
    if (field.* != null) return false;
    field.* = try allocator.dupe(u8, value);
    return true;
}

/// `trkn` and `disk`: reserved(2), number(2), total(2).
fn setPair(value: Value, number: *?u32, total: *?u32) bool {
    if (value.bytes.len < 6 or number.* != null) return false;
    const n = std.mem.readInt(u16, value.bytes[2..4], .big);
    const t = std.mem.readInt(u16, value.bytes[4..6], .big);
    if (n != 0) number.* = n;
    if (t != 0) total.* = t;
    return n != 0 or t != 0;
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) !?model.ObservedTags {
    var file = try source.LocalFileSource.open(std.testing.io, path);
    defer file.close();
    return read(allocator, file.readable());
}

test "iTunes atoms of an AAC file yield canonical tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/tagged-reference-aac.m4a")).?;
    try std.testing.expectEqualStrings("AAC Reference", tags.title.?);
    try std.testing.expectEqualStrings("Orca Fixtures", tags.artist.?);
    try std.testing.expectEqualStrings("Orca Fixtures", tags.album_artist.?);
    try std.testing.expectEqualStrings("Codec References", tags.album.?);
    try std.testing.expectEqualStrings("2026", tags.date.?);
    try std.testing.expectEqual(@as(?u32, 2), tags.track_number);
    try std.testing.expectEqual(@as(?u32, 5), tags.track_total);
    try std.testing.expectEqual(@as(?u32, 1), tags.disc_number);
    try std.testing.expectEqual(@as(?u32, 2), tags.disc_total);
    try std.testing.expectEqual(@as(usize, 1), tags.genres.len);
    try std.testing.expectEqualStrings("Test Tone", tags.genres[0]);
}

test "iTunes atoms of an ALAC file carry the tags of the FLAC it came from" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/tagged-reference-alac.m4a")).?;
    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.track_number);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_total);
}

test "a cover atom is observed and read back as the same image" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/covered-reference.m4a")).?;
    const artwork = tags.artwork.?;
    try std.testing.expectEqualStrings("image/png", artwork.mime_type);
    try std.testing.expectEqual(@as(u64, 217), artwork.byte_size);

    var file = try source.LocalFileSource.open(std.testing.io, "fixtures/audio/covered-reference.m4a");
    defer file.close();
    const image = (try readPicture(std.testing.allocator, file.readable())).?;
    defer image.deinit();
    try std.testing.expectEqual(@as(usize, 217), image.bytes.len);
    try std.testing.expectEqualStrings("image/png", image.mime_type);
}

test "a genre stored as an ID3v1 number is named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var genres: std.ArrayList([]const u8) = .empty;
    var tags: model.ObservedTags = .{};
    try std.testing.expect(try assign(arena.allocator(), "gnre".*, .{ .kind = .binary, .bytes = "\x00\x0a" }, &tags, &genres));
    try std.testing.expectEqualStrings("Metal", genres.items[0]);
}
