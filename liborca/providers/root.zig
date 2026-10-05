pub const acoustid = @import("acoustid.zig");
pub const cached_get = @import("cached_get.zig");
pub const coverartarchive = @import("coverartarchive.zig");
pub const credentials = @import("credentials.zig");
pub const listenbrainz = @import("listenbrainz.zig");
pub const listenbrainz_labs = @import("listenbrainz_labs.zig");
pub const listens = @import("listens.zig");
pub const lrclib = @import("lrclib.zig");
pub const model = @import("model.zig");
pub const musicbrainz = @import("musicbrainz.zig");
pub const scoring = @import("scoring.zig");
pub const scrobble = @import("scrobble.zig");
pub const shared_state = @import("shared_state.zig");
pub const url = @import("url.zig");
pub const wikidata = @import("wikidata.zig");
pub const wikimedia_commons = @import("wikimedia_commons.zig");
pub const wikipedia = @import("wikipedia.zig");
pub const workflow = @import("workflow.zig");

pub const Candidate = model.Candidate;
pub const CandidateList = model.CandidateList;
pub const Provider = model.Provider;
pub const Query = model.Query;

test {
    _ = @import("acoustid.zig");
    _ = @import("cached_get.zig");
    _ = @import("coverartarchive.zig");
    _ = @import("credentials.zig");
    _ = @import("listenbrainz.zig");
    _ = @import("listenbrainz_labs.zig");
    _ = @import("listens.zig");
    _ = @import("lrclib.zig");
    _ = @import("model.zig");
    _ = @import("musicbrainz.zig");
    _ = @import("scoring.zig");
    _ = @import("scrobble.zig");
    _ = @import("shared_state.zig");
    _ = @import("url.zig");
    _ = @import("wikidata.zig");
    _ = @import("wikimedia_commons.zig");
    _ = @import("wikipedia.zig");
    _ = @import("workflow.zig");
}

const std = @import("std");
const network = @import("../network/root.zig");

fn fetchOnce(gateway: *network.Gateway) !void {
    const response = try gateway.execute(std.testing.allocator, .get, "https://example.test", null, &.{});
    response.deinit();
}

test "gateways of different services are each spaced by their own interval" {
    var mb: network.testing.TestGateway = undefined;
    mb.init(.{ .config = .{ .identity = network.testing.test_identity, .minimum_interval_ms = musicbrainz.minimum_interval_ms } });
    defer mb.deinit();
    var acoustid_net = network.testing.gateway(
        &mb.transport,
        &mb.clock,
        &mb.prng,
        .{ .identity = network.testing.test_identity, .minimum_interval_ms = acoustid.minimum_interval_ms },
    );

    try fetchOnce(&acoustid_net);
    try std.testing.expectEqual(@as(u64, 0), mb.clock.slept());
    try fetchOnce(&acoustid_net);
    try std.testing.expectEqual(@as(u64, 334), mb.clock.slept());

    try fetchOnce(&mb.gateway);
    try std.testing.expectEqual(@as(u64, 334), mb.clock.slept());
    try fetchOnce(&acoustid_net);
    try std.testing.expectEqual(@as(u64, 334 + 334), mb.clock.slept());
    try fetchOnce(&mb.gateway);
    try std.testing.expectEqual(@as(u64, 334 + 334 + 666), mb.clock.slept());
}
