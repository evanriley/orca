pub const artwork = @import("artwork.zig");
pub const id3v1 = @import("id3v1.zig");
pub const id3v2 = @import("id3v2.zig");
pub const file_mutation = @import("file_mutation.zig");
pub const executor = @import("executor.zig");
pub const model = @import("model.zig");
pub const mp4_tags = @import("mp4_tags.zig");
pub const mutation = @import("mutation.zig");
pub const ogg_comment = @import("ogg_comment.zig");
pub const recovery = @import("recovery.zig");
pub const riff_tags = @import("riff_tags.zig");
pub const vorbis_comment = @import("vorbis_comment.zig");

pub const EffectiveMetadata = model.EffectiveMetadata;
pub const ObservedFileMetadata = model.ObservedFileMetadata;
pub const ObservedTags = model.ObservedTags;
pub const Artwork = model.Artwork;
pub const EmbeddedImage = model.EmbeddedImage;
pub const ArtworkKind = model.ArtworkKind;
pub const OrcaMetadata = model.OrcaMetadata;
pub const ResolutionPolicy = model.ResolutionPolicy;
pub const Provenance = model.Provenance;
pub const Field = model.Field;
pub const Value = model.Value;
pub const resolve = model.resolve;

test {
    _ = @import("artwork.zig");
    _ = @import("id3v1.zig");
    _ = @import("id3v2.zig");
    _ = @import("file_mutation.zig");
    _ = @import("executor.zig");
    _ = @import("model.zig");
    _ = @import("mp4_tags.zig");
    _ = @import("mutation.zig");
    _ = @import("ogg_comment.zig");
    _ = @import("recovery.zig");
    _ = @import("riff_tags.zig");
    _ = @import("vorbis_comment.zig");
}
