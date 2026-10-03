const std = @import("std");
const id3v1 = @import("id3v1.zig");
const lrc = @import("lrc.zig");
const lyrics = @import("lyrics.zig");
const model = @import("model.zig");
const mutation = @import("mutation.zig");
const source = @import("../storage/source.zig");

/// An ID3v2 size field is syncsafe and therefore cannot exceed 256 MiB, but no
/// honest tag approaches that. Anything larger is refused before allocating.
pub const max_tag_bytes: usize = 16 << 20;

const max_text_bytes: usize = 1 << 20;

pub const ReadError = error{
    InvalidId3v2Tag,
    TruncatedId3v2Tag,
    InvalidId3v2Text,
    Id3v2TagTooLarge,
};

/// Read canonical tags from the ID3v2 tag at the start of a stream.
///
/// Returns null when the stream carries no ID3v2 tag Orca can read: no `ID3`
/// identifier, an empty tag, or a major version outside 2.3/2.4. Callers fall
/// back to ID3v1 in that case. Text allocated from `allocator` lives until the
/// caller frees it; callers are expected to pass an arena.
pub fn read(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
) !?model.ObservedTags {
    const tag = try loadTag(allocator, readable) orelse return null;
    defer tag.deinit();
    return try parseFrames(allocator, tag.span, tag.major);
}

/// Extract the cover image an `APIC` frame carries, or null when the tag has
/// none Orca can use.
///
/// A front cover outranks every other picture type, and the first front cover
/// wins; with no front cover present the first usable picture is taken. That
/// is the same preference `applyPicture` records as an observation, so a file
/// whose scan says "front cover, 216 KB, image/jpeg" hands back those bytes
/// and not a different picture from the same tag.
pub fn readPicture(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
) !?model.EmbeddedImage {
    const tag = try loadTag(allocator, readable) orelse return null;
    defer tag.deinit();

    var frames: FrameIterator = .{ .body = tag.span, .major = tag.major };
    var chosen: ?Picture = null;
    while (try frames.next()) |frame| {
        if (!std.mem.eql(u8, &frame.identifier, "APIC")) continue;
        const picture = decodePicture(frame.data) orelse continue;
        if (chosen) |existing| {
            if (existing.kind == .front_cover or picture.kind != .front_cover) continue;
        }
        chosen = picture;
        if (picture.kind == .front_cover) break;
    }

    const picture = chosen orelse return null;
    // Bounded before the copy, not after it. The tag body is already capped at
    // `max_tag_bytes`, so this can only bite when the two bounds differ.
    if (picture.data.len > model.max_image_bytes) return error.ArtworkTooLarge;
    const bytes = try allocator.dupe(u8, picture.data);
    errdefer allocator.free(bytes);
    return try model.adoptImage(allocator, bytes, picture.kind);
}

/// The lyrics in a tag: a `SYLT` frame of lyrics timed in milliseconds,
/// else the first `USLT` frame with text. Lines are allocated from `output`;
/// `allocator` holds the tag while it is read. A frame that does not parse is
/// passed over, and a tag that stops parsing keeps what came before.
pub fn readLyrics(
    allocator: std.mem.Allocator,
    output: std.mem.Allocator,
    readable: source.ReadableSource,
) !?lyrics.Content {
    const tag = try loadTag(allocator, readable) orelse return null;
    defer tag.deinit();

    var frames: FrameIterator = .{ .body = tag.span, .major = tag.major };
    var unsynchronised: ?lyrics.Content = null;
    while (frames.next() catch null) |frame| {
        if (std.mem.eql(u8, &frame.identifier, "SYLT")) {
            if (try decodeSynchronisedLyrics(output, frame.data)) |content| return content;
        } else if (unsynchronised == null and std.mem.eql(u8, &frame.identifier, "USLT")) {
            unsynchronised = try decodeUnsynchronisedLyrics(allocator, output, frame.data);
        }
    }
    return unsynchronised;
}

/// `SYLT`: encoding(1), language(3), timestamp format(1), content type(1),
/// descriptor, then entries of terminated text and a 32-bit start. Only
/// lyrics (content type 1) timed in milliseconds (format 2) are used.
fn decodeSynchronisedLyrics(output: std.mem.Allocator, data: []const u8) !?lyrics.Content {
    if (data.len < 6 or data.len > lyrics.max_text_bytes) return null;
    const encoding = data[0];
    if (encoding > 3 or data[4] != 2 or data[5] != 1) return null;
    const width: usize = if (isWideEncoding(encoding)) 2 else 1;
    var rest = data[6..];
    rest = rest[(terminatorLength(encoding, rest) orelse return null)..];

    var lines: std.ArrayList(lyrics.Line) = .empty;
    var any_text = false;
    while (rest.len > 0) {
        const consumed = terminatorLength(encoding, rest) orelse return null;
        if (consumed < width or consumed + 4 > rest.len) return null;
        var text = decodeText(output, encoding, rest[0 .. consumed - width]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (std.mem.startsWith(u8, text, "\n")) text = text[1..];
        if (text.len > 0) any_text = true;
        if (lines.items.len == lyrics.max_lines) return null;
        try lines.append(output, .{
            .start_ms = std.mem.readInt(u32, rest[consumed..][0..4], .big),
            .text = text,
        });
        rest = rest[consumed + 4 ..];
    }
    if (!any_text) return null;
    const owned = try lines.toOwnedSlice(output);
    lyrics.sortLines(owned);
    return .{ .kind = .synced, .language = lyrics.languageCode(data[1..4].*), .lines = owned };
}

/// `USLT`: encoding(1), language(3), descriptor, then the text, which may be
/// LRC. Null when the text is empty or does not decode.
fn decodeUnsynchronisedLyrics(
    allocator: std.mem.Allocator,
    output: std.mem.Allocator,
    data: []const u8,
) !?lyrics.Content {
    if (data.len < 4 or data.len > 2 * lyrics.max_text_bytes) return null;
    const encoding = data[0];
    if (encoding > 3) return null;
    var rest = data[4..];
    rest = rest[(terminatorLength(encoding, rest) orelse return null)..];
    const width: usize = if (isWideEncoding(encoding)) 2 else 1;
    while (rest.len >= width and std.mem.allEqual(u8, rest[rest.len - width ..], 0))
        rest = rest[0 .. rest.len - width];
    const text = decodeText(allocator, encoding, rest) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(text);
    var content = try lrc.parse(output, text) orelse return null;
    content.language = lyrics.languageCode(data[1..4].*);
    return content;
}

/// A tag read into memory, unsynchronized and past its extended header.
const LoadedTag = struct {
    allocator: std.mem.Allocator,
    /// The allocation, which `span` is a view into.
    body: []u8,
    span: []u8,
    major: u8,

    fn deinit(self: LoadedTag) void {
        self.allocator.free(self.body);
    }
};

fn loadTag(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
) !?LoadedTag {
    var header: [10]u8 = undefined;
    if (try readExact(readable, 0, &header) != header.len) return null;
    if (!std.mem.eql(u8, header[0..3], "ID3")) return null;
    if (header[3] == 0xff or header[4] == 0xff) return error.InvalidId3v2Tag;
    const major = header[3];
    const size = try syncsafe(header[6..10].*);
    if (size == 0) return null;
    if (size > max_tag_bytes) return error.Id3v2TagTooLarge;
    // ID3v2.2 frame identifiers are three bytes wide and a different frame set;
    // it is deliberately not read here, and neither is any future major.
    if (major < 3 or major > 4) return null;
    if (size > readable.size() - header.len) return error.TruncatedId3v2Tag;

    const body = try allocator.alloc(u8, size);
    errdefer allocator.free(body);
    if (try readExact(readable, header.len, body) != body.len)
        return error.TruncatedId3v2Tag;

    const flags = header[5];
    var span: []u8 = body;
    if (flags & 0x80 != 0) span = unsynchronize(span);
    if (flags & 0x40 != 0) span = try skipExtendedHeader(span, major);
    return .{ .allocator = allocator, .body = body, .span = span, .major = major };
}

/// Total bytes an ID3v2 tag occupies at the head of a stream, or zero when the
/// stream does not begin with one. Lets container readers skip a leading tag.
pub fn prefixLength(readable: source.ReadableSource) !u64 {
    var header: [10]u8 = undefined;
    if (try readExact(readable, 0, &header) != header.len) return 0;
    if (!std.mem.eql(u8, header[0..3], "ID3")) return 0;
    if (header[3] == 0xff or header[4] == 0xff) return error.InvalidId3v2Tag;
    const size = try syncsafe(header[6..10].*);
    const footer: u64 = if (header[5] & 0x10 != 0) 10 else 0;
    return @as(u64, header.len) + size + footer;
}

fn syncsafe(bytes: [4]u8) !u32 {
    var value: u32 = 0;
    for (bytes) |byte| {
        if (byte & 0x80 != 0) return error.InvalidId3v2Tag;
        value = (value << 7) | byte;
    }
    return value;
}

/// Undo unsynchronization in place: every `0xFF 0x00` pair becomes `0xFF`. The
/// result aliases the input buffer, which is why callers own mutable bytes.
fn unsynchronize(bytes: []u8) []u8 {
    var write: usize = 0;
    var read_index: usize = 0;
    while (read_index < bytes.len) {
        const byte = bytes[read_index];
        bytes[write] = byte;
        write += 1;
        read_index += 1;
        if (byte == 0xff and read_index < bytes.len and bytes[read_index] == 0x00)
            read_index += 1;
    }
    return bytes[0..write];
}

fn skipExtendedHeader(bytes: []u8, major: u8) ![]u8 {
    if (bytes.len < 6) return error.TruncatedId3v2Tag;
    // v2.4 states a syncsafe size that includes the size field; v2.3 states a
    // plain size that excludes it.
    const declared: usize = if (major >= 4)
        try syncsafe(bytes[0..4].*)
    else
        std.mem.readInt(u32, bytes[0..4], .big) + 4;
    if (declared < 4 or declared > bytes.len) return error.TruncatedId3v2Tag;
    return bytes[declared..];
}

/// One frame's identifier and its payload, already stripped of the group,
/// data-length and per-frame unsynchronization prefixes the flags announce.
const Frame = struct {
    identifier: [4]u8,
    data: []u8,
};

/// Walks a tag body frame by frame.
///
/// Extracted so that reading tags and reading a cover image are the same walk
/// over the same bytes. They diverge only in what they do with a frame, and a
/// second copy of ID3v2's size-field and frame-flag rules is exactly the kind
/// of thing that drifts.
const FrameIterator = struct {
    body: []u8,
    major: u8,
    position: usize = 0,

    fn next(self: *FrameIterator) !?Frame {
        while (self.position + 10 <= self.body.len) {
            const identifier = self.body[self.position..][0..4].*;
            // Padding, or a stream that stopped making sense: keep what was
            // read rather than discarding a tag over trailing garbage.
            if (identifier[0] == 0 or !isFrameIdentifier(&identifier)) return null;
            const size_bytes = self.body[self.position + 4 ..][0..4].*;
            const declared: usize = if (self.major >= 4)
                syncsafe(size_bytes) catch std.mem.readInt(u32, &size_bytes, .big)
            else
                std.mem.readInt(u32, &size_bytes, .big);
            const format_flags = self.body[self.position + 9];
            self.position += 10;
            if (declared > self.body.len - self.position) return error.TruncatedId3v2Tag;
            var data = self.body[self.position..][0..declared];
            self.position += declared;

            if (self.major >= 4) {
                if (format_flags & 0x40 != 0) data = advance(data, 1) orelse continue;
                // Compressed or encrypted payloads are skipped, not guessed at.
                if (format_flags & 0x0c != 0) continue;
                if (format_flags & 0x01 != 0) data = advance(data, 4) orelse continue;
                if (format_flags & 0x02 != 0) data = unsynchronize(data);
            } else {
                if (format_flags & 0xc0 != 0) continue;
                if (format_flags & 0x20 != 0) data = advance(data, 1) orelse continue;
            }
            return .{ .identifier = identifier, .data = data };
        }
        return null;
    }
};

fn parseFrames(
    allocator: std.mem.Allocator,
    body: []u8,
    major: u8,
) !model.ObservedTags {
    var tags: model.ObservedTags = .{};
    var genres: std.ArrayList([]const u8) = .empty;
    defer genres.deinit(allocator);
    var pending_day_month: ?[]const u8 = null;

    var frames: FrameIterator = .{ .body = body, .major = major };
    while (try frames.next()) |frame| try applyFrame(
        allocator,
        &frame.identifier,
        frame.data,
        &tags,
        &genres,
        &pending_day_month,
    );

    if (pending_day_month) |day_month| try applyDayMonth(allocator, &tags, day_month);
    tags.genres = try genres.toOwnedSlice(allocator);
    return tags;
}

fn advance(data: []u8, count: usize) ?[]u8 {
    if (data.len < count) return null;
    return data[count..];
}

fn isFrameIdentifier(identifier: *const [4]u8) bool {
    for (identifier) |byte| {
        if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// Frame identifiers, encoding bytes, `n/total` packing, and numeric genre
/// references all terminate here; only canonical values leave this function.
fn applyFrame(
    allocator: std.mem.Allocator,
    identifier: *const [4]u8,
    data: []const u8,
    tags: *model.ObservedTags,
    genres: *std.ArrayList([]const u8),
    pending_day_month: *?[]const u8,
) !void {
    const id = identifier.*;
    if (std.mem.eql(u8, &id, "APIC")) return applyPicture(allocator, data, tags);
    if (std.mem.eql(u8, &id, "UFID")) return applyUniqueFileIdentifier(allocator, data, tags);
    if (std.mem.eql(u8, &id, "TXXX")) return applyUserText(allocator, data, tags);
    if (id[0] != 'T') return;

    var values = try decodeTextValues(allocator, data);
    defer values.deinit(allocator);
    if (values.items.len == 0) return;
    const first = values.items[0];

    if (std.mem.eql(u8, &id, "TCON")) {
        for (values.items) |value| {
            const name = try canonicalGenre(allocator, value);
            if (name.len != 0) try genres.append(allocator, name);
        }
        return;
    }
    if (std.mem.eql(u8, &id, "TIT2")) return claim(&tags.title, first);
    if (std.mem.eql(u8, &id, "TPE1")) return claim(&tags.artist, first);
    if (std.mem.eql(u8, &id, "TPE2")) return claim(&tags.album_artist, first);
    if (std.mem.eql(u8, &id, "TALB")) return claim(&tags.album, first);
    if (std.mem.eql(u8, &id, "TCOM")) return claim(&tags.composer, first);
    if (std.mem.eql(u8, &id, "TPUB")) return claim(&tags.label, first);
    if (std.mem.eql(u8, &id, "TMED")) return claim(&tags.media, first);
    if (std.mem.eql(u8, &id, "TSRC")) return claim(&tags.isrc, first);
    if (std.mem.eql(u8, &id, "TRCK")) return claimPair(first, &tags.track_number, &tags.track_total);
    if (std.mem.eql(u8, &id, "TPOS")) return claimPair(first, &tags.disc_number, &tags.disc_total);
    if (std.mem.eql(u8, &id, "TCMP")) {
        if (tags.compilation == null) tags.compilation = isTruthy(first);
        return;
    }
    if (std.mem.eql(u8, &id, "TDRC") or std.mem.eql(u8, &id, "TYER"))
        return claim(&tags.date, first);
    if (std.mem.eql(u8, &id, "TDOR") or std.mem.eql(u8, &id, "TORY"))
        return claim(&tags.original_date, first);
    // v2.3 splits the release date into a year frame and a `DDMM` frame; the
    // pair is recombined once both have been seen.
    if (std.mem.eql(u8, &id, "TDAT") and pending_day_month.* == null and first.len == 4)
        pending_day_month.* = try allocator.dupe(u8, first);
}

fn applyDayMonth(
    allocator: std.mem.Allocator,
    tags: *model.ObservedTags,
    day_month: []const u8,
) !void {
    const year = tags.date orelse return;
    if (year.len != 4) return;
    for (day_month) |byte| if (!std.ascii.isDigit(byte)) return;
    tags.date = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
        year,
        day_month[2..4],
        day_month[0..2],
    });
}

fn applyUserText(
    allocator: std.mem.Allocator,
    data: []const u8,
    tags: *model.ObservedTags,
) !void {
    var values = try decodeTextValues(allocator, data);
    defer values.deinit(allocator);
    if (values.items.len < 2) return;
    const description = values.items[0];
    const value = values.items[1];
    if (value.len == 0) return;
    if (eqlAny(description, recording_id_descriptions))
        return claim(&tags.musicbrainz_recording_id, value);
    if (eqlAny(description, release_id_descriptions))
        return claim(&tags.musicbrainz_release_id, value);
    if (eqlAny(description, release_group_id_descriptions))
        return claim(&tags.musicbrainz_release_group_id, value);
    if (eqlAny(description, release_track_id_descriptions))
        return claim(&tags.musicbrainz_release_track_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Artist Id", "MUSICBRAINZ_ARTISTID" }))
        return claim(&tags.musicbrainz_artist_id, value);
    if (eqlAny(description, album_artist_id_descriptions))
        return claim(&tags.musicbrainz_album_artist_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Album Type", "RELEASETYPE" }))
        return claim(&tags.release_type, value);
    if (eqlAny(description, &.{ "MusicBrainz Album Status", "RELEASESTATUS" }))
        return claim(&tags.release_status, value);
    if (eqlAny(description, &.{ "MusicBrainz Album Release Country", "RELEASECOUNTRY" }))
        return claim(&tags.release_country, value);
    if (eqlAny(description, &.{ "originaldate", "originalyear" }))
        return claim(&tags.original_date, value);
    if (eqlAny(description, &.{"LABEL"})) return claim(&tags.label, value);
    if (eqlAny(description, &.{"ISRC"})) return claim(&tags.isrc, value);
    if (eqlAny(description, &.{"COMPILATION"})) {
        if (tags.compilation == null) tags.compilation = isTruthy(value);
        return;
    }
    if (eqlAny(description, advisory_descriptions)) {
        if (tags.explicit == null) tags.explicit = model.Explicit.fromAdvisoryText(value);
        return;
    }
}

const recording_id_descriptions: []const []const u8 = &.{ "MusicBrainz Track Id", "MUSICBRAINZ_TRACKID" };
const release_id_descriptions: []const []const u8 = &.{ "MusicBrainz Album Id", "MUSICBRAINZ_ALBUMID" };
const release_group_id_descriptions: []const []const u8 = &.{ "MusicBrainz Release Group Id", "MUSICBRAINZ_RELEASEGROUPID" };
const release_track_id_descriptions: []const []const u8 = &.{ "MusicBrainz Release Track Id", "MUSICBRAINZ_RELEASETRACKID" };
const album_artist_id_descriptions: []const []const u8 = &.{ "MusicBrainz Album Artist Id", "MUSICBRAINZ_ALBUMARTISTID" };
const advisory_descriptions: []const []const u8 = &.{"ITUNESADVISORY"};
const musicbrainz_ufid_owner = "http://musicbrainz.org";

fn applyUniqueFileIdentifier(
    allocator: std.mem.Allocator,
    data: []const u8,
    tags: *model.ObservedTags,
) !void {
    const split = std.mem.indexOfScalar(u8, data, 0) orelse return;
    const owner = data[0..split];
    if (!std.mem.eql(u8, owner, musicbrainz_ufid_owner)) return;
    const identifier = data[split + 1 ..];
    if (identifier.len == 0 or identifier.len > 128) return;
    for (identifier) |byte| if (byte < 0x20 or byte > 0x7e) return;
    if (tags.musicbrainz_recording_id != null) return;
    tags.musicbrainz_recording_id = try allocator.dupe(u8, identifier);
}

/// What an `APIC` frame body means, with the frame layout stripped off.
///
/// `mime` and `data` borrow the frame, which borrows the tag body.
const Picture = struct {
    mime: []const u8,
    data: []const u8,
    kind: model.ArtworkKind,
};

/// Split an `APIC` body into its declared type and its payload.
///
/// The one definition of the frame's layout: an observation and a fetch must
/// not be able to disagree about which bytes are the image. Returns null for a
/// frame that carries no image — a malformed body, an empty payload, or the
/// `-->` MIME type, which the spec defines as a *link* to an image elsewhere
/// rather than an image.
fn decodePicture(data: []const u8) ?Picture {
    if (data.len < 4) return null;
    const encoding = data[0];
    const mime_end = std.mem.indexOfScalar(u8, data[1..], 0) orelse return null;
    const mime = data[1 .. 1 + mime_end];
    var cursor = 1 + mime_end + 1;
    if (cursor >= data.len) return null;
    const picture_type = data[cursor];
    cursor += 1;
    const description = terminatorLength(encoding, data[cursor..]) orelse return null;
    cursor += description;
    if (cursor >= data.len) return null;
    if (std.mem.eql(u8, mime, "-->")) return null;
    return .{
        .mime = mime,
        .data = data[cursor..],
        .kind = switch (picture_type) {
            3 => .front_cover,
            4 => .back_cover,
            else => .other,
        },
    };
}

/// Artwork is *observed* here, never decoded: enough to say a cover exists,
/// what type it claims to be, and how large it is. `readPicture` is the other
/// half, and both read the frame through `decodePicture`.
fn applyPicture(
    allocator: std.mem.Allocator,
    data: []const u8,
    tags: *model.ObservedTags,
) !void {
    const picture = decodePicture(data) orelse return;
    if (tags.artwork) |existing| {
        if (existing.kind == .front_cover or picture.kind != .front_cover) return;
    }
    tags.artwork = .{
        .mime_type = try id3v1.latin1ToUtf8(allocator, picture.mime),
        .byte_size = picture.data.len,
        .kind = picture.kind,
    };
}

/// Bytes consumed by a terminated string, including its terminator.
fn terminatorLength(encoding: u8, bytes: []const u8) ?usize {
    if (isWideEncoding(encoding)) {
        var index: usize = 0;
        while (index + 1 < bytes.len) : (index += 2) {
            if (bytes[index] == 0 and bytes[index + 1] == 0) return index + 2;
        }
        return bytes.len;
    }
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return bytes.len;
    return end + 1;
}

fn isWideEncoding(encoding: u8) bool {
    return encoding == 1 or encoding == 2;
}

/// Decode a text frame body: one encoding byte followed by one or more
/// terminator-separated values. Multi-value frames are legal in v2.4.
fn decodeTextValues(
    allocator: std.mem.Allocator,
    data: []const u8,
) !std.ArrayList([]const u8) {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer values.deinit(allocator);
    if (data.len == 0) return values;
    const encoding = data[0];
    if (encoding > 3) return error.InvalidId3v2Text;
    var rest = data[1..];
    if (rest.len > max_text_bytes) return error.InvalidId3v2Text;
    const step: usize = if (isWideEncoding(encoding)) 2 else 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index + step <= rest.len) : (index += step) {
        const terminated = if (step == 1)
            rest[index] == 0
        else
            rest[index] == 0 and rest[index + 1] == 0;
        if (!terminated) continue;
        try values.append(allocator, try decodeText(allocator, encoding, rest[start..index]));
        start = index + step;
    }
    if (start < rest.len)
        try values.append(allocator, try decodeText(allocator, encoding, rest[start..]));
    // A frame that is nothing but terminators still carries no values.
    while (values.items.len > 0 and values.items[values.items.len - 1].len == 0)
        _ = values.pop();
    return values;
}

fn decodeText(allocator: std.mem.Allocator, encoding: u8, bytes: []const u8) ![]const u8 {
    return switch (encoding) {
        0 => id3v1.latin1ToUtf8(allocator, bytes),
        1 => decodeUtf16(allocator, bytes, null),
        2 => decodeUtf16(allocator, bytes, .big),
        3 => blk: {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidId3v2Text;
            break :blk allocator.dupe(u8, bytes);
        },
        else => error.InvalidId3v2Text,
    };
}

/// UTF-16 text carries a BOM in encoding 1 and is big-endian in encoding 2.
/// A missing BOM is treated as little-endian, which is what the encoders that
/// omit it actually produce.
fn decodeUtf16(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    fixed: ?std.builtin.Endian,
) ![]const u8 {
    var rest = bytes;
    var endian = fixed orelse .little;
    if (fixed == null and rest.len >= 2) {
        if (rest[0] == 0xff and rest[1] == 0xfe) {
            endian = .little;
            rest = rest[2..];
        } else if (rest[0] == 0xfe and rest[1] == 0xff) {
            endian = .big;
            rest = rest[2..];
        }
    }
    if (rest.len % 2 != 0) return error.InvalidId3v2Text;
    const units = try allocator.alloc(u16, rest.len / 2);
    defer allocator.free(units);
    for (units, 0..) |*unit, index| {
        const value = std.mem.readInt(u16, rest[index * 2 ..][0..2], endian);
        unit.* = std.mem.nativeToLittle(u16, value);
    }
    return std.unicode.utf16LeToUtf8Alloc(allocator, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidId3v2Text,
    };
}

/// `TCON` may hold a name, a bare ID3v1 genre number, a parenthesized number,
/// or one of the two special codes. Only a name is returned.
fn canonicalGenre(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var text = std.mem.trim(u8, value, " ");
    if (text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')')
        text = text[1 .. text.len - 1];
    if (std.mem.eql(u8, text, "RX")) return allocator.dupe(u8, "Remix");
    if (std.mem.eql(u8, text, "CR")) return allocator.dupe(u8, "Cover");
    if (text.len != 0 and isAllDigits(text)) {
        const code = std.fmt.parseUnsigned(u8, text, 10) catch return allocator.dupe(u8, text);
        if (id3v1.genreName(code)) |name| return allocator.dupe(u8, name);
        return allocator.dupe(u8, "");
    }
    return allocator.dupe(u8, text);
}

fn isAllDigits(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// First frame wins: duplicate frames are common and a later one must not
/// silently replace an earlier value.
fn claim(field: *?[]const u8, value: []const u8) void {
    if (field.* != null or value.len == 0) return;
    field.* = value;
}

fn claimPair(value: []const u8, number: *?u32, total: *?u32) void {
    if (std.mem.indexOfScalar(u8, value, '/')) |split| {
        claimNumber(value[0..split], number);
        claimNumber(value[split + 1 ..], total);
        return;
    }
    claimNumber(value, number);
}

fn claimNumber(value: []const u8, field: *?u32) void {
    if (field.* != null) return;
    const trimmed = std.mem.trim(u8, value, " ");
    if (trimmed.len == 0) return;
    field.* = std.fmt.parseUnsigned(u32, trimmed, 10) catch null;
}

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn eqlAny(text: []const u8, spellings: []const []const u8) bool {
    for (spellings) |spelling| if (std.ascii.eqlIgnoreCase(text, spelling)) return true;
    return false;
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

/// Bytes of padding a rewritten tag carries, so another tagger can edit it in
/// place.
const write_padding: usize = 1024;

pub const WriteError = error{
    MetadataPreconditionChanged,
    UnsupportedId3Layout,
    InvalidTagValue,
    Id3v2TagTooLarge,
};

/// A replacement for an MPEG or ADTS stream's tags: the new leading tag, the
/// span of the original that is audio, and the trailer to end with.
pub const Rewrite = struct {
    allocator: std.mem.Allocator,
    tag: []u8,
    audio_start: u64,
    audio_end: u64,
    /// The ID3v1 trailer to write after the audio: the original one updated
    /// with the fields it can hold, or null when the file had none.
    trailer: ?[128]u8,

    pub fn deinit(self: Rewrite) void {
        self.allocator.free(self.tag);
    }
};

/// Plans a tag rewrite of the stream in `readable` for `changes`.
///
/// Each change's `before` must equal what the file currently says, read the
/// way the scanner reads it: the ID3v2 tag when it has values, the ID3v1
/// trailer otherwise. The tag keeps its version -- 2.3 stays 2.3, 2.4 stays
/// 2.4 -- and a stream with none gets 2.4. Only the frames for the changed
/// fields are replaced; every other frame is copied byte for byte.
///
/// `genres` replaces every `TCON` frame with one: its genres NUL-separated in
/// 2.4, and joined with `; ` in 2.3, which has no multi-value text frames. The
/// ID3v1 trailer's genre byte is left as it was.
pub fn rewrite(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
    changes: []const mutation.Change,
    genres: ?mutation.GenreChange,
) !Rewrite {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const loaded = try loadTag(scratch, readable);
    var header: [10]u8 = undefined;
    const has_header = try readExact(readable, 0, &header) == header.len and
        std.mem.eql(u8, header[0..3], "ID3");
    if (has_header and loaded == null) return error.UnsupportedId3Layout;
    if (loaded) |tag| {
        // Frame sizes under tag-level unsynchronization in 2.4 describe the
        // unsynchronized bytes, so its frames cannot be copied verbatim.
        if (tag.major == 4 and header[5] & 0x80 != 0) return error.UnsupportedId3Layout;
    }
    const major: u8 = if (loaded) |tag| tag.major else 4;

    const size = readable.size();
    var trailer_bytes: [128]u8 = undefined;
    const trailer = if (size >= 128 and try readExact(readable, size - 128, &trailer_bytes) == 128)
        id3v1.parse(&trailer_bytes)
    else
        null;

    const current = try currentTags(scratch, loaded, trailer);
    for (changes) |change| {
        if (change.before) |expected| {
            const value = try currentValue(scratch, current.tags, change.field) orelse
                return error.MetadataPreconditionChanged;
            if (!std.mem.eql(u8, expected, value)) return error.MetadataPreconditionChanged;
        }
        if (change.after) |value| {
            if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidTagValue;
        }
    }
    if (genres) |genre_change| {
        if (genre_change.before.len != current.tags.genres.len) return error.MetadataPreconditionChanged;
        for (genre_change.before, current.tags.genres) |expected, value| {
            if (!std.mem.eql(u8, expected, value)) return error.MetadataPreconditionChanged;
        }
        if (genre_change.after.len == 0) return error.InvalidTagValue;
        for (genre_change.after) |value| {
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null or
                !std.unicode.utf8ValidateSlice(value))
                return error.InvalidTagValue;
        }
    }

    var body: std.ArrayList(u8) = .empty;
    if (loaded) |tag| try copyUnchangedFrames(scratch, &body, tag, changes, genres != null);
    if (current.origin == .trailer) try appendTrailerFrames(scratch, &body, major, current.tags, changes, genres != null);
    for (changes) |change| {
        const value = change.after orelse continue;
        try appendChangedFrames(scratch, &body, major, change.field, value, current.tags);
    }
    if (genres) |genre_change| {
        const separator = if (major >= 4) "\x00" else "; ";
        try appendTextFrame(scratch, &body, major, "TCON", try std.mem.join(scratch, separator, genre_change.after));
    }
    try body.appendNTimes(scratch, 0, write_padding);
    if (body.items.len >= 1 << 28) return error.Id3v2TagTooLarge;

    const tag = try allocator.alloc(u8, 10 + body.items.len);
    errdefer allocator.free(tag);
    @memcpy(tag[0..3], "ID3");
    tag[3] = major;
    tag[4] = 0;
    tag[5] = 0;
    writeSyncsafe(tag[6..10], @intCast(body.items.len));
    @memcpy(tag[10..], body.items);

    return .{
        .allocator = allocator,
        .tag = tag,
        .audio_start = try prefixLength(readable),
        .audio_end = if (trailer != null) size - 128 else size,
        .trailer = if (trailer) |legacy| updatedTrailer(legacy, trailer_bytes, changes) else null,
    };
}

const CurrentTags = struct {
    tags: model.ObservedTags,
    origin: enum { id3v2, trailer, none },
};

fn currentTags(allocator: std.mem.Allocator, loaded: ?LoadedTag, trailer: ?id3v1.Tag) !CurrentTags {
    if (loaded) |tag| {
        const tags = try parseFrames(allocator, tag.span, tag.major);
        if (tags.hasValuesBesidesArtwork()) return .{ .tags = tags, .origin = .id3v2 };
    }
    const legacy = trailer orelse return .{ .tags = .{}, .origin = .none };
    var tags: model.ObservedTags = .{
        .title = if (legacy.title.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.title) else null,
        .artist = if (legacy.artist.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.artist) else null,
        .album = if (legacy.album.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.album) else null,
        .date = if (legacy.year.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.year) else null,
        .track_number = if (legacy.track_number) |number| (if (number != 0) number else null) else null,
    };
    if (id3v1.genreName(legacy.genre)) |name| tags.genres = try allocator.dupe([]const u8, &.{name});
    return .{ .tags = tags, .origin = .trailer };
}

/// A field's current value, as text in the form a `Change.before` states it.
fn currentValue(allocator: std.mem.Allocator, tags: model.ObservedTags, field: mutation.Field) !?[]const u8 {
    return switch (field) {
        .title => tags.title,
        .artist => tags.artist,
        .album => tags.album,
        .album_artist => tags.album_artist,
        .date => tags.date,
        .track_number => if (tags.track_number) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else null,
        .disc_number => if (tags.disc_number) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else null,
        .compilation => if (tags.compilation) |flag| (if (flag) "1" else "0") else null,
        .musicbrainz_recording_id => tags.musicbrainz_recording_id,
        .musicbrainz_release_id => tags.musicbrainz_release_id,
        .musicbrainz_release_group_id => tags.musicbrainz_release_group_id,
        .musicbrainz_release_track_id => tags.musicbrainz_release_track_id,
        .musicbrainz_album_artist_id => tags.musicbrainz_album_artist_id,
        .explicit => if (tags.explicit) |advisory| advisory.advisoryText() else null,
    };
}

/// The frames that carry `field` in `major`. v2.3 splits a date into a year
/// frame and a day-month frame, and both are replaced together.
fn fieldFrames(field: mutation.Field, major: u8) []const *const [4]u8 {
    return switch (field) {
        .title => &.{"TIT2"},
        .artist => &.{"TPE1"},
        .album => &.{"TALB"},
        .album_artist => &.{"TPE2"},
        .track_number => &.{"TRCK"},
        .disc_number => &.{"TPOS"},
        .compilation => &.{"TCMP"},
        .date => if (major >= 4) &.{"TDRC"} else &.{ "TYER", "TDAT", "TIME", "TRDA" },
        .musicbrainz_recording_id,
        .musicbrainz_release_id,
        .musicbrainz_release_group_id,
        .musicbrainz_release_track_id,
        .musicbrainz_album_artist_id,
        .explicit,
        => &.{},
    };
}

/// The `TXXX` descriptions the reader takes `field` from; a write uses the
/// first.
fn userTextDescriptions(field: mutation.Field) []const []const u8 {
    return switch (field) {
        .musicbrainz_recording_id => recording_id_descriptions,
        .musicbrainz_release_id => release_id_descriptions,
        .musicbrainz_release_group_id => release_group_id_descriptions,
        .musicbrainz_release_track_id => release_track_id_descriptions,
        .musicbrainz_album_artist_id => album_artist_id_descriptions,
        .explicit => advisory_descriptions,
        .title, .artist, .album, .track_number, .album_artist, .disc_number, .date, .compilation => &.{},
    };
}

/// Whether a change replaces `frame`. MusicBrainz IDs live in `TXXX` frames
/// under a description the reader accepts, and a recording ID also in a `UFID`
/// frame owned by MusicBrainz, so those two frame types are told apart by
/// description and owner, and every other description or owner is kept.
fn replaced(
    allocator: std.mem.Allocator,
    frame: []const u8,
    major: u8,
    changes: []const mutation.Change,
    replaces_genres: bool,
) !bool {
    const identifier = frame[0..4];
    if (replaces_genres and std.mem.eql(u8, identifier, "TCON")) return true;
    for (changes) |change| {
        for (fieldFrames(change.field, major)) |candidate| {
            if (std.mem.eql(u8, identifier, candidate)) return true;
        }
        if (try carriesUserText(allocator, frame, major, userTextDescriptions(change.field))) return true;
        if (change.field == .musicbrainz_recording_id and try carriesMusicBrainzUfid(allocator, frame, major))
            return true;
    }
    return false;
}

fn carriesMusicBrainzUfid(allocator: std.mem.Allocator, frame: []const u8, major: u8) !bool {
    if (!std.mem.eql(u8, frame[0..4], "UFID")) return false;
    const payload = try framePayload(allocator, frame, major) orelse return false;
    const split = std.mem.indexOfScalar(u8, payload, 0) orelse return false;
    return std.mem.eql(u8, payload[0..split], musicbrainz_ufid_owner);
}

fn carriesUserText(allocator: std.mem.Allocator, frame: []const u8, major: u8, descriptions: []const []const u8) !bool {
    if (descriptions.len == 0 or !std.mem.eql(u8, frame[0..4], "TXXX")) return false;
    const payload = try framePayload(allocator, frame, major) orelse return false;
    var values = decodeTextValues(allocator, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer values.deinit(allocator);
    if (values.items.len == 0) return false;
    return eqlAny(values.items[0], descriptions);
}

/// A whole frame's payload with the prefixes its format flags announce
/// removed, or null when it is compressed or encrypted. Per-frame
/// unsynchronization is undone on a copy, so the frame itself can still be
/// copied verbatim.
fn framePayload(allocator: std.mem.Allocator, frame: []const u8, major: u8) !?[]const u8 {
    const format_flags = frame[9];
    var data = frame[10..];
    if (major >= 4) {
        if (format_flags & 0x0c != 0) return null;
        if (format_flags & 0x40 != 0) data = if (data.len >= 1) data[1..] else return null;
        if (format_flags & 0x01 != 0) data = if (data.len >= 4) data[4..] else return null;
        if (format_flags & 0x02 != 0) return unsynchronize(try allocator.dupe(u8, data));
    } else {
        if (format_flags & 0xc0 != 0) return null;
        if (format_flags & 0x20 != 0) data = if (data.len >= 1) data[1..] else return null;
    }
    return data;
}

/// Every frame no change replaces, header and payload as they were.
fn copyUnchangedFrames(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    tag: LoadedTag,
    changes: []const mutation.Change,
    replaces_genres: bool,
) !void {
    var position: usize = 0;
    while (position + 10 <= tag.span.len) {
        const identifier = tag.span[position..][0..4];
        if (identifier[0] == 0 or !isFrameIdentifier(identifier)) break;
        const size_bytes = tag.span[position + 4 ..][0..4].*;
        const declared: usize = if (tag.major >= 4)
            try syncsafe(size_bytes)
        else
            std.mem.readInt(u32, &size_bytes, .big);
        if (declared > tag.span.len - position - 10) return error.TruncatedId3v2Tag;
        const frame = tag.span[position .. position + 10 + declared];
        position += frame.len;
        if (try replaced(allocator, frame, tag.major, changes, replaces_genres)) continue;
        try body.appendSlice(allocator, frame);
    }
}

fn appendTrailerFrames(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    major: u8,
    tags: model.ObservedTags,
    changes: []const mutation.Change,
    replaces_genres: bool,
) !void {
    for ([_]mutation.Field{ .title, .artist, .album, .date, .track_number }) |field| {
        if (changesField(changes, field)) continue;
        const value = try currentValue(allocator, tags, field) orelse continue;
        if (field == .date and major < 4)
            try appendTextFrame(allocator, body, major, "TYER", value)
        else
            try appendChangedFrames(allocator, body, major, field, value, tags);
    }
    if (replaces_genres) return;
    for (tags.genres) |genre| try appendTextFrame(allocator, body, major, "TCON", genre);
}

fn changesField(changes: []const mutation.Change, field: mutation.Field) bool {
    for (changes) |change| {
        if (change.field == field) return true;
    }
    return false;
}

fn appendChangedFrames(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    major: u8,
    field: mutation.Field,
    value: []const u8,
    current: model.ObservedTags,
) !void {
    switch (field) {
        .track_number => try appendTextFrame(allocator, body, major, "TRCK", try pair(allocator, value, current.track_total)),
        .disc_number => try appendTextFrame(allocator, body, major, "TPOS", try pair(allocator, value, current.disc_total)),
        .date => if (major >= 4) {
            try appendTextFrame(allocator, body, major, "TDRC", value);
        } else {
            // v2.3 holds a year, and optionally a DDMM day and month.
            if (value.len < 4 or !isAllDigits(value[0..4])) return error.InvalidTagValue;
            try appendTextFrame(allocator, body, major, "TYER", value[0..4]);
            if (value.len >= 10 and value[4] == '-' and value[7] == '-') {
                const day_month = [4]u8{ value[8], value[9], value[5], value[6] };
                if (isAllDigits(&day_month)) try appendTextFrame(allocator, body, major, "TDAT", &day_month);
            }
        },
        .title, .artist, .album, .album_artist, .compilation => try appendTextFrame(allocator, body, major, fieldFrames(field, major)[0], value),
        .musicbrainz_recording_id => try appendUniqueFileIdentifier(allocator, body, major, musicbrainz_ufid_owner, value),
        .musicbrainz_release_id,
        .musicbrainz_release_group_id,
        .musicbrainz_release_track_id,
        .musicbrainz_album_artist_id,
        .explicit,
        => try appendUserText(allocator, body, major, userTextDescriptions(field)[0], value),
    }
}

/// A `UFID` frame: the owner, a terminator, and the identifier's bytes, with
/// no encoding byte.
fn appendUniqueFileIdentifier(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    major: u8,
    owner: []const u8,
    identifier: []const u8,
) !void {
    if (identifier.len == 0 or identifier.len > 64) return error.InvalidTagValue;
    const payload = try std.mem.concat(allocator, u8, &.{ owner, "\x00", identifier });
    try appendFrame(allocator, body, major, "UFID", payload);
}

/// `n/total` when the file stated a total, so editing a track number does not
/// drop the album's track count.
fn pair(allocator: std.mem.Allocator, value: []const u8, total: ?u32) ![]const u8 {
    const count = total orelse return value;
    return std.fmt.allocPrint(allocator, "{s}/{d}", .{ value, count });
}

/// A text frame: UTF-8 in 2.4, UTF-16 with a byte-order mark in 2.3, which has
/// no UTF-8 encoding.
fn appendTextFrame(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    major: u8,
    identifier: *const [4]u8,
    value: []const u8,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    if (major >= 4) {
        try payload.append(allocator, 3);
        try payload.appendSlice(allocator, value);
    } else {
        try payload.append(allocator, 1);
        try appendUtf16(allocator, &payload, value);
    }
    try appendFrame(allocator, body, major, identifier, payload.items);
}

fn appendUserText(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    major: u8,
    description: []const u8,
    value: []const u8,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    if (major >= 4) {
        try payload.append(allocator, 3);
        try payload.appendSlice(allocator, description);
        try payload.append(allocator, 0);
        try payload.appendSlice(allocator, value);
    } else {
        try payload.append(allocator, 1);
        try appendUtf16(allocator, &payload, description);
        try payload.appendSlice(allocator, &.{ 0, 0 });
        try appendUtf16(allocator, &payload, value);
    }
    try appendFrame(allocator, body, major, "TXXX", payload.items);
}

fn appendUtf16(allocator: std.mem.Allocator, payload: *std.ArrayList(u8), text: []const u8) !void {
    try payload.appendSlice(allocator, &.{ 0xff, 0xfe });
    var units = (try std.unicode.Utf8View.init(text)).iterator();
    while (units.nextCodepoint()) |codepoint| {
        var encoded: [2]u16 = undefined;
        const count: usize = if (codepoint < 0x10000) blk: {
            encoded[0] = @intCast(codepoint);
            break :blk 1;
        } else blk: {
            const offset = codepoint - 0x10000;
            encoded[0] = @intCast(0xd800 + (offset >> 10));
            encoded[1] = @intCast(0xdc00 + (offset & 0x3ff));
            break :blk 2;
        };
        for (encoded[0..count]) |unit| {
            var little: [2]u8 = undefined;
            std.mem.writeInt(u16, &little, unit, .little);
            try payload.appendSlice(allocator, &little);
        }
    }
}

fn appendFrame(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    major: u8,
    identifier: *const [4]u8,
    payload: []const u8,
) !void {
    try body.appendSlice(allocator, identifier);
    var size: [4]u8 = undefined;
    if (major >= 4)
        writeSyncsafe(&size, @intCast(payload.len))
    else
        std.mem.writeInt(u32, &size, @intCast(payload.len), .big);
    try body.appendSlice(allocator, &size);
    try body.appendSlice(allocator, &.{ 0, 0 });
    try body.appendSlice(allocator, payload);
}

fn writeSyncsafe(destination: *[4]u8, value: u32) void {
    destination[0] = @intCast((value >> 21) & 0x7f);
    destination[1] = @intCast((value >> 14) & 0x7f);
    destination[2] = @intCast((value >> 7) & 0x7f);
    destination[3] = @intCast(value & 0x7f);
}

/// The ID3v1 trailer with the changes it can hold applied. When a new value
/// does not fit ID3v1 at all, the original trailer is kept: readers prefer the
/// ID3v2 tag, and a half-updated trailer would be worse than a stale one.
fn updatedTrailer(legacy: id3v1.Tag, original: [128]u8, changes: []const mutation.Change) [128]u8 {
    var tag = legacy;
    for (changes) |change| {
        const value = change.after orelse "";
        switch (change.field) {
            .title => tag.title = value,
            .artist => tag.artist = value,
            .album => tag.album = value,
            .date => tag.year = if (value.len >= 4) value[0..4] else value,
            .track_number => tag.track_number = if (change.after) |text|
                std.fmt.parseUnsigned(u8, text, 10) catch return original
            else
                null,
            .album_artist,
            .disc_number,
            .compilation,
            .musicbrainz_recording_id,
            .musicbrainz_release_id,
            .musicbrainz_release_group_id,
            .musicbrainz_release_track_id,
            .musicbrainz_album_artist_id,
            .explicit,
            => {},
        }
    }
    return id3v1.encode(tag) catch original;
}

fn expectTags(allocator: std.mem.Allocator, bytes: []const u8) !?model.ObservedTags {
    var memory = source.MemorySource{ .bytes = bytes };
    return read(allocator, memory.readable());
}

fn buildTag(
    allocator: std.mem.Allocator,
    major: u8,
    flags: u8,
    frames: []const u8,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "ID3");
    try bytes.appendSlice(allocator, &.{ major, 0, flags });
    var size: [4]u8 = undefined;
    const length: u32 = @intCast(frames.len);
    size[0] = @intCast((length >> 21) & 0x7f);
    size[1] = @intCast((length >> 14) & 0x7f);
    size[2] = @intCast((length >> 7) & 0x7f);
    size[3] = @intCast(length & 0x7f);
    try bytes.appendSlice(allocator, &size);
    try bytes.appendSlice(allocator, frames);
    return bytes.toOwnedSlice(allocator);
}

fn buildFrame(
    allocator: std.mem.Allocator,
    identifier: *const [4]u8,
    major: u8,
    payload: []const u8,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, identifier);
    var size: [4]u8 = undefined;
    const length: u32 = @intCast(payload.len);
    if (major >= 4) {
        size[0] = @intCast((length >> 21) & 0x7f);
        size[1] = @intCast((length >> 14) & 0x7f);
        size[2] = @intCast((length >> 7) & 0x7f);
        size[3] = @intCast(length & 0x7f);
    } else {
        std.mem.writeInt(u32, &size, length, .big);
    }
    try bytes.appendSlice(allocator, &size);
    try bytes.appendSlice(allocator, &.{ 0, 0 });
    try bytes.appendSlice(allocator, payload);
    return bytes.toOwnedSlice(allocator);
}

test "ID3v2.4 frames map onto canonical fields without leaking frame identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var frames: std.ArrayList(u8) = .empty;
    for ([_]struct { id: *const [4]u8, payload: []const u8 }{
        .{ .id = "TIT2", .payload = "\x03Reference Tone" },
        .{ .id = "TPE1", .payload = "\x03Orca Test" },
        .{ .id = "TPE2", .payload = "\x03Orca Ensemble" },
        .{ .id = "TALB", .payload = "\x03Fixtures" },
        .{ .id = "TRCK", .payload = "\x032/9" },
        .{ .id = "TPOS", .payload = "\x031/2" },
        .{ .id = "TDRC", .payload = "\x032026-08-23" },
        .{ .id = "TCMP", .payload = "\x031" },
        .{ .id = "TCON", .payload = "\x03Ambient\x00(9)" },
        .{ .id = "TXXX", .payload = "\x03MusicBrainz Album Id\x00release-uuid" },
    }) |frame| {
        const encoded = try buildFrame(allocator, frame.id, 4, frame.payload);
        try frames.appendSlice(allocator, encoded);
    }
    const tag = try buildTag(allocator, 4, 0, frames.items);
    const tags = (try expectTags(allocator, tag)).?;

    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.artist.?);
    try std.testing.expectEqualStrings("Orca Ensemble", tags.album_artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.album.?);
    try std.testing.expectEqual(@as(?u32, 2), tags.track_number);
    try std.testing.expectEqual(@as(?u32, 9), tags.track_total);
    try std.testing.expectEqual(@as(?u32, 1), tags.disc_number);
    try std.testing.expectEqual(@as(?u32, 2), tags.disc_total);
    try std.testing.expectEqualStrings("2026-08-23", tags.date.?);
    try std.testing.expectEqual(@as(?bool, true), tags.compilation);
    try std.testing.expectEqual(@as(usize, 2), tags.genres.len);
    try std.testing.expectEqualStrings("Ambient", tags.genres[0]);
    try std.testing.expectEqualStrings("Metal", tags.genres[1]);
    try std.testing.expectEqualStrings("release-uuid", tags.musicbrainz_release_id.?);
}

test "ID3v2.3 sizes, Latin-1 text, and split date frames read correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var frames: std.ArrayList(u8) = .empty;
    try frames.appendSlice(allocator, try buildFrame(allocator, "TIT2", 3, "\x00Caf\xe9"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "TYER", 3, "\x001999"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "TDAT", 3, "\x000112"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "TRCK", 3, "\x0007"));
    const tag = try buildTag(allocator, 3, 0, frames.items);
    const tags = (try expectTags(allocator, tag)).?;

    try std.testing.expectEqualStrings("Café", tags.title.?);
    try std.testing.expectEqualStrings("1999-12-01", tags.date.?);
    try std.testing.expectEqual(@as(?u32, 7), tags.track_number);
}

test "UTF-16 text frames decode from either byte order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var frames: std.ArrayList(u8) = .empty;
    try frames.appendSlice(allocator, try buildFrame(
        allocator,
        "TIT2",
        3,
        "\x01\xff\xfeS\x00o\x00l\x00",
    ));
    try frames.appendSlice(allocator, try buildFrame(
        allocator,
        "TPE1",
        3,
        "\x01\xfe\xff\x00M\x00o\x00o\x00n",
    ));
    try frames.appendSlice(allocator, try buildFrame(
        allocator,
        "TALB",
        4,
        "\x02\x00S\x00k\x00y",
    ));
    const tag = try buildTag(allocator, 4, 0, frames.items);
    const tags = (try expectTags(allocator, tag)).?;
    try std.testing.expectEqualStrings("Sol", tags.title.?);
    try std.testing.expectEqualStrings("Moon", tags.artist.?);
    try std.testing.expectEqualStrings("Sky", tags.album.?);
}

test "unsynchronized tags are restored before frames are parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const payload = "\x00\xff\xfeend";
    const frame = try buildFrame(allocator, "TIT2", 3, payload);
    var unsynced: std.ArrayList(u8) = .empty;
    for (frame) |byte| {
        try unsynced.append(allocator, byte);
        if (byte == 0xff) try unsynced.append(allocator, 0x00);
    }
    const tag = try buildTag(allocator, 3, 0x80, unsynced.items);
    const tags = (try expectTags(allocator, tag)).?;
    try std.testing.expectEqualStrings("ÿþend", tags.title.?);
}

test "extended headers are skipped in both supported versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const frame = try buildFrame(allocator, "TIT2", 3, "\x00After header");
    var v3: std.ArrayList(u8) = .empty;
    try v3.appendSlice(allocator, &.{ 0, 0, 0, 6, 0, 0, 0, 0, 0, 0 });
    try v3.appendSlice(allocator, frame);
    const v3_tags = (try expectTags(allocator, try buildTag(allocator, 3, 0x40, v3.items))).?;
    try std.testing.expectEqualStrings("After header", v3_tags.title.?);

    const v4_frame = try buildFrame(allocator, "TIT2", 4, "\x00After header");
    var v4: std.ArrayList(u8) = .empty;
    try v4.appendSlice(allocator, &.{ 0, 0, 0, 6, 1, 0 });
    try v4.appendSlice(allocator, v4_frame);
    const v4_tags = (try expectTags(allocator, try buildTag(allocator, 4, 0x40, v4.items))).?;
    try std.testing.expectEqualStrings("After header", v4_tags.title.?);
}

test "APIC artwork is reported by type and size without decoding image data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var payload: std.ArrayList(u8) = .empty;
    try payload.appendSlice(allocator, "\x00image/jpeg\x00");
    try payload.append(allocator, 3);
    try payload.appendSlice(allocator, "cover\x00");
    try payload.appendNTimes(allocator, 0x5a, 64);
    const frame = try buildFrame(allocator, "APIC", 4, payload.items);
    const tags = (try expectTags(allocator, try buildTag(allocator, 4, 0, frame))).?;

    try std.testing.expectEqualStrings("image/jpeg", tags.artwork.?.mime_type);
    try std.testing.expectEqual(@as(u64, 64), tags.artwork.?.byte_size);
    try std.testing.expectEqual(model.ArtworkKind.front_cover, tags.artwork.?.kind);
}

test "truncated and malformed ID3v2 tags are rejected without reading past the end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(try expectTags(allocator, "ID3") == null);
    try std.testing.expect(try expectTags(allocator, "no tag here at all") == null);
    // v2.2 is a real but unsupported version, not a parse failure.
    try std.testing.expect(try expectTags(
        allocator,
        "ID3\x02\x00\x00\x00\x00\x00\x0aTT2\x00\x00\x04\x00abc",
    ) == null);
    try std.testing.expectError(
        error.InvalidId3v2Tag,
        expectTags(allocator, "ID3\xff\x00\x00\x00\x00\x00\x0a"),
    );
    try std.testing.expectError(
        error.InvalidId3v2Tag,
        expectTags(allocator, "ID3\x04\x00\x00\x00\x00\x80\x0a"),
    );
    // Header declares more bytes than the stream holds.
    try std.testing.expectError(
        error.TruncatedId3v2Tag,
        expectTags(allocator, "ID3\x04\x00\x00\x00\x00\x01\x00short"),
    );
    // A frame declares more bytes than the tag holds.
    const frames = try buildFrame(allocator, "TIT2", 4, "\x03Title");
    frames[7] = 0x40;
    try std.testing.expectError(
        error.TruncatedId3v2Tag,
        expectTags(allocator, try buildTag(allocator, 4, 0, frames)),
    );
    // Trailing garbage after a valid frame keeps what was already read.
    var mixed: std.ArrayList(u8) = .empty;
    try mixed.appendSlice(allocator, try buildFrame(allocator, "TIT2", 4, "\x03Kept"));
    try mixed.appendSlice(allocator, "\xfe\xfe\xfe\xfe\x00\x00\x00\x02\x00\x00zz");
    const tags = (try expectTags(allocator, try buildTag(allocator, 4, 0, mixed.items))).?;
    try std.testing.expectEqualStrings("Kept", tags.title.?);
}

test "a tag declaring more bytes than the stream holds is rejected before any allocation" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.TruncatedId3v2Tag,
        expectTags(failing.allocator(), "ID3\x04\x00\x00\x01\x00\x00\x00short"),
    );
}

test "tagged MP3 fixture reads its real ID3v2 frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var file = try source.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.mp3",
    );
    defer file.close();
    const tags = (try read(allocator, file.readable())).?;
    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.album.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.track_number);
    try std.testing.expect(try prefixLength(file.readable()) > 10);
}

test "a TXXX ITUNESADVISORY of 1 marks an MP3 explicit, and a rewrite to 2 reads back clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = try readFixtureBytes("fixtures/audio/explicit-reference.mp3");
    defer std.testing.allocator.free(original);
    var memory = source.MemorySource{ .bytes = original };
    const tags = (try read(allocator, memory.readable())).?;
    try std.testing.expectEqual(@as(?model.Explicit, .explicit), tags.explicit);
    try std.testing.expectEqual(@as(?u32, 2), tags.track_total);

    const rewritten = try applyRewrite(allocator, original, &.{
        .{ .field = .explicit, .before = "1", .after = "2" },
    });
    var rewritten_memory = source.MemorySource{ .bytes = rewritten };
    const after = (try read(allocator, rewritten_memory.readable())).?;
    try std.testing.expectEqual(@as(?model.Explicit, .clean), after.explicit);
    try std.testing.expectEqualStrings("Explicit MP3", after.title.?);
}

/// Applies a planned rewrite to `original` in memory, as `stageMpeg` does on
/// disk, so the result can be read back.
fn applyRewrite(allocator: std.mem.Allocator, original: []const u8, changes: []const mutation.Change) ![]u8 {
    return applyGenreRewrite(allocator, original, changes, null);
}

fn applyGenreRewrite(
    allocator: std.mem.Allocator,
    original: []const u8,
    changes: []const mutation.Change,
    genres: ?mutation.GenreChange,
) ![]u8 {
    var memory = source.MemorySource{ .bytes = original };
    const planned = try rewrite(allocator, memory.readable(), changes, genres);
    defer planned.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, planned.tag);
    try out.appendSlice(allocator, original[@intCast(planned.audio_start)..@intCast(planned.audio_end)]);
    if (planned.trailer) |trailer| try out.appendSlice(allocator, &trailer);
    return out.toOwnedSlice(allocator);
}

fn readFixtureBytes(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
}

test "a rewritten ID3v2.4 tag carries the edit, keeps the cover and every other frame, and leaves the audio alone" {
    const original = try readFixtureBytes("fixtures/audio/covered-reference.mp3");
    defer std.testing.allocator.free(original);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = (try expectTags(arena.allocator(), original)).?;

    const written = try applyRewrite(std.testing.allocator, original, &.{
        .{ .field = .title, .before = before.title, .after = "Rewritten Title" },
        .{ .field = .album_artist, .before = before.album_artist, .after = "Rewritten Artist" },
    });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqual(@as(u8, 4), written[3]);
    const after = (try expectTags(arena.allocator(), written)).?;
    try std.testing.expectEqualStrings("Rewritten Title", after.title.?);
    try std.testing.expectEqualStrings("Rewritten Artist", after.album_artist.?);
    try std.testing.expectEqualDeep(before.artist, after.artist);
    try std.testing.expectEqualDeep(before.album, after.album);
    try std.testing.expectEqual(before.artwork.?.byte_size, after.artwork.?.byte_size);

    var original_memory = source.MemorySource{ .bytes = original };
    var written_memory = source.MemorySource{ .bytes = written };
    const original_audio = original[@intCast(try prefixLength(original_memory.readable()))..];
    const written_audio = written[@intCast(try prefixLength(written_memory.readable()))..];
    try std.testing.expectEqualSlices(u8, original_audio, written_audio);
}

test "an ID3v2.3 tag stays 2.3, with non-Latin text written as UTF-16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var frames: std.ArrayList(u8) = .empty;
    try frames.appendSlice(allocator, try buildFrame(allocator, "TIT2", 3, "\x00Old"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "TRCK", 3, "\x002/9"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "TYER", 3, "\x001999"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "TDAT", 3, "\x000101"));
    try frames.appendSlice(allocator, try buildFrame(allocator, "COMM", 3, "\x00engkept"));
    const tag = try buildTag(allocator, 3, 0, frames.items);
    const original = try std.mem.concat(allocator, u8, &.{ tag, "\xff\xfb\x90\x64audio" });

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .title, .before = "Old", .after = "Ωμέγα" },
        .{ .field = .track_number, .before = "2", .after = "5" },
        .{ .field = .date, .before = "1999-01-01", .after = "2024-03-15" },
    });
    try std.testing.expectEqual(@as(u8, 3), written[3]);
    const after = (try expectTags(allocator, written)).?;
    try std.testing.expectEqualStrings("Ωμέγα", after.title.?);
    try std.testing.expectEqual(@as(?u32, 5), after.track_number);
    try std.testing.expectEqual(@as(?u32, 9), after.track_total);
    try std.testing.expectEqualStrings("2024-03-15", after.date.?);
    try std.testing.expect(std.mem.indexOf(u8, written, "COMM") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\xff\xfb\x90\x64audio"));
}

test "a stream with no ID3v2 tag gets a 2.4 one, and its ID3v1 trailer is updated too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trailer = try id3v1.encode(.{
        .title = "Legacy",
        .artist = "Artist",
        .album = "Album",
        .year = "2001",
        .comment = "",
        .track_number = 1,
        .genre = 13,
    });
    const original = try std.mem.concat(allocator, u8, &.{ "\xff\xfb\x90\x64audio", &trailer });
    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .title, .before = "Legacy", .after = "Modern" },
    });
    try std.testing.expectEqual(@as(u8, 4), written[3]);
    try std.testing.expectEqualStrings("Modern", (try expectTags(allocator, written)).?.title.?);
    try std.testing.expectEqualStrings("Modern", id3v1.parse(written[written.len - 128 ..][0..128]).?.title);
    try std.testing.expect(std.mem.indexOf(u8, written, "\xff\xfb\x90\x64audio") != null);
}

test "a rewrite refuses a change whose before no longer matches the file" {
    const original = try readFixtureBytes("fixtures/audio/tagged-reference.mp3");
    defer std.testing.allocator.free(original);
    var memory = source.MemorySource{ .bytes = original };
    try std.testing.expectError(error.MetadataPreconditionChanged, rewrite(
        std.testing.allocator,
        memory.readable(),
        &.{.{ .field = .title, .before = "Not what the file says", .after = "New" }},
        null,
    ));
}

test "clearing a field removes its frame" {
    const original = try readFixtureBytes("fixtures/audio/tagged-reference.mp3");
    defer std.testing.allocator.free(original);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = (try expectTags(arena.allocator(), original)).?;
    const written = try applyRewrite(arena.allocator(), original, &.{
        .{ .field = .album, .before = before.album, .after = null },
    });
    const after = (try expectTags(arena.allocator(), written)).?;
    try std.testing.expect(after.album == null);
    try std.testing.expectEqualStrings(before.title.?, after.title.?);
}

fn expectRecordingIdRewrite(comptime major: u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_id = "11111111-2222-4333-8444-555555555555";
    const new_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    const legacy_description = if (major >= 4) "\x03MusicBrainz Track Id\x00" else "\x00MusicBrainz Track Id\x00";
    const foreign_ufid = try buildFrame(allocator, "UFID", major, "http://www.cddb.com/id3/taginfo1.html\x003CD3N42R04-1");
    const replay_gain = try buildFrame(allocator, "TXXX", major, "\x00REPLAYGAIN_TRACK_GAIN\x00-6.50 dB");
    const title = try buildFrame(allocator, "TIT2", major, "\x00Kept");
    var frames: std.ArrayList(u8) = .empty;
    try frames.appendSlice(allocator, title);
    try frames.appendSlice(allocator, foreign_ufid);
    try frames.appendSlice(allocator, try buildFrame(allocator, "TXXX", major, legacy_description ++ old_id));
    try frames.appendSlice(allocator, replay_gain);
    const original = try std.mem.concat(allocator, u8, &.{ try buildTag(allocator, major, 0, frames.items), "\xff\xfb\x90\x64audio" });
    try std.testing.expectEqualStrings(old_id, (try expectTags(allocator, original)).?.musicbrainz_recording_id.?);

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .musicbrainz_recording_id, .before = old_id, .after = new_id },
    });
    try std.testing.expectEqual(major, written[3]);
    const after = (try expectTags(allocator, written)).?;
    try std.testing.expectEqualStrings(new_id, after.musicbrainz_recording_id.?);
    try std.testing.expectEqualStrings("Kept", after.title.?);
    try std.testing.expect(std.mem.indexOf(u8, written, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, foreign_ufid) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, replay_gain) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "MusicBrainz Track Id") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, old_id) == null);
    const musicbrainz_ufid = try buildFrame(allocator, "UFID", major, "http://musicbrainz.org\x00" ++ new_id);
    try std.testing.expect(std.mem.indexOf(u8, written, musicbrainz_ufid) != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\xff\xfb\x90\x64audio"));
}

test "a recording id is written as a MusicBrainz UFID in 2.4, replacing the legacy TXXX and keeping other owners and descriptions" {
    try expectRecordingIdRewrite(4);
}

test "a recording id is written as a MusicBrainz UFID in 2.3, replacing the legacy TXXX and keeping other owners and descriptions" {
    try expectRecordingIdRewrite(3);
}

test "a recording id is added to a tag that had none, and an earlier MusicBrainz UFID is replaced" {
    const original = try readFixtureBytes("fixtures/audio/covered-reference.mp3");
    defer std.testing.allocator.free(original);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = (try expectTags(allocator, original)).?;
    try std.testing.expect(before.musicbrainz_recording_id == null);
    const first_id = "11111111-2222-4333-8444-555555555555";
    const second_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

    const first = try applyRewrite(allocator, original, &.{
        .{ .field = .musicbrainz_recording_id, .before = null, .after = first_id },
    });
    const once = (try expectTags(allocator, first)).?;
    try std.testing.expectEqualStrings(first_id, once.musicbrainz_recording_id.?);
    try std.testing.expectEqualDeep(before.title, once.title);
    try std.testing.expectEqual(before.artwork.?.byte_size, once.artwork.?.byte_size);

    const second = try applyRewrite(allocator, first, &.{
        .{ .field = .musicbrainz_recording_id, .before = first_id, .after = second_id },
    });
    try std.testing.expectEqualStrings(second_id, (try expectTags(allocator, second)).?.musicbrainz_recording_id.?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, "http://musicbrainz.org"));
}

fn expectGenreRewrite(comptime major: u8) !void {
    const genre_alias = @import("genre_alias.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const title = try buildFrame(allocator, "TIT2", major, "\x00Kept");
    var frames: std.ArrayList(u8) = .empty;
    try frames.appendSlice(allocator, try buildFrame(allocator, "TCON", major, "\x00(17)"));
    try frames.appendSlice(allocator, title);
    try frames.appendSlice(allocator, try buildFrame(allocator, "TCON", major, "\x00Indie Rock, Rock"));
    const original = try std.mem.concat(allocator, u8, &.{ try buildTag(allocator, major, 0, frames.items), "\xff\xfb\x90\x64audio" });
    const genres: mutation.GenreChange = .{
        .before = &.{ "Rock", "Indie Rock, Rock" },
        .after = &.{ "Shoegaze", "Dream Pop" },
    };

    const written = try applyGenreRewrite(allocator, original, &.{}, genres);
    try std.testing.expectEqual(major, written[3]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "TCON"));
    try std.testing.expect(std.mem.indexOf(u8, written, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Indie") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\xff\xfb\x90\x64audio"));
    const after = (try expectTags(allocator, written)).?;
    try std.testing.expectEqualStrings("Kept", after.title.?);
    if (major >= 4) {
        try std.testing.expectEqual(@as(usize, 2), after.genres.len);
        try std.testing.expectEqualStrings("Shoegaze", after.genres[0]);
        try std.testing.expectEqualStrings("Dream Pop", after.genres[1]);
    } else {
        try std.testing.expectEqual(@as(usize, 1), after.genres.len);
        try std.testing.expectEqualStrings("Shoegaze; Dream Pop", after.genres[0]);
    }
    const canonical = try genre_alias.foldAll(allocator, after.genres);
    try std.testing.expectEqual(@as(usize, 2), canonical.len);
    try std.testing.expectEqualStrings("Shoegaze", canonical[0].name);
    try std.testing.expectEqualStrings("Dream Pop", canonical[1].name);

    try std.testing.expectError(error.MetadataPreconditionChanged, applyGenreRewrite(allocator, original, &.{}, .{
        .before = &.{"Rock"},
        .after = &.{"Shoegaze"},
    }));
}

test "a genre write replaces every TCON frame with one holding each genre as a separate 2.4 value" {
    try expectGenreRewrite(4);
}

test "a genre write replaces every TCON frame with one semicolon list in 2.3, which canonicalisation splits" {
    try expectGenreRewrite(3);
}

test "a genre write to a trailer-only stream puts the genres in the new ID3v2 tag and leaves the trailer's genre byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{ "\xff\xfb\x90\x64audio", &trailer });

    const written = try applyGenreRewrite(allocator, original, &.{}, .{ .before = &.{"Rock"}, .after = &.{ "Jazz", "Blues" } });
    try std.testing.expectEqualSlices(u8, &trailer, written[written.len - 128 ..]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "TCON"));
    const after = (try expectTags(allocator, written)).?;
    try std.testing.expectEqualStrings("Song", after.title.?);
    try std.testing.expectEqualStrings("1999", after.date.?);
    try std.testing.expectEqual(@as(usize, 2), after.genres.len);
    try std.testing.expectEqualStrings("Jazz", after.genres[0]);
    try std.testing.expectEqualStrings("Blues", after.genres[1]);
}

fn legacyTrailer(year: []const u8) ![128]u8 {
    return id3v1.encode(.{
        .title = "Song",
        .artist = "Band",
        .album = "Record",
        .year = year,
        .comment = "",
        .track_number = 3,
        .genre = 17,
    });
}

fn expectTrailerValues(tags: model.ObservedTags, title: []const u8, year: []const u8) !void {
    try std.testing.expectEqualStrings(title, tags.title.?);
    try std.testing.expectEqualStrings("Band", tags.artist.?);
    try std.testing.expectEqualStrings("Record", tags.album.?);
    try std.testing.expectEqualStrings(year, tags.date.?);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_number);
    try std.testing.expectEqual(@as(usize, 1), tags.genres.len);
    try std.testing.expectEqualStrings("Rock", tags.genres[0]);
}

test "a recording id given to a trailer-only stream keeps every trailer value in the new ID3v2 tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{ "\xff\xfb\x90\x64audio", &trailer });
    const recording_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .musicbrainz_recording_id, .before = null, .after = recording_id },
    });
    try std.testing.expectEqual(@as(u8, 4), written[3]);
    const after = (try expectTags(allocator, written)).?;
    try expectTrailerValues(after, "Song", "1999");
    try std.testing.expectEqualStrings(recording_id, after.musicbrainz_recording_id.?);
    try std.testing.expectEqualSlices(u8, &trailer, written[written.len - 128 ..]);
}

test "a changed field overrides the trailer value while the other trailer values are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trailer = try legacyTrailer("99");
    const original = try std.mem.concat(allocator, u8, &.{ "\xff\xfb\x90\x64audio", &trailer });

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .title, .before = "Song", .after = "Anthem" },
    });
    const after = (try expectTags(allocator, written)).?;
    try expectTrailerValues(after, "Anthem", "99");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "TIT2"));
    try std.testing.expectEqualStrings("Anthem", id3v1.parse(written[written.len - 128 ..][0..128]).?.title);

    const cleared = try applyRewrite(allocator, original, &.{
        .{ .field = .artist, .before = "Band", .after = null },
    });
    try std.testing.expect((try expectTags(allocator, cleared)).?.artist == null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "TPE1") == null);
}

test "an ID3v2.3 tag holding only ReplayGain gains the trailer values in 2.3 form and keeps the ReplayGain frame byte for byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const replay_gain = try buildFrame(allocator, "TXXX", 3, "\x00REPLAYGAIN_TRACK_GAIN\x00-6.50 dB");
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{
        try buildTag(allocator, 3, 0, replay_gain),
        "\xff\xfb\x90\x64audio",
        &trailer,
    });

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .musicbrainz_recording_id, .before = null, .after = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a" },
    });
    try std.testing.expectEqual(@as(u8, 3), written[3]);
    try std.testing.expect(std.mem.indexOf(u8, written, replay_gain) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "TYER") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "TDRC") == null);
    try expectTrailerValues((try expectTags(allocator, written)).?, "Song", "1999");
}

test "an ID3v2 tag with values of its own gains nothing from the trailer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const title = try buildFrame(allocator, "TIT2", 4, "\x03Tagged");
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{
        try buildTag(allocator, 4, 0, title),
        "\xff\xfb\x90\x64audio",
        &trailer,
    });

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .album, .before = null, .after = "New Album" },
    });
    var expected_body: std.ArrayList(u8) = .empty;
    try expected_body.appendSlice(allocator, title);
    try appendTextFrame(allocator, &expected_body, 4, "TALB", "New Album");
    try expected_body.appendNTimes(allocator, 0, write_padding);
    try std.testing.expectEqualSlices(u8, expected_body.items, written[10 .. 10 + expected_body.items.len]);
    const after = (try expectTags(allocator, written)).?;
    try std.testing.expectEqualStrings("Tagged", after.title.?);
    try std.testing.expect(after.artist == null);
    try std.testing.expectEqual(@as(usize, 0), after.genres.len);
}

test "a recording id written to a cover-only ID3v2.3 tag keeps the cover byte for byte and gains the trailer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cover = try buildFrame(allocator, "APIC", 3, "\x00image/png\x00\x03\x00" ++ "\x5a" ** 32);
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{
        try buildTag(allocator, 3, 0, cover),
        "\xff\xfb\x90\x64audio",
        &trailer,
    });
    const before = (try expectTags(allocator, original)).?;
    try std.testing.expect(!before.hasValuesBesidesArtwork());
    const recording_id = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .musicbrainz_recording_id, .before = null, .after = recording_id },
    });
    try std.testing.expectEqual(@as(u8, 3), written[3]);
    try std.testing.expectEqualSlices(u8, cover, written[10 .. 10 + cover.len]);
    const after = (try expectTags(allocator, written)).?;
    try expectTrailerValues(after, "Song", "1999");
    try std.testing.expectEqualStrings(recording_id, after.musicbrainz_recording_id.?);
    try std.testing.expectEqual(@as(u64, 32), after.artwork.?.byte_size);
    try std.testing.expectEqualSlices(u8, &trailer, written[written.len - 128 ..]);
}

test "a title change to a cover-only ID3v2 tag is checked against the trailer title and keeps the other trailer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cover = try buildFrame(allocator, "APIC", 4, "\x00image/png\x00\x03\x00" ++ "\x5a" ** 32);
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{
        try buildTag(allocator, 4, 0, cover),
        "\xff\xfb\x90\x64audio",
        &trailer,
    });

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .title, .before = "Song", .after = "Anthem" },
    });
    try expectTrailerValues((try expectTags(allocator, written)).?, "Anthem", "1999");
}

fn countUserText(allocator: std.mem.Allocator, bytes: []const u8, descriptions: []const []const u8) !usize {
    var memory = source.MemorySource{ .bytes = bytes };
    const tag = try loadTag(allocator, memory.readable()) orelse return 0;
    defer tag.deinit();
    var frames: FrameIterator = .{ .body = tag.span, .major = tag.major };
    var count: usize = 0;
    while (try frames.next()) |frame| {
        if (!std.mem.eql(u8, &frame.identifier, "TXXX")) continue;
        var values = try decodeTextValues(allocator, frame.data);
        defer values.deinit(allocator);
        if (values.items.len > 0 and eqlAny(values.items[0], descriptions)) count += 1;
    }
    return count;
}

fn asciiUtf16Le(comptime ascii: []const u8) [ascii.len * 2]u8 {
    var bytes: [ascii.len * 2]u8 = undefined;
    for (ascii, 0..) |byte, index| bytes[index * 2 ..][0..2].* = .{ byte, 0 };
    return bytes;
}

fn expectedUserTextFrame(
    allocator: std.mem.Allocator,
    comptime major: u8,
    comptime description: []const u8,
    comptime value: []const u8,
) ![]u8 {
    const payload = comptime if (major >= 4)
        "\x03" ++ description ++ "\x00" ++ value
    else
        "\x01\xff\xfe" ++ asciiUtf16Le(description) ++ "\x00\x00\xff\xfe" ++ asciiUtf16Le(value);
    return buildFrame(allocator, "TXXX", major, payload);
}

const ReleaseIds = struct {
    release: []const u8,
    release_group: []const u8,
    release_track: []const u8,
    album_artist: []const u8,
};

const first_release_ids: ReleaseIds = .{
    .release = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a",
    .release_group = "0b6a3a3e-3b2c-4c8e-9a51-1f2d3c4b5a69",
    .release_track = "c2f7b3a4-5d6e-4f80-9a1b-2c3d4e5f6a7b",
    .album_artist = "d4e5f6a7-b8c9-4d0e-8f1a-2b3c4d5e6f70",
};

const second_release_ids: ReleaseIds = .{
    .release = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
    .release_group = "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e",
    .release_track = "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f",
    .album_artist = "4d5e6f7a-8b9c-4d0e-9f2a-3b4c5d6e7f80",
};

fn releaseIdChanges(before: ?ReleaseIds, after: ReleaseIds) [4]mutation.Change {
    return .{
        .{ .field = .musicbrainz_release_id, .before = if (before) |ids| ids.release else null, .after = after.release },
        .{ .field = .musicbrainz_release_group_id, .before = if (before) |ids| ids.release_group else null, .after = after.release_group },
        .{ .field = .musicbrainz_release_track_id, .before = if (before) |ids| ids.release_track else null, .after = after.release_track },
        .{ .field = .musicbrainz_album_artist_id, .before = if (before) |ids| ids.album_artist else null, .after = after.album_artist },
    };
}

fn expectReleaseIds(tags: model.ObservedTags, ids: ReleaseIds) !void {
    try std.testing.expectEqualStrings(ids.release, tags.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings(ids.release_group, tags.musicbrainz_release_group_id.?);
    try std.testing.expectEqualStrings(ids.release_track, tags.musicbrainz_release_track_id.?);
    try std.testing.expectEqualStrings(ids.album_artist, tags.musicbrainz_album_artist_id.?);
}

fn expectReleaseIdRewrite(comptime major: u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_id = "11111111-2222-4333-8444-555555555555";
    const new_id = first_release_ids.release;
    const release_group_id = first_release_ids.release_group;
    const recording_id = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const title = try buildFrame(allocator, "TIT2", major, "\x00Kept");
    const foreign_ufid = try buildFrame(allocator, "UFID", major, "http://www.cddb.com/id3/taginfo1.html\x003CD3N42R04-1");
    const release_group = try buildFrame(allocator, "TXXX", major, "\x00MusicBrainz Release Group Id\x00" ++ release_group_id);
    const recording = try buildFrame(allocator, "TXXX", major, "\x00MusicBrainz Track Id\x00" ++ recording_id);
    const replay_gain = try buildFrame(allocator, "TXXX", major, "\x00REPLAYGAIN_TRACK_GAIN\x00-6.50 dB");
    const cover = try buildFrame(allocator, "APIC", major, "\x00image/png\x00\x03\x00" ++ "\x5a" ** 32);
    var frames: std.ArrayList(u8) = .empty;
    try frames.appendSlice(allocator, title);
    try frames.appendSlice(allocator, foreign_ufid);
    try frames.appendSlice(allocator, release_group);
    try frames.appendSlice(allocator, try buildFrame(allocator, "TXXX", major, "\x00MUSICBRAINZ_ALBUMID\x00" ++ old_id));
    try frames.appendSlice(allocator, recording);
    try frames.appendSlice(allocator, replay_gain);
    try frames.appendSlice(allocator, cover);
    const original = try std.mem.concat(allocator, u8, &.{ try buildTag(allocator, major, 0, frames.items), "\xff\xfb\x90\x64audio" });
    try std.testing.expectEqualStrings(old_id, (try expectTags(allocator, original)).?.musicbrainz_release_id.?);

    const written = try applyRewrite(allocator, original, &.{
        .{ .field = .musicbrainz_release_id, .before = old_id, .after = new_id },
    });
    try std.testing.expectEqual(major, written[3]);
    for ([_][]const u8{ title, foreign_ufid, release_group, recording, replay_gain, cover }) |kept|
        try std.testing.expect(std.mem.indexOf(u8, written, kept) != null);
    const after = (try expectTags(allocator, written)).?;
    try std.testing.expectEqualStrings(new_id, after.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings(release_group_id, after.musicbrainz_release_group_id.?);
    try std.testing.expectEqualStrings(recording_id, after.musicbrainz_recording_id.?);
    try std.testing.expectEqualStrings("Kept", after.title.?);
    try std.testing.expectEqual(@as(u64, 32), after.artwork.?.byte_size);
    try std.testing.expect(std.mem.indexOf(u8, written, "MUSICBRAINZ_ALBUMID") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, old_id) == null);
    try std.testing.expectEqual(@as(usize, 1), try countUserText(allocator, written, release_id_descriptions));
    const expected = try expectedUserTextFrame(allocator, major, "MusicBrainz Album Id", first_release_ids.release);
    try std.testing.expect(std.mem.indexOf(u8, written, expected) != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\xff\xfb\x90\x64audio"));
}

test "a release id is written as Picard's TXXX in 2.4, replacing the uppercase spelling and keeping every other description, owner and cover" {
    try expectReleaseIdRewrite(4);
}

test "a release id is written as Picard's TXXX in 2.3, replacing the uppercase spelling and keeping every other description, owner and cover" {
    try expectReleaseIdRewrite(3);
}

fn expectEveryReleaseIdRoundTrips(comptime major: u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const title = try buildFrame(allocator, "TIT2", major, "\x00Kept");
    const original = try std.mem.concat(allocator, u8, &.{ try buildTag(allocator, major, 0, title), "\xff\xfb\x90\x64audio" });

    const first = try applyRewrite(allocator, original, &releaseIdChanges(null, first_release_ids));
    try std.testing.expectEqual(major, first[3]);
    const once = (try expectTags(allocator, first)).?;
    try expectReleaseIds(once, first_release_ids);
    try std.testing.expectEqualStrings("Kept", once.title.?);

    const second = try applyRewrite(allocator, first, &releaseIdChanges(first_release_ids, second_release_ids));
    try expectReleaseIds((try expectTags(allocator, second)).?, second_release_ids);
    for ([_][]const []const u8{
        release_id_descriptions,
        release_group_id_descriptions,
        release_track_id_descriptions,
        album_artist_id_descriptions,
    }) |descriptions| try std.testing.expectEqual(@as(usize, 1), try countUserText(allocator, second, descriptions));
    try std.testing.expect(std.mem.indexOf(u8, second, title) != null);
}

test "every release-level MusicBrainz id written to a 2.4 tag reads back, and writing it again replaces it" {
    try expectEveryReleaseIdRoundTrips(4);
}

test "every release-level MusicBrainz id written to a 2.3 tag reads back, and writing it again replaces it" {
    try expectEveryReleaseIdRoundTrips(3);
}

test "release ids written to a cover-only ID3v2.3 tag keep the cover and ReplayGain byte for byte and gain the trailer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cover = try buildFrame(allocator, "APIC", 3, "\x00image/png\x00\x03\x00" ++ "\x5a" ** 32);
    const replay_gain = try buildFrame(allocator, "TXXX", 3, "\x00REPLAYGAIN_TRACK_GAIN\x00-6.50 dB");
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{
        try buildTag(allocator, 3, 0, try std.mem.concat(allocator, u8, &.{ cover, replay_gain })),
        "\xff\xfb\x90\x64audio",
        &trailer,
    });
    try std.testing.expect(!(try expectTags(allocator, original)).?.hasValuesBesidesArtwork());

    const written = try applyRewrite(allocator, original, &releaseIdChanges(null, first_release_ids));
    try std.testing.expectEqual(@as(u8, 3), written[3]);
    try std.testing.expectEqualSlices(u8, cover, written[10 .. 10 + cover.len]);
    try std.testing.expectEqualSlices(u8, replay_gain, written[10 + cover.len .. 10 + cover.len + replay_gain.len]);
    const after = (try expectTags(allocator, written)).?;
    try expectTrailerValues(after, "Song", "1999");
    try expectReleaseIds(after, first_release_ids);
    try std.testing.expectEqual(@as(u64, 32), after.artwork.?.byte_size);
    try std.testing.expectEqualSlices(u8, &trailer, written[written.len - 128 ..]);
}

test "release ids given to a trailer-only stream keep every trailer value in the new ID3v2 tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trailer = try legacyTrailer("1999");
    const original = try std.mem.concat(allocator, u8, &.{ "\xff\xfb\x90\x64audio", &trailer });

    const written = try applyRewrite(allocator, original, &releaseIdChanges(null, first_release_ids));
    try std.testing.expectEqual(@as(u8, 4), written[3]);
    const after = (try expectTags(allocator, written)).?;
    try expectTrailerValues(after, "Song", "1999");
    try expectReleaseIds(after, first_release_ids);
    try std.testing.expectEqualSlices(u8, &trailer, written[written.len - 128 ..]);
}

fn readLyricsFrom(arena: *std.heap.ArenaAllocator, frames: []const []const u8) !?lyrics.Content {
    const allocator = arena.allocator();
    const body = try std.mem.concat(allocator, u8, frames);
    const tag = try buildTag(allocator, 4, 0, body);
    var memory = source.MemorySource{ .bytes = tag };
    return readLyrics(std.testing.allocator, allocator, memory.readable());
}

test "a SYLT frame of millisecond lyrics is synced and wins over USLT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const unsynced = try buildFrame(allocator, "USLT", 4, "\x03engDesc\x00Plain words");
    const synced = try buildFrame(allocator, "SYLT", 4, "\x03eng\x02\x01\x00" ++
        "\nSecond\x00\x00\x00\x07\xd0" ++ "First\x00\x00\x00\x03\xe8");
    const content = (try readLyricsFrom(&arena, &.{ unsynced, synced })).?;
    try std.testing.expectEqual(lyrics.Kind.synced, content.kind);
    try std.testing.expectEqualStrings("eng", &content.language.?);
    try std.testing.expectEqual(@as(usize, 2), content.lines.len);
    try std.testing.expectEqual(@as(?u32, 1000), content.lines[0].start_ms);
    try std.testing.expectEqualStrings("First", content.lines[0].text);
    try std.testing.expectEqualStrings("Second", content.lines[1].text);
}

test "a SYLT frame timed in MPEG frames is passed over for USLT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const frames = try buildFrame(allocator, "SYLT", 4, "\x03eng\x01\x01\x00Line\x00\x00\x00\x00\x10");
    const unsynced = try buildFrame(allocator, "USLT", 4, "\x03XXX\x00Plain words");
    const content = (try readLyricsFrom(&arena, &.{ frames, unsynced })).?;
    try std.testing.expectEqual(lyrics.Kind.plain, content.kind);
    try std.testing.expectEqual(@as(?[3]u8, null), content.language);
    try std.testing.expectEqualStrings("Plain words", content.lines[0].text);
}

test "a SYLT frame of another content type is passed over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const chords = try buildFrame(allocator, "SYLT", 4, "\x03eng\x02\x05\x00Am\x00\x00\x00\x00\x10");
    try std.testing.expect(try readLyricsFrom(&arena, &.{chords}) == null);
}

test "a UTF-16 USLT with a byte order mark decodes, LRC included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const frame = try buildFrame(allocator, "USLT", 3, "\x01deu\xff\xfe\x00\x00" ++
        "\xff\xfe[\x000\x000\x00:\x000\x002\x00]\x00G\x00r\x00\xfc\x00\xdf\x00e\x00\x00\x00");
    const content = (try readLyricsFrom(&arena, &.{frame})).?;
    try std.testing.expectEqual(lyrics.Kind.synced, content.kind);
    try std.testing.expectEqualStrings("deu", &content.language.?);
    try std.testing.expectEqual(@as(?u32, 2000), content.lines[0].start_ms);
    try std.testing.expectEqualStrings("Grüße", content.lines[0].text);
}

test "an empty USLT is ignored and the first USLT with text wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = try buildFrame(allocator, "USLT", 4, "\x03eng\x00");
    const blank = try buildFrame(allocator, "USLT", 4, "\x03eng\x00\n\n");
    const first = try buildFrame(allocator, "USLT", 4, "\x03eng\x00First text");
    const second = try buildFrame(allocator, "USLT", 4, "\x03eng\x00Second text");
    const content = (try readLyricsFrom(&arena, &.{ empty, blank, first, second })).?;
    try std.testing.expectEqualStrings("First text", content.lines[0].text);
}

test "a truncated SYLT reads as no lyrics without failing the tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const broken = try buildFrame(allocator, "SYLT", 4, "\x03eng\x02\x01\x00Line\x00\x00\x00");
    try std.testing.expect(try readLyricsFrom(&arena, &.{broken}) == null);
}
