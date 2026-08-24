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

/// Cover art is described, never carried: readers report enough for a caller to
/// decide whether to fetch the bytes, and image payloads stay in the file.
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
        inline for (info.field_names, info.field_types) |name, Field_| {
            if (@typeInfo(Field_) == .optional and @field(self, name) != null)
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
