const std = @import("std");
const id3v1 = @import("id3v1.zig");
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
    if (eqlAny(description, &.{ "MusicBrainz Track Id", "MUSICBRAINZ_TRACKID" }))
        return claim(&tags.musicbrainz_recording_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Album Id", "MUSICBRAINZ_ALBUMID" }))
        return claim(&tags.musicbrainz_release_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Release Group Id", "MUSICBRAINZ_RELEASEGROUPID" }))
        return claim(&tags.musicbrainz_release_group_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Release Track Id", "MUSICBRAINZ_RELEASETRACKID" }))
        return claim(&tags.musicbrainz_release_track_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Artist Id", "MUSICBRAINZ_ARTISTID" }))
        return claim(&tags.musicbrainz_artist_id, value);
    if (eqlAny(description, &.{ "MusicBrainz Album Artist Id", "MUSICBRAINZ_ALBUMARTISTID" }))
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
}

fn applyUniqueFileIdentifier(
    allocator: std.mem.Allocator,
    data: []const u8,
    tags: *model.ObservedTags,
) !void {
    const split = std.mem.indexOfScalar(u8, data, 0) orelse return;
    const owner = data[0..split];
    if (!std.mem.eql(u8, owner, "http://musicbrainz.org")) return;
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
pub fn rewrite(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
    changes: []const mutation.Change,
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
        if (!change.field.writesToFiles()) return error.UnwritableMetadataField;
        if (change.before) |expected| {
            const value = try currentValue(scratch, current, change.field) orelse
                return error.MetadataPreconditionChanged;
            if (!std.mem.eql(u8, expected, value)) return error.MetadataPreconditionChanged;
        }
        if (change.after) |value| {
            if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidTagValue;
        }
    }

    var body: std.ArrayList(u8) = .empty;
    if (loaded) |tag| try copyUnchangedFrames(scratch, &body, tag, changes);
    for (changes) |change| {
        const value = change.after orelse continue;
        try appendChangedFrames(scratch, &body, major, change.field, value, current);
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

fn currentTags(allocator: std.mem.Allocator, loaded: ?LoadedTag, trailer: ?id3v1.Tag) !model.ObservedTags {
    if (loaded) |tag| {
        const tags = try parseFrames(allocator, tag.span, tag.major);
        if (!tags.isEmpty()) return tags;
    }
    const legacy = trailer orelse return .{};
    return .{
        .title = if (legacy.title.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.title) else null,
        .artist = if (legacy.artist.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.artist) else null,
        .album = if (legacy.album.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.album) else null,
        .date = if (legacy.year.len != 0) try id3v1.latin1ToUtf8(allocator, legacy.year) else null,
        .track_number = if (legacy.track_number) |number| number else null,
    };
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
        .musicbrainz_recording_id => &.{},
    };
}

fn replaced(identifier: *const [4]u8, major: u8, changes: []const mutation.Change) bool {
    for (changes) |change| {
        for (fieldFrames(change.field, major)) |frame| {
            if (std.mem.eql(u8, identifier, frame)) return true;
        }
    }
    return false;
}

/// Every frame no change replaces, header and payload as they were.
fn copyUnchangedFrames(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    tag: LoadedTag,
    changes: []const mutation.Change,
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
        if (replaced(identifier, tag.major, changes)) continue;
        try body.appendSlice(allocator, frame);
    }
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
        else => try appendTextFrame(allocator, body, major, fieldFrames(field, major)[0], value),
    }
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
        try payload.appendSlice(allocator, &.{ 1, 0xff, 0xfe });
        var units = (try std.unicode.Utf8View.init(value)).iterator();
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
    try body.appendSlice(allocator, identifier);
    var size: [4]u8 = undefined;
    if (major >= 4)
        writeSyncsafe(&size, @intCast(payload.items.len))
    else
        std.mem.writeInt(u32, &size, @intCast(payload.items.len), .big);
    try body.appendSlice(allocator, &size);
    try body.appendSlice(allocator, &.{ 0, 0 });
    try body.appendSlice(allocator, payload.items);
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
            .album_artist, .disc_number, .compilation, .musicbrainz_recording_id => {},
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

/// Applies a planned rewrite to `original` in memory, as `stageMpeg` does on
/// disk, so the result can be read back.
fn applyRewrite(allocator: std.mem.Allocator, original: []const u8, changes: []const mutation.Change) ![]u8 {
    var memory = source.MemorySource{ .bytes = original };
    const planned = try rewrite(allocator, memory.readable(), changes);
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
