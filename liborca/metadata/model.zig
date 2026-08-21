pub const Provenance = enum {
    observed_file,
    user,
    provider,
    inference,
    analysis,
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
    const std = @import("std");
    const effective = resolve(
        .{ .title = .{ .text = "File title", .provenance = .observed_file } },
        .{ .title = .{ .text = "User title", .provenance = .user, .locked = true } },
        .prefer_file,
    );
    try std.testing.expectEqualStrings("User title", effective.title.?.text);
    try std.testing.expectEqual(Provenance.user, effective.title.?.provenance);
}
