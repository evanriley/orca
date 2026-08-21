pub const model = @import("model.zig");
pub const musicbrainz = @import("musicbrainz.zig");
pub const scoring = @import("scoring.zig");

pub const Candidate = model.Candidate;
pub const CandidateList = model.CandidateList;
pub const Provider = model.Provider;
pub const Query = model.Query;

test {
    _ = @import("model.zig");
    _ = @import("musicbrainz.zig");
    _ = @import("scoring.zig");
}
