const std = @import("std");
const liborca = @import("liborca");

test "public module identifies the host platform" {
    try std.testing.expect(liborca.platform.current.supported);
    try std.testing.expect(liborca.platform.current.name.len > 0);
}
