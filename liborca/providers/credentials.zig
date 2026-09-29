const std = @import("std");

/// Platform frontends implement this capability with Keychain, Secret Service,
/// or another secure store. Provider code never reads credentials from the
/// library database or serializes them into cache keys.
pub const Store = struct {
    context: *anyopaque,
    get_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!?[]u8,

    pub fn get(
        self: Store,
        allocator: std.mem.Allocator,
        service: []const u8,
        account: []const u8,
    ) !?[]u8 {
        return self.get_fn(self.context, allocator, service, account);
    }
};

/// Frees a copy of a secret after overwriting it, so it does not linger in
/// memory the allocator hands out again.
pub fn wipeAndFree(allocator: std.mem.Allocator, secret: []u8) void {
    wipe(secret);
    allocator.free(secret);
}

pub fn wipe(secret: []u8) void {
    std.crypto.secureZero(u8, secret);
}

test "a wiped secret is all zero" {
    var secret = "user-token".*;
    wipe(&secret);
    try std.testing.expect(std.mem.allEqual(u8, &secret, 0));
}
