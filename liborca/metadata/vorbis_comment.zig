const std = @import("std");
const lrc = @import("lrc.zig");
const lyrics = @import("lyrics.zig");
const model = @import("model.zig");
const mutation = @import("mutation.zig");
const source = @import("../storage/source.zig");

const vendor = "Orca";

/// A FLAC metadata block length is a 24-bit field, so no honest comment block
/// can exceed this and a larger claim is a corrupt or hostile stream.
const max_metadata_block_size: usize = (1 << 24) - 1;
const max_picture_text_size: usize = 4096;

pub const ReadError = error{
    InvalidFlacStream,
    InvalidVorbisComment,
    TruncatedFlacStream,
};

/// Read canonical tags from a FLAC stream's METADATA_BLOCK_VORBIS_COMMENT.
///
/// Returns null when the stream carries no comment block at all. Text allocated
/// from `allocator` lives until the caller frees it; callers are expected to
/// pass an arena, which is what `library/tag_reader.zig` does.
pub fn read(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
) !?model.ObservedTags {
    var tags: model.ObservedTags = .{};
    var genres: std.ArrayList([]const u8) = .empty;
    defer genres.deinit(allocator);
    var found_comment = false;
    var blocks = (try BlockIterator.init(readable)) orelse return null;
    while (try blocks.next()) |block| {
        switch (block.block_type) {
            4 => {
                if (found_comment) return error.InvalidVorbisComment;
                found_comment = true;
                const payload = try allocator.alloc(u8, block.length);
                defer allocator.free(payload);
                if (try readExact(readable, block.offset, payload) != block.length)
                    return error.TruncatedFlacStream;
                try parseInto(allocator, payload, &tags, &genres);
            },
            6 => try readPictureHeader(allocator, readable, block, &tags),
            else => {},
        }
    }

    if (!found_comment and tags.artwork == null) return null;
    tags.genres = try genres.toOwnedSlice(allocator);
    return tags;
}

/// Extract the cover image a FLAC `PICTURE` block carries, or null when the
/// stream has none Orca can use.
///
/// Same preference as `read` records: the first front cover wins, and with no
/// front cover the first usable picture is taken, so the bytes handed back are
/// the picture the scan said was there.
pub fn readPicture(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
) !?model.EmbeddedImage {
    var blocks = (try BlockIterator.init(readable)) orelse return null;
    var chosen: ?PictureBlock = null;
    while (try blocks.next()) |block| {
        if (block.block_type != 6) continue;
        const picture = (try readPictureBlock(readable, block)) orelse continue;
        if (chosen) |existing| {
            if (existing.kind == .front_cover or picture.kind != .front_cover) continue;
        }
        chosen = picture;
        if (picture.kind == .front_cover) break;
    }

    const picture = chosen orelse return null;
    // Bounded before the allocation, and against a length the block declares
    // rather than one that has already been believed.
    if (picture.data_length > model.max_image_bytes) return error.ArtworkTooLarge;
    const bytes = try allocator.alloc(u8, picture.data_length);
    errdefer allocator.free(bytes);
    if (try readExact(readable, picture.data_offset, bytes) != bytes.len)
        return error.TruncatedArtwork;
    return try model.adoptImage(allocator, bytes, picture.kind);
}

/// The lyrics in a FLAC stream's comment block, as `lyricsFromComments`
/// finds them. Lines are allocated from `output`.
pub fn readLyrics(
    allocator: std.mem.Allocator,
    output: std.mem.Allocator,
    readable: source.ReadableSource,
) !?lyrics.Content {
    var blocks = (try BlockIterator.init(readable)) orelse return null;
    while (try blocks.next()) |block| {
        if (block.block_type != 4) continue;
        const payload = try allocator.alloc(u8, block.length);
        defer allocator.free(payload);
        if (try readExact(readable, block.offset, payload) != block.length)
            return error.TruncatedFlacStream;
        return lyricsFromComments(output, payload);
    }
    return null;
}

/// The first `LYRICS` comment with text, else the first `UNSYNCEDLYRICS`
/// one, parsed as LRC. Keys match in any case.
pub fn lyricsFromComments(output: std.mem.Allocator, payload: []const u8) !?lyrics.Content {
    for ([_][]const u8{ "LYRICS", "UNSYNCEDLYRICS" }) |key| {
        var entries = try Entries.init(payload);
        while (try entries.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key, key)) continue;
            if (try lrc.parse(output, entry.value)) |content| return content;
        }
    }
    return null;
}

/// The `KEY=value` entries of a bare Vorbis comment payload, in order.
pub const Entries = struct {
    payload: []const u8,
    cursor: usize,
    remaining: u32,

    pub fn init(payload: []const u8) ReadError!Entries {
        var cursor: usize = 0;
        _ = try takeString(payload, &cursor);
        const count = try takeU32(payload, &cursor);
        return .{ .payload = payload, .cursor = cursor, .remaining = count };
    }

    pub fn next(self: *Entries) ReadError!?Entry {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try parseEntry(try takeString(self.payload, &self.cursor));
    }
};

/// A `PICTURE` block held in memory rather than in a FLAC stream: Ogg streams
/// carry one base64-encoded in a `METADATA_BLOCK_PICTURE` comment. Parsed by
/// the same code as a FLAC block, so the two cannot disagree about layout.
pub const PictureView = struct {
    kind: model.ArtworkKind,
    mime_type: []const u8,
    data: []const u8,
};

pub fn pictureFromBlock(block_bytes: []const u8) ?PictureView {
    var memory = source.MemorySource{ .bytes = block_bytes };
    const picture = (readPictureBlock(memory.readable(), .{
        .block_type = 6,
        .offset = 0,
        .length = block_bytes.len,
    }) catch return null) orelse return null;
    const mime_start: usize = @intCast(picture.mime_offset);
    const data_start: usize = @intCast(picture.data_offset);
    return .{
        .kind = picture.kind,
        .mime_type = block_bytes[mime_start..][0..picture.mime_length],
        .data = block_bytes[data_start..][0..picture.data_length],
    };
}

/// One FLAC metadata block: what it is, and where its body lives in the file.
const MetadataBlock = struct {
    block_type: u8,
    offset: u64,
    length: usize,
};

/// Walks a FLAC stream's metadata blocks.
///
/// Extracted so that reading comments and reading a cover image are the same
/// walk. A stream that never sets the last-block flag is refused after a
/// bounded number of blocks rather than followed for ever.
const BlockIterator = struct {
    readable: source.ReadableSource,
    offset: u64 = 4,
    finished: bool = false,
    remaining: usize = 4096,

    /// Null when the source is too short to be a FLAC stream at all, which
    /// callers report as "no tags" rather than as a failure.
    fn init(readable: source.ReadableSource) !?BlockIterator {
        var magic: [4]u8 = undefined;
        if (try readExact(readable, 0, &magic) != magic.len) return null;
        if (!std.mem.eql(u8, &magic, "fLaC")) return error.InvalidFlacStream;
        return .{ .readable = readable };
    }

    fn next(self: *BlockIterator) !?MetadataBlock {
        if (self.finished) return null;
        if (self.remaining == 0) return error.InvalidFlacStream;
        self.remaining -= 1;

        var header: [4]u8 = undefined;
        if (try readExact(self.readable, self.offset, &header) != header.len)
            return error.TruncatedFlacStream;
        self.offset += header.len;
        self.finished = header[0] & 0x80 != 0;
        const length: usize = (@as(usize, header[1]) << 16) |
            (@as(usize, header[2]) << 8) | @as(usize, header[3]);
        if (length > max_metadata_block_size) return error.InvalidFlacStream;
        if (self.offset + length > self.readable.size()) return error.TruncatedFlacStream;
        const block: MetadataBlock = .{
            .block_type = header[0] & 0x7f,
            .offset = self.offset,
            .length = length,
        };
        self.offset += length;
        return block;
    }
};

/// Where a `PICTURE` block's declared type and payload live in the file.
const PictureBlock = struct {
    kind: model.ArtworkKind,
    mime_offset: u64,
    mime_length: u32,
    data_offset: u64,
    data_length: u32,
};

/// Parse a `PICTURE` block's fixed header.
///
/// The one definition of the block's layout: an observation and a fetch must
/// not be able to disagree about which bytes are the image. Null for a block
/// whose fields do not fit inside it, or that declares no payload — malformed
/// metadata is normal in a real library and is skipped, not fatal.
fn readPictureBlock(
    readable: source.ReadableSource,
    block: MetadataBlock,
) !?PictureBlock {
    if (block.length < 32) return null;
    var head: [8]u8 = undefined;
    if (try readExact(readable, block.offset, &head) != head.len)
        return error.TruncatedFlacStream;
    const picture_type = std.mem.readInt(u32, head[0..4], .big);
    const mime_length = std.mem.readInt(u32, head[4..8], .big);
    if (mime_length > max_picture_text_size) return null;
    if (8 + @as(u64, mime_length) + 24 > block.length) return null;

    var description_length: [4]u8 = undefined;
    if (try readExact(readable, block.offset + 8 + mime_length, &description_length) != 4)
        return error.TruncatedFlacStream;
    const description = std.mem.readInt(u32, &description_length, .big);
    if (description > max_picture_text_size) return null;
    // 4 description-length bytes, the description, then width, height, colour
    // depth and indexed-colour count — four more 32-bit fields.
    const length_offset = @as(u64, 8) + mime_length + 4 + description + 16;
    if (length_offset + 4 > block.length) return null;

    var data_length: [4]u8 = undefined;
    if (try readExact(readable, block.offset + length_offset, &data_length) != 4)
        return error.TruncatedFlacStream;
    const declared = std.mem.readInt(u32, &data_length, .big);
    if (declared == 0) return null;
    // The block must actually contain the payload it claims.
    if (length_offset + 4 + @as(u64, declared) > block.length) return null;
    return .{
        .kind = artworkKind(picture_type),
        .mime_offset = block.offset + 8,
        .mime_length = mime_length,
        .data_offset = block.offset + length_offset + 4,
        .data_length = declared,
    };
}

/// Parse a bare Vorbis comment payload — vendor string, count, `KEY=value`
/// entries — into canonical tags. Shared by FLAC and, later, Ogg.
pub fn parse(allocator: std.mem.Allocator, payload: []const u8) !model.ObservedTags {
    var tags: model.ObservedTags = .{};
    var genres: std.ArrayList([]const u8) = .empty;
    defer genres.deinit(allocator);
    try parseInto(allocator, payload, &tags, &genres);
    tags.genres = try genres.toOwnedSlice(allocator);
    return tags;
}

fn parseInto(
    allocator: std.mem.Allocator,
    payload: []const u8,
    tags: *model.ObservedTags,
    genres: *std.ArrayList([]const u8),
) !void {
    var cursor: usize = 0;
    _ = try takeString(payload, &cursor);
    const count = try takeU32(payload, &cursor);
    for (0..count) |_| {
        const entry = try takeString(payload, &cursor);
        const parsed = try parseEntry(entry);
        const value = std.mem.trim(u8, parsed.value, " \t\r\n");
        if (value.len == 0) continue;
        try assign(allocator, parsed.key, value, tags, genres);
    }
}

/// Key spellings, alias sets, and `n/total` packing stop here. Real libraries
/// mix cases within one file and disagree about total-count spellings, so both
/// conventions are accepted and matching is case-insensitive per the spec.
fn assign(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    tags: *model.ObservedTags,
    genres: *std.ArrayList([]const u8),
) !void {
    if (matches(key, &.{"GENRE"})) {
        try genres.append(allocator, try allocator.dupe(u8, value));
        return;
    }
    if (matches(key, &.{"TITLE"})) return setText(allocator, &tags.title, value);
    if (matches(key, &.{"ARTIST"})) return setText(allocator, &tags.artist, value);
    if (matches(key, &.{"ALBUM"})) return setText(allocator, &tags.album, value);
    if (matches(key, &.{ "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST" }))
        return setText(allocator, &tags.album_artist, value);
    if (matches(key, &.{"COMPOSER"})) return setText(allocator, &tags.composer, value);
    if (matches(key, &.{"TRACKNUMBER"})) return setPair(
        value,
        &tags.track_number,
        &tags.track_total,
    );
    if (matches(key, &.{ "TRACKTOTAL", "TOTALTRACKS" }))
        return setNumber(value, &tags.track_total);
    if (matches(key, &.{"DISCNUMBER"})) return setPair(
        value,
        &tags.disc_number,
        &tags.disc_total,
    );
    if (matches(key, &.{ "DISCTOTAL", "TOTALDISCS" }))
        return setNumber(value, &tags.disc_total);
    if (matches(key, &.{ "DATE", "YEAR" })) return setText(allocator, &tags.date, value);
    if (matches(key, &.{ "ORIGINALDATE", "ORIGINALYEAR" }))
        return setText(allocator, &tags.original_date, value);
    if (matches(key, &.{"COMPILATION"})) {
        if (tags.compilation == null) tags.compilation = isTruthy(value);
        return;
    }
    if (matches(key, &.{"ITUNESADVISORY"})) {
        if (tags.explicit == null) tags.explicit = model.Explicit.fromAdvisoryText(value);
        return;
    }
    if (matches(key, &.{ "LABEL", "ORGANIZATION" }))
        return setText(allocator, &tags.label, value);
    if (matches(key, &.{"MEDIA"})) return setText(allocator, &tags.media, value);
    if (matches(key, &.{"ISRC"})) return setText(allocator, &tags.isrc, value);
    if (matches(key, &.{ "RELEASECOUNTRY", "MUSICBRAINZ_ALBUMCOUNTRY" }))
        return setText(allocator, &tags.release_country, value);
    if (matches(key, &.{ "RELEASETYPE", "MUSICBRAINZ_ALBUMTYPE" }))
        return setText(allocator, &tags.release_type, value);
    if (matches(key, &.{ "RELEASESTATUS", "MUSICBRAINZ_ALBUMSTATUS" }))
        return setText(allocator, &tags.release_status, value);
    if (matches(key, &.{"MUSICBRAINZ_TRACKID"}))
        return setText(allocator, &tags.musicbrainz_recording_id, value);
    if (matches(key, &.{"MUSICBRAINZ_ALBUMID"}))
        return setText(allocator, &tags.musicbrainz_release_id, value);
    if (matches(key, &.{"MUSICBRAINZ_RELEASEGROUPID"}))
        return setText(allocator, &tags.musicbrainz_release_group_id, value);
    if (matches(key, &.{"MUSICBRAINZ_RELEASETRACKID"}))
        return setText(allocator, &tags.musicbrainz_release_track_id, value);
    if (matches(key, &.{"MUSICBRAINZ_ARTISTID"}))
        return setText(allocator, &tags.musicbrainz_artist_id, value);
    if (matches(key, &.{"MUSICBRAINZ_ALBUMARTISTID"}))
        return setText(allocator, &tags.musicbrainz_album_artist_id, value);
}

fn matches(key: []const u8, spellings: []const []const u8) bool {
    for (spellings) |spelling| if (std.ascii.eqlIgnoreCase(key, spelling)) return true;
    return false;
}

/// First occurrence wins for single-valued fields: repeated keys are legal in
/// Vorbis comments, and a later duplicate must never silently overwrite.
fn setText(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) !void {
    if (field.* != null) return;
    field.* = try allocator.dupe(u8, value);
}

fn setNumber(value: []const u8, field: *?u32) void {
    if (field.* != null) return;
    field.* = parseNumber(value);
}

fn setPair(value: []const u8, number: *?u32, total: *?u32) void {
    if (std.mem.indexOfScalar(u8, value, '/')) |split| {
        setNumber(value[0..split], number);
        setNumber(value[split + 1 ..], total);
        return;
    }
    setNumber(value, number);
}

fn parseNumber(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " ");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(u32, trimmed, 10) catch null;
}

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

/// FLAC PICTURE blocks are *observed* here, never decoded: presence, MIME type,
/// and payload size are all the library needs before a user asks for the image.
/// `readPicture` is the other half, and both read the block through
/// `readPictureBlock`.
fn readPictureHeader(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
    block: MetadataBlock,
    tags: *model.ObservedTags,
) !void {
    const picture = (try readPictureBlock(readable, block)) orelse return;
    if (tags.artwork) |existing| {
        if (existing.kind == .front_cover or picture.kind != .front_cover) return;
    }
    const mime = try allocator.alloc(u8, picture.mime_length);
    errdefer allocator.free(mime);
    if (try readExact(readable, picture.mime_offset, mime) != mime.len)
        return error.TruncatedFlacStream;
    if (tags.artwork) |existing| allocator.free(existing.mime_type);
    tags.artwork = .{
        .mime_type = mime,
        .byte_size = picture.data_length,
        .kind = picture.kind,
    };
}

pub fn artworkKind(picture_type: u32) model.ArtworkKind {
    return switch (picture_type) {
        3 => .front_cover,
        4 => .back_cover,
        else => .other,
    };
}

fn readExact(readable: source.ReadableSource, offset: u64, buffer: []u8) !usize {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const chunk = try readable.readAt(offset + filled, buffer[filled..]);
        if (chunk == 0) break;
        filled += chunk;
    }
    return filled;
}

/// `genres` replaces every GENRE entry with one entry per genre, after
/// checking the file's current GENRE values are `genres.before`.
pub fn rewrite(
    allocator: std.mem.Allocator,
    payload: []const u8,
    changes: []const mutation.Change,
    genres: ?mutation.GenreChange,
) ![]u8 {
    try validateChanges(changes);
    var cursor: usize = 0;
    const vendor_text = try takeString(payload, &cursor);
    const count = try takeU32(payload, &cursor);

    if (genres) |genre_change| {
        if (!try genresMatch(payload, cursor, count, genre_change.before))
            return error.MetadataPreconditionChanged;
    }
    for (changes) |change| {
        if (change.before) |expected| {
            var found = false;
            var check_cursor = cursor;
            for (0..count) |_| {
                const entry = try takeString(payload, &check_cursor);
                const parsed = try parseEntry(entry);
                if (fieldMatches(change.field, parsed.key) and
                    valueMatches(change.field, expected, parsed.value))
                {
                    found = true;
                    break;
                }
            }
            if (!found) return error.MetadataPreconditionChanged;
        }
    }
    // A stated total survives a new track or disc number, as it does in ID3.
    var track_total: ?[]const u8 = null;
    var disc_total: ?[]const u8 = null;
    {
        var total_cursor = cursor;
        for (0..count) |_| {
            const parsed = try parseEntry(try takeString(payload, &total_cursor));
            const slash = std.mem.indexOfScalar(u8, parsed.value, '/') orelse continue;
            if (fieldMatches(.track_number, parsed.key)) track_total = parsed.value[slash..];
            if (fieldMatches(.disc_number, parsed.key)) disc_total = parsed.value[slash..];
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
        var replaced = genres != null and isGenreKey(parsed.key);
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
        const total: []const u8 = switch (change.field) {
            .track_number => track_total orelse "",
            .disc_number => disc_total orelse "",
            else => "",
        };
        const suffix = if (std.mem.indexOfScalar(u8, value, '/') == null) total else "";
        const length = try std.math.add(usize, key.len + 1, value.len + suffix.len);
        try appendU32(&output, allocator, std.math.cast(u32, length) orelse
            return error.MetadataValueTooLong);
        try output.appendSlice(allocator, key);
        try output.append(allocator, '=');
        try output.appendSlice(allocator, value);
        try output.appendSlice(allocator, suffix);
        output_count = try std.math.add(u32, output_count, 1);
    };
    if (genres) |genre_change| for (genre_change.after) |genre| {
        if (!std.unicode.utf8ValidateSlice(genre)) return error.InvalidMetadataText;
        const length = try std.math.add(usize, genre_key.len + 1, genre.len);
        try appendU32(&output, allocator, std.math.cast(u32, length) orelse
            return error.MetadataValueTooLong);
        try output.appendSlice(allocator, genre_key ++ "=");
        try output.appendSlice(allocator, genre);
        output_count = try std.math.add(u32, output_count, 1);
    };
    std.mem.writeInt(u32, output.items[count_offset..][0..4], output_count, .little);
    return output.toOwnedSlice(allocator);
}

pub fn create(
    allocator: std.mem.Allocator,
    changes: []const mutation.Change,
    genres: ?mutation.GenreChange,
) ![]u8 {
    for (changes) |change| if (change.before != null)
        return error.MetadataPreconditionChanged;
    if (genres) |genre_change| if (genre_change.before.len != 0)
        return error.MetadataPreconditionChanged;
    var base: [12]u8 = undefined;
    std.mem.writeInt(u32, base[0..4], vendor.len, .little);
    @memcpy(base[4 .. 4 + vendor.len], vendor);
    std.mem.writeInt(u32, base[8..12], 0, .little);
    return rewrite(allocator, &base, changes, genres);
}

const genre_key = "GENRE";

fn isGenreKey(key: []const u8) bool {
    return matches(key, &.{genre_key});
}

/// Whether the GENRE values the reader would collect from the `count`
/// entries at `cursor` are exactly `expected`, in order.
fn genresMatch(payload: []const u8, cursor: usize, count: u32, expected: []const []const u8) !bool {
    var check_cursor = cursor;
    var matched: usize = 0;
    for (0..count) |_| {
        const parsed = try parseEntry(try takeString(payload, &check_cursor));
        if (!isGenreKey(parsed.key)) continue;
        const value = std.mem.trim(u8, parsed.value, " \t\r\n");
        if (value.len == 0) continue;
        if (matched == expected.len or !std.mem.eql(u8, value, expected[matched])) return false;
        matched += 1;
    }
    return matched == expected.len;
}

pub const Entry = struct { key: []const u8, value: []const u8 };

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

/// Every key spelling the reader accepts for `field`, so a rewrite replaces
/// the entry the reader took its value from rather than adding a second one.
fn fieldMatches(field: mutation.Field, key: []const u8) bool {
    const spellings: []const []const u8 = switch (field) {
        .title => &.{"TITLE"},
        .artist => &.{"ARTIST"},
        .album => &.{"ALBUM"},
        .album_artist => &.{ "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST" },
        .track_number => &.{"TRACKNUMBER"},
        .disc_number => &.{"DISCNUMBER"},
        .date => &.{ "DATE", "YEAR" },
        .compilation => &.{"COMPILATION"},
        .musicbrainz_recording_id => &.{"MUSICBRAINZ_TRACKID"},
        .musicbrainz_release_id => &.{"MUSICBRAINZ_ALBUMID"},
        .musicbrainz_release_group_id => &.{"MUSICBRAINZ_RELEASEGROUPID"},
        .musicbrainz_release_track_id => &.{"MUSICBRAINZ_RELEASETRACKID"},
        .musicbrainz_album_artist_id => &.{"MUSICBRAINZ_ALBUMARTISTID"},
        .explicit => &.{"ITUNESADVISORY"},
    };
    return matches(key, spellings);
}

/// Whether a stored comment value is `expected` as the reader interprets it:
/// numbers before any `/total`, compilation as a truth value, text trimmed.
fn valueMatches(field: mutation.Field, expected: []const u8, raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    return switch (field) {
        .track_number, .disc_number => blk: {
            const number = value[0 .. std.mem.indexOfScalar(u8, value, '/') orelse value.len];
            break :blk std.mem.eql(u8, std.mem.trim(u8, number, " "), expected);
        },
        .compilation => std.mem.eql(u8, if (isTruthy(value)) "1" else "0", expected),
        else => std.mem.eql(u8, value, expected),
    };
}

fn fieldKey(field: mutation.Field) []const u8 {
    return switch (field) {
        .title => "TITLE",
        .artist => "ARTIST",
        .album => "ALBUM",
        .track_number => "TRACKNUMBER",
        .album_artist => "ALBUMARTIST",
        .disc_number => "DISCNUMBER",
        .date => "DATE",
        .compilation => "COMPILATION",
        .musicbrainz_recording_id => "MUSICBRAINZ_TRACKID",
        .musicbrainz_release_id => "MUSICBRAINZ_ALBUMID",
        .musicbrainz_release_group_id => "MUSICBRAINZ_RELEASEGROUPID",
        .musicbrainz_release_track_id => "MUSICBRAINZ_RELEASETRACKID",
        .musicbrainz_album_artist_id => "MUSICBRAINZ_ALBUMARTISTID",
        .explicit => "ITUNESADVISORY",
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
    }, null);
    defer std.testing.allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "TITLE=Néw title") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "CUSTOM=preserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ARTIST=") == null);
}

test "Vorbis comment rewrite validates preconditions and framing" {
    try std.testing.expectError(
        error.InvalidVorbisComment,
        rewrite(std.testing.allocator, "short", &.{}, null),
    );
    const created = try create(std.testing.allocator, &.{.{
        .field = .album,
        .before = null,
        .after = "Generated album",
    }}, null);
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "ALBUM=Generated album") != null);
}

fn buildComments(allocator: std.mem.Allocator, entries: []const []const u8) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(allocator);
    try appendString(&payload, allocator, "reference libFLAC");
    try appendU32(&payload, allocator, @intCast(entries.len));
    for (entries) |entry| try appendString(&payload, allocator, entry);
    return payload.toOwnedSlice(allocator);
}

const TestBlock = struct { block_type: u8, payload: []const u8 };

fn buildFlac(allocator: std.mem.Allocator, blocks: []const TestBlock) ![]u8 {
    var stream: std.ArrayList(u8) = .empty;
    errdefer stream.deinit(allocator);
    try stream.appendSlice(allocator, "fLaC");
    const stream_info: [34]u8 = @splat(0);
    var all: std.ArrayList(TestBlock) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, .{ .block_type = 0, .payload = &stream_info });
    try all.appendSlice(allocator, blocks);
    for (all.items, 0..) |block, index| {
        const last = index + 1 == all.items.len;
        try stream.append(allocator, block.block_type | @as(u8, if (last) 0x80 else 0));
        try stream.append(allocator, @intCast((block.payload.len >> 16) & 0xff));
        try stream.append(allocator, @intCast((block.payload.len >> 8) & 0xff));
        try stream.append(allocator, @intCast(block.payload.len & 0xff));
        try stream.appendSlice(allocator, block.payload);
    }
    return stream.toOwnedSlice(allocator);
}

fn readStream(allocator: std.mem.Allocator, bytes: []const u8) !?model.ObservedTags {
    var memory = source.MemorySource{ .bytes = bytes };
    return read(allocator, memory.readable());
}

test "Vorbis comment keys match case-insensitively in their real mixed spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try buildComments(allocator, &.{
        "TITLE=Reference Tone",
        "ARTIST=Orca Test",
        "album=Fixtures",
        "albumartist=Orca Ensemble",
        "Album Artist=Ignored second spelling",
        "TRACKNUMBER=4",
        "DATE=2026-08-23",
        "compilation=1",
    });
    const tags = (try readStream(allocator, try buildFlac(allocator, &.{
        .{ .block_type = 4, .payload = payload },
    }))).?;

    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.album.?);
    try std.testing.expectEqualStrings("Orca Ensemble", tags.album_artist.?);
    try std.testing.expectEqual(@as(?u32, 4), tags.track_number);
    try std.testing.expectEqualStrings("2026-08-23", tags.date.?);
    try std.testing.expectEqual(@as(?bool, true), tags.compilation);
}

test "repeated Vorbis keys keep the first value and collect every genre" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try buildComments(allocator, &.{
        "GENRE=Ambient",
        "TITLE=First wins",
        "GENRE=Electronic",
        "TITLE=Second is discarded",
        "GENRE=Downtempo",
    });
    const tags = (try readStream(allocator, try buildFlac(allocator, &.{
        .{ .block_type = 4, .payload = payload },
    }))).?;

    try std.testing.expectEqualStrings("First wins", tags.title.?);
    try std.testing.expectEqual(@as(usize, 3), tags.genres.len);
    try std.testing.expectEqualStrings("Ambient", tags.genres[0]);
    try std.testing.expectEqualStrings("Downtempo", tags.genres[2]);
}

test "both total-count conventions and MusicBrainz identifiers are read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try buildComments(allocator, &.{
        "TRACKNUMBER=2",
        "TOTALTRACKS=12",
        "DISCNUMBER=1",
        "DISCTOTAL=2",
        "MUSICBRAINZ_TRACKID=recording-uuid",
        "MUSICBRAINZ_ALBUMID=release-uuid",
        "MUSICBRAINZ_ALBUMARTISTID=album-artist-uuid",
        "MUSICBRAINZ_RELEASEGROUPID=group-uuid",
        "MUSICBRAINZ_RELEASETRACKID=release-track-uuid",
        "MUSICBRAINZ_ARTISTID=artist-uuid",
        "MUSICBRAINZ_ALBUMTYPE=album",
        "MUSICBRAINZ_ALBUMSTATUS=official",
        "RELEASECOUNTRY=GB",
        "LABEL=Orca Records",
        "MEDIA=CD",
        "ISRC=GBAAA2600001",
        "ORIGINALDATE=1999",
    });
    const tags = (try readStream(allocator, try buildFlac(allocator, &.{
        .{ .block_type = 4, .payload = payload },
    }))).?;

    try std.testing.expectEqual(@as(?u32, 12), tags.track_total);
    try std.testing.expectEqual(@as(?u32, 2), tags.disc_total);
    try std.testing.expectEqualStrings("recording-uuid", tags.musicbrainz_recording_id.?);
    try std.testing.expectEqualStrings("release-uuid", tags.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings("group-uuid", tags.musicbrainz_release_group_id.?);
    try std.testing.expectEqualStrings(
        "release-track-uuid",
        tags.musicbrainz_release_track_id.?,
    );
    try std.testing.expectEqualStrings("artist-uuid", tags.musicbrainz_artist_id.?);
    try std.testing.expectEqualStrings(
        "album-artist-uuid",
        tags.musicbrainz_album_artist_id.?,
    );
    try std.testing.expectEqualStrings("album", tags.release_type.?);
    try std.testing.expectEqualStrings("official", tags.release_status.?);
    try std.testing.expectEqualStrings("GB", tags.release_country.?);
    try std.testing.expectEqualStrings("Orca Records", tags.label.?);
    try std.testing.expectEqualStrings("CD", tags.media.?);
    try std.testing.expectEqualStrings("GBAAA2600001", tags.isrc.?);
    try std.testing.expectEqualStrings("1999", tags.original_date.?);
}

test "an ITUNESADVISORY comment states the advisory, and a value outside 0 to 2 states none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]struct { comment: []const u8, expected: ?model.Explicit }{
        .{ .comment = "ITUNESADVISORY=2", .expected = .clean },
        .{ .comment = "iTunesAdvisory=1", .expected = .explicit },
        .{ .comment = "ITUNESADVISORY=0", .expected = .none },
        .{ .comment = "ITUNESADVISORY=yes", .expected = null },
    }) |case| {
        const payload = try buildComments(allocator, &.{ "TITLE=Advisory", case.comment });
        const tags = (try readStream(allocator, try buildFlac(allocator, &.{
            .{ .block_type = 4, .payload = payload },
        }))).?;
        try std.testing.expectEqual(case.expected, tags.explicit);
    }
}

test "packed track totals and missing core fields are normal outcomes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try buildComments(allocator, &.{
        "TITLE=Untitled by its artist",
        "TRACKNUMBER=3/11",
        "DISCNUMBER=1/2",
        "ALBUM=",
    });
    const tags = (try readStream(allocator, try buildFlac(allocator, &.{
        .{ .block_type = 4, .payload = payload },
    }))).?;

    try std.testing.expect(tags.artist == null);
    try std.testing.expect(tags.album == null);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_number);
    try std.testing.expectEqual(@as(?u32, 11), tags.track_total);
    try std.testing.expectEqual(@as(?u32, 1), tags.disc_number);
    try std.testing.expectEqual(@as(?u32, 2), tags.disc_total);
}

test "FLAC picture blocks are reported without decoding image data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var picture: std.ArrayList(u8) = .empty;
    try appendU32Big(&picture, allocator, 3);
    try appendU32Big(&picture, allocator, 9);
    try picture.appendSlice(allocator, "image/png");
    try appendU32Big(&picture, allocator, 0);
    for (0..4) |_| try appendU32Big(&picture, allocator, 0);
    try appendU32Big(&picture, allocator, 128);
    try picture.appendNTimes(allocator, 0x11, 128);

    const payload = try buildComments(allocator, &.{"TITLE=With art"});
    const tags = (try readStream(allocator, try buildFlac(allocator, &.{
        .{ .block_type = 4, .payload = payload },
        .{ .block_type = 6, .payload = picture.items },
    }))).?;

    try std.testing.expectEqualStrings("With art", tags.title.?);
    try std.testing.expectEqualStrings("image/png", tags.artwork.?.mime_type);
    try std.testing.expectEqual(@as(u64, 128), tags.artwork.?.byte_size);
    try std.testing.expectEqual(model.ArtworkKind.front_cover, tags.artwork.?.kind);
}

test "truncated and malformed FLAC metadata is rejected without reading past the end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(try readStream(allocator, "fL") == null);
    try std.testing.expectError(
        error.InvalidFlacStream,
        readStream(allocator, "OggSnot a flac stream"),
    );
    // A block header that claims more payload than the stream holds.
    try std.testing.expectError(
        error.TruncatedFlacStream,
        readStream(allocator, "fLaC\x84\x00\x10\x00short"),
    );
    // A comment payload whose entry count runs off the end of the block.
    var overclaimed: std.ArrayList(u8) = .empty;
    try appendString(&overclaimed, allocator, "reference libFLAC");
    try appendU32(&overclaimed, allocator, 5);
    try appendString(&overclaimed, allocator, "TITLE=Complete");
    try std.testing.expectError(error.InvalidVorbisComment, readStream(
        allocator,
        try buildFlac(allocator, &.{.{ .block_type = 4, .payload = overclaimed.items }}),
    ));
    // An entry with no `=` separator is not a comment.
    var unseparated: std.ArrayList(u8) = .empty;
    try appendString(&unseparated, allocator, "reference libFLAC");
    try appendU32(&unseparated, allocator, 1);
    try appendString(&unseparated, allocator, "TITLE no separator");
    try std.testing.expectError(error.InvalidVorbisComment, readStream(
        allocator,
        try buildFlac(allocator, &.{.{ .block_type = 4, .payload = unseparated.items }}),
    ));
    // A stream with no comment block at all simply has no tags.
    try std.testing.expect(try readStream(
        allocator,
        try buildFlac(allocator, &.{}),
    ) == null);
}

test "tagged FLAC fixture reads its real Vorbis comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var file = try source.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    defer file.close();
    const tags = (try read(allocator, file.readable())).?;
    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.album.?);
    try std.testing.expectEqualStrings("Orca Test", tags.album_artist.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.track_number);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_total);
    try std.testing.expectEqualStrings("2026", tags.date.?);
}

fn appendU32Big(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(allocator, &bytes);
}

fn commentPayload(allocator: std.mem.Allocator, entries: []const []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendString(&bytes, allocator, "test");
    try appendU32(&bytes, allocator, @intCast(entries.len));
    for (entries) |entry| try appendString(&bytes, allocator, entry);
    return bytes.toOwnedSlice(allocator);
}

test "a rewrite matches what the reader saw: aliased keys, n/total numbers and truth values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try commentPayload(allocator, &.{
        "ALBUM ARTIST=Old Artist",
        "TRACKNUMBER=2/9",
        "COMPILATION=true",
        "YEAR=1999",
        "COMMENT=kept",
    });
    const before = try parse(allocator, payload);
    try std.testing.expectEqualStrings("Old Artist", before.album_artist.?);

    const rewritten = try rewrite(allocator, payload, &.{
        .{ .field = .album_artist, .before = "Old Artist", .after = "New Artist" },
        .{ .field = .track_number, .before = "2", .after = "5" },
        .{ .field = .compilation, .before = "1", .after = "0" },
        .{ .field = .date, .before = "1999", .after = "2024" },
    }, null);
    const after = try parse(allocator, rewritten);
    try std.testing.expectEqualStrings("New Artist", after.album_artist.?);
    try std.testing.expectEqual(@as(?u32, 5), after.track_number);
    try std.testing.expectEqual(@as(?u32, 9), after.track_total);
    try std.testing.expectEqual(@as(?bool, false), after.compilation);
    try std.testing.expectEqualStrings("2024", after.date.?);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "ALBUM ARTIST=") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "YEAR=") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "COMMENT=kept") != null);
}

test "a recording id rewrite replaces the existing MUSICBRAINZ_TRACKID in place of adding one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_id = "11111111-2222-4333-8444-555555555555";
    const new_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const payload = try commentPayload(allocator, &.{
        "TITLE=Kept",
        "musicbrainz_trackid=" ++ old_id,
        "MUSICBRAINZ_RELEASETRACKID=release-track-uuid",
    });
    try std.testing.expectEqualStrings(old_id, (try parse(allocator, payload)).musicbrainz_recording_id.?);

    const rewritten = try rewrite(allocator, payload, &.{
        .{ .field = .musicbrainz_recording_id, .before = old_id, .after = new_id },
    }, null);
    const after = try parse(allocator, rewritten);
    try std.testing.expectEqualStrings(new_id, after.musicbrainz_recording_id.?);
    try std.testing.expectEqualStrings("release-track-uuid", after.musicbrainz_release_track_id.?);
    try std.testing.expectEqualStrings("Kept", after.title.?);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, old_id) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rewritten, "MUSICBRAINZ_TRACKID="));
}

test "a genre rewrite replaces every GENRE entry in any case with one entry per genre" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try commentPayload(allocator, &.{
        "genre=Indie Rock, Rock",
        "TITLE=Kept",
        "GENRE= ",
        "Genre=Pop",
    });
    const changed: mutation.GenreChange = .{
        .before = &.{ "Indie Rock, Rock", "Pop" },
        .after = &.{ "Shoegaze", "Dream Pop" },
    };

    const rewritten = try rewrite(allocator, payload, &.{}, changed);
    const after = try parse(allocator, rewritten);
    try std.testing.expectEqual(@as(usize, 2), after.genres.len);
    try std.testing.expectEqualStrings("Shoegaze", after.genres[0]);
    try std.testing.expectEqualStrings("Dream Pop", after.genres[1]);
    try std.testing.expectEqualStrings("Kept", after.title.?);
    try std.testing.expectEqual(@as(usize, 2), try countEntries(rewritten, "GENRE"));
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Indie Rock") == null);

    const created = try create(allocator, &.{}, .{ .before = &.{}, .after = &.{"Jazz"} });
    try std.testing.expectEqualStrings("Jazz", (try parse(allocator, created)).genres[0]);
}

test "a genre rewrite refuses a file whose genres are no longer the ones previewed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payload = try commentPayload(allocator, &.{ "GENRE=Rock", "GENRE=Pop" });
    for ([_][]const []const u8{ &.{"Rock"}, &.{ "Pop", "Rock" }, &.{ "Rock", "Pop", "Jazz" }, &.{} }) |before| {
        try std.testing.expectError(
            error.MetadataPreconditionChanged,
            rewrite(allocator, payload, &.{}, .{ .before = before, .after = &.{"Jazz"} }),
        );
    }
    try std.testing.expectError(
        error.MetadataPreconditionChanged,
        create(allocator, &.{}, .{ .before = &.{"Rock"}, .after = &.{"Jazz"} }),
    );
}

fn countEntries(payload: []const u8, key: []const u8) !usize {
    var entries = try Entries.init(payload);
    var count: usize = 0;
    while (try entries.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, key)) count += 1;
    }
    return count;
}

test "a release id rewrite replaces every MUSICBRAINZ_ALBUMID entry in any case with one and keeps the other keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_id = "11111111-2222-4333-8444-555555555555";
    const second_old_id = "22222222-3333-4444-8555-666666666666";
    const new_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const recording_id = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const payload = try commentPayload(allocator, &.{
        "TITLE=Kept",
        "musicbrainz_albumid=" ++ old_id,
        "MUSICBRAINZ_TRACKID=" ++ recording_id,
        "MusicBrainz_AlbumId=" ++ second_old_id,
        "CUSTOM=preserved",
    });
    try std.testing.expectEqualStrings(old_id, (try parse(allocator, payload)).musicbrainz_release_id.?);

    const rewritten = try rewrite(allocator, payload, &.{
        .{ .field = .musicbrainz_release_id, .before = old_id, .after = new_id },
    }, null);
    const after = try parse(allocator, rewritten);
    try std.testing.expectEqualStrings(new_id, after.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings(recording_id, after.musicbrainz_recording_id.?);
    try std.testing.expectEqualStrings("Kept", after.title.?);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "MUSICBRAINZ_TRACKID=" ++ recording_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "CUSTOM=preserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, old_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, second_old_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "MUSICBRAINZ_ALBUMID=" ++ new_id) != null);
    try std.testing.expectEqual(@as(usize, 1), try countEntries(rewritten, "MUSICBRAINZ_ALBUMID"));
    try std.testing.expectEqual(@as(u32, 4), (try Entries.init(rewritten)).remaining);
}

test "every release-level MusicBrainz id is written under Picard's Vorbis key and read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const release_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const release_group_id = "0b6a3a3e-3b2c-4c8e-9a51-1f2d3c4b5a69";
    const release_track_id = "c2f7b3a4-5d6e-4f80-9a1b-2c3d4e5f6a7b";
    const album_artist_id = "d4e5f6a7-b8c9-4d0e-8f1a-2b3c4d5e6f70";
    const created = try create(allocator, &.{
        .{ .field = .musicbrainz_release_id, .before = null, .after = release_id },
        .{ .field = .musicbrainz_release_group_id, .before = null, .after = release_group_id },
        .{ .field = .musicbrainz_release_track_id, .before = null, .after = release_track_id },
        .{ .field = .musicbrainz_album_artist_id, .before = null, .after = album_artist_id },
    }, null);
    const tags = try parse(allocator, created);
    try std.testing.expectEqualStrings(release_id, tags.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings(release_group_id, tags.musicbrainz_release_group_id.?);
    try std.testing.expectEqualStrings(release_track_id, tags.musicbrainz_release_track_id.?);
    try std.testing.expectEqualStrings(album_artist_id, tags.musicbrainz_album_artist_id.?);
    for ([_][]const u8{
        "MUSICBRAINZ_ALBUMID=" ++ release_id,
        "MUSICBRAINZ_RELEASEGROUPID=" ++ release_group_id,
        "MUSICBRAINZ_RELEASETRACKID=" ++ release_track_id,
        "MUSICBRAINZ_ALBUMARTISTID=" ++ album_artist_id,
    }) |entry| try std.testing.expect(std.mem.indexOf(u8, created, entry) != null);
}

test "LYRICS outranks UNSYNCEDLYRICS in any key case and an empty one is passed over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const comments = try buildComments(allocator, &.{
        "unsyncedlyrics=Plain text",
        "Lyrics=",
        "lyrics=[00:01.50]Timed",
    });
    const stream = try buildFlac(allocator, &.{.{ .block_type = 4, .payload = comments }});
    var memory = source.MemorySource{ .bytes = stream };
    const content = (try readLyrics(std.testing.allocator, allocator, memory.readable())).?;
    try std.testing.expectEqual(lyrics.Kind.synced, content.kind);
    try std.testing.expectEqual(@as(?u32, 1500), content.lines[0].start_ms);
}

test "UNSYNCEDLYRICS is read when no LYRICS comment has text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const comments = try buildComments(allocator, &.{ "TITLE=Song", "UNSYNCEDLYRICS=Plain text" });
    const content = (try lyricsFromComments(allocator, comments)).?;
    try std.testing.expectEqual(lyrics.Kind.plain, content.kind);
    try std.testing.expectEqualStrings("Plain text", content.lines[0].text);
}
