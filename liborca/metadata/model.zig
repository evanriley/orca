const std = @import("std");

pub const Provenance = enum {
    observed_file,
    user,
    provider,
    inference,
    analysis,
};

pub const Field = enum {
    title,
    artist,
    album,
    track_number,
};

pub const Value = struct {
    text: []const u8,
    provenance: Provenance,
    locked: bool = false,
};

pub const ObservedFileMetadata = struct {
    title: ?Value = null,
    artist: ?Value = null,
    album: ?Value = null,
};

pub const OrcaMetadata = struct {
    title: ?Value = null,
    artist: ?Value = null,
    album: ?Value = null,
};

pub const ResolutionPolicy = enum {
    prefer_file,
    prefer_orca,
};

pub const EffectiveMetadata = struct {
    title: ?Value,
    artist: ?Value,
    album: ?Value,
};

pub fn resolve(
    observed: ObservedFileMetadata,
    orca: OrcaMetadata,
    policy: ResolutionPolicy,
) EffectiveMetadata {
    return .{
        .title = resolveValue(observed.title, orca.title, policy),
        .artist = resolveValue(observed.artist, orca.artist, policy),
        .album = resolveValue(observed.album, orca.album, policy),
    };
}

fn resolveValue(observed: ?Value, orca: ?Value, policy: ResolutionPolicy) ?Value {
    if (orca) |value| if (value.locked) return value;
    return switch (policy) {
        .prefer_file => observed orelse orca,
        .prefer_orca => orca orelse observed,
    };
}

test "locked user values outrank file preference" {
    const effective = resolve(
        .{ .title = .{ .text = "File title", .provenance = .observed_file } },
        .{ .title = .{ .text = "User title", .provenance = .user, .locked = true } },
        .prefer_file,
    );
    try std.testing.expectEqualStrings("User title", effective.title.?.text);
    try std.testing.expectEqual(Provenance.user, effective.title.?.provenance);
}

/// Cover art is described, never carried, by an *observation*: a scan reports
/// enough for a caller to decide whether to fetch the bytes, and the image
/// payload stays in the file until somebody asks for it. `EmbeddedImage` below
/// is the answer to that ask, and it is a separate type on purpose — one says
/// "this file claims a 216 KB JPEG", the other is 216 KB of JPEG.
pub const ArtworkKind = enum {
    front_cover,
    back_cover,
    other,
};

pub const Artwork = struct {
    mime_type: []const u8,
    byte_size: u64,
    kind: ArtworkKind = .other,
};

/// The largest embedded image Orca will read into memory.
///
/// The whole image is held at once — there is no partial cover, and a decoder
/// cannot be handed half a JPEG — so this is the allocation the bound is
/// protecting, and it is checked against the length a container *declares*,
/// before anything is allocated to honour the claim.
///
/// 12 MiB is chosen to sit below both containers' own ceilings and above every
/// honest cover. A FLAC `PICTURE` block carries a 24-bit length and
/// `id3v2.max_tag_bytes` refuses a tag past 16 MiB, so a bound at 16 MiB would
/// be unreachable — an enforcement that can never fire is not one. Measured
/// against the 22,060-file reference library, the largest embedded cover is
/// 11.29 MiB, the median is 157 KB, 148 files exceed 4 MiB and 28 exceed
/// 8 MiB. A claim past this is refused rather than grown into.
pub const max_image_bytes: usize = 12 << 20;

pub const ArtworkReadError = error{
    ArtworkTooLarge,
    TruncatedArtwork,
    UnrecognizedArtworkImage,
};

/// One embedded cover image, owned by the caller.
///
/// `mime_type` is resolved from the bytes rather than from what the container
/// claimed, and it is a static string rather than an allocation. The claim is
/// not reliable enough to hand a decoder: 93 files in the reference library
/// declare `image/jpg`, which is not a media type, and 24 declare nothing at
/// all. What the file *says* is an observation and stays in `Artwork`; what the
/// bytes *are* is this.
pub const EmbeddedImage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    /// Borrowed from `sniffImageMimeType`'s static table; never freed.
    mime_type: []const u8,
    kind: ArtworkKind,

    pub fn deinit(self: EmbeddedImage) void {
        self.allocator.free(self.bytes);
    }
};

/// Adopt an already-allocated payload as a cover image, or reject it.
///
/// Ownership transfers only on success. A rejection leaves the buffer to the
/// caller, whose `errdefer` already covers it — freeing here as well is a
/// double free, which is exactly what the first version of this did.
pub fn adoptImage(
    allocator: std.mem.Allocator,
    bytes: []u8,
    kind: ArtworkKind,
) ArtworkReadError!EmbeddedImage {
    if (bytes.len > max_image_bytes) return error.ArtworkTooLarge;
    const mime_type = sniffImageMimeType(bytes) orelse return error.UnrecognizedArtworkImage;
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .mime_type = mime_type,
        .kind = kind,
    };
}

/// The image encodings a cover can honestly be, recognised by magic bytes.
///
/// Deliberately a short list. An embedded cover that is none of these is not a
/// cover Orca can display, and the caller learns that here rather than by
/// handing arbitrary bytes to a platform image decoder.
pub fn sniffImageMimeType(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or
        std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (std.mem.startsWith(u8, bytes, "BM")) return "image/bmp";
    return null;
}

test "cover images are typed by their bytes rather than by what a tag claimed" {
    try std.testing.expectEqualStrings("image/png", sniffImageMimeType("\x89PNG\r\n\x1a\n\x00").?);
    try std.testing.expectEqualStrings("image/jpeg", sniffImageMimeType("\xff\xd8\xff\xe0").?);
    try std.testing.expectEqualStrings("image/webp", sniffImageMimeType("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expect(sniffImageMimeType("RIFF\x00\x00\x00\x00WAVEfmt ") == null);
    try std.testing.expect(sniffImageMimeType("not an image") == null);
    try std.testing.expect(sniffImageMimeType("") == null);
}

/// The canonical result of reading one source file's tags.
///
/// Format readers map onto this and nothing else: ID3 frame identifiers, ID3v1
/// genre numbers, Vorbis comment key spellings, alias sets, text encodings, and
/// multi-value conventions all terminate at the reader that understands them.
/// Absent fields are normal — real libraries contain files missing any of them.
///
/// Text is UTF-8. String lifetimes belong to whatever allocator the reader was
/// given; readers are documented to expect an arena.
pub const ObservedTags = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    track_number: ?u32 = null,
    track_total: ?u32 = null,
    disc_number: ?u32 = null,
    disc_total: ?u32 = null,
    /// Release date as the file states it, normalized to `YYYY`, `YYYY-MM`, or
    /// `YYYY-MM-DD` where the source is precise enough.
    date: ?[]const u8 = null,
    original_date: ?[]const u8 = null,
    /// Multi-valued in every container Orca reads, so it is a list here.
    genres: []const []const u8 = &.{},
    compilation: ?bool = null,
    label: ?[]const u8 = null,
    media: ?[]const u8 = null,
    isrc: ?[]const u8 = null,
    release_country: ?[]const u8 = null,
    release_type: ?[]const u8 = null,
    release_status: ?[]const u8 = null,
    musicbrainz_recording_id: ?[]const u8 = null,
    musicbrainz_release_id: ?[]const u8 = null,
    musicbrainz_release_group_id: ?[]const u8 = null,
    musicbrainz_release_track_id: ?[]const u8 = null,
    musicbrainz_artist_id: ?[]const u8 = null,
    musicbrainz_album_artist_id: ?[]const u8 = null,
    artwork: ?Artwork = null,

    pub fn isEmpty(self: ObservedTags) bool {
        if (self.genres.len != 0) return false;
        const info = @typeInfo(ObservedTags).@"struct";
        inline for (info.fields) |field| {
            if (@typeInfo(field.type) == .optional and @field(self, field.name) != null)
                return false;
        }
        return true;
    }

    /// Project the resolution-participating subset onto the layered model.
    pub fn observedFileMetadata(self: ObservedTags) ObservedFileMetadata {
        return .{
            .title = observedValue(self.title),
            .artist = observedValue(self.artist),
            .album = observedValue(self.album),
        };
    }
};

fn observedValue(text: ?[]const u8) ?Value {
    const present = text orelse return null;
    if (present.len == 0) return null;
    return .{ .text = present, .provenance = .observed_file };
}

test "observed tags project onto the layered metadata model with file provenance" {
    const tags = ObservedTags{
        .title = "Reference Tone",
        .artist = "Orca Test",
        .album = "",
        .track_number = 1,
    };
    const observed = tags.observedFileMetadata();
    try std.testing.expectEqualStrings("Reference Tone", observed.title.?.text);
    try std.testing.expectEqual(Provenance.observed_file, observed.artist.?.provenance);
    try std.testing.expect(observed.album == null);
    try std.testing.expect(!tags.isEmpty());
    try std.testing.expect((ObservedTags{}).isEmpty());
}
