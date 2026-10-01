pub const acoustid = @import("acoustid.zig");
pub const coverartarchive = @import("coverartarchive.zig");
pub const credentials = @import("credentials.zig");
pub const listenbrainz = @import("listenbrainz.zig");
pub const listens = @import("listens.zig");
pub const model = @import("model.zig");
pub const musicbrainz = @import("musicbrainz.zig");
pub const scoring = @import("scoring.zig");
pub const scrobble = @import("scrobble.zig");
pub const shared_state = @import("shared_state.zig");
pub const url = @import("url.zig");
pub const workflow = @import("workflow.zig");

pub const Candidate = model.Candidate;
pub const CandidateList = model.CandidateList;
pub const Provider = model.Provider;
pub const Query = model.Query;

test {
    _ = @import("acoustid.zig");
    _ = @import("coverartarchive.zig");
    _ = @import("credentials.zig");
    _ = @import("listenbrainz.zig");
    _ = @import("listens.zig");
    _ = @import("model.zig");
    _ = @import("musicbrainz.zig");
    _ = @import("scoring.zig");
    _ = @import("scrobble.zig");
    _ = @import("shared_state.zig");
    _ = @import("url.zig");
    _ = @import("workflow.zig");
}
