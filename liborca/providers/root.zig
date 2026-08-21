pub const acoustid = @import("acoustid.zig");
pub const credentials = @import("credentials.zig");
pub const model = @import("model.zig");
pub const musicbrainz = @import("musicbrainz.zig");
pub const scoring = @import("scoring.zig");
pub const scrobble = @import("scrobble.zig");

pub const Candidate = model.Candidate;
pub const CandidateList = model.CandidateList;
pub const Provider = model.Provider;
pub const Query = model.Query;

test {
    _ = @import("acoustid.zig");
    _ = @import("credentials.zig");
    _ = @import("model.zig");
    _ = @import("musicbrainz.zig");
    _ = @import("scoring.zig");
    _ = @import("scrobble.zig");
}
