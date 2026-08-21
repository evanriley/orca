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
