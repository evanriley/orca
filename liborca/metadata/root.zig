pub const id3v1 = @import("id3v1.zig");
pub const file_mutation = @import("file_mutation.zig");
pub const model = @import("model.zig");
pub const mutation = @import("mutation.zig");

pub const EffectiveMetadata = model.EffectiveMetadata;
pub const ObservedFileMetadata = model.ObservedFileMetadata;
pub const OrcaMetadata = model.OrcaMetadata;
pub const ResolutionPolicy = model.ResolutionPolicy;

test {
    _ = @import("id3v1.zig");
    _ = @import("file_mutation.zig");
    _ = @import("model.zig");
    _ = @import("mutation.zig");
}
