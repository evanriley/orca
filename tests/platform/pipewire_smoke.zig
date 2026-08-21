const std = @import("std");

extern fn pw_get_library_version() [*:0]const u8;

test "PipeWire library can be linked through the platform build boundary" {
    const version = std.mem.span(pw_get_library_version());
    try std.testing.expect(version.len > 0);
}
