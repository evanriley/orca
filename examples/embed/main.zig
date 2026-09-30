//! Lists the tracks of an Orca library, using only liborca's public API.

const std = @import("std");
const orca = @import("liborca");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: orca-embed-example DATABASE\n", .{});
        return error.InvalidArguments;
    }

    var runtime = orca.Runtime.init(allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(.{ .name = "EmbedExample", .version = "0.1.0", .contact = "https://example.invalid" });
    const database_path = try allocator.dupeSentinel(u8, args[1], 0);
    defer allocator.free(database_path);
    const library = try runtime.openLibrary(init.io, database_path);

    const query: orca.TrackQuery = .{ .limit = 50, .sort = .title };
    var page = try runtime.libraryTrackQuery(library, "", query);
    defer page.deinit();
    for (page.items) |track| std.debug.print("{d}\t{s}\t{s}\n", .{ track.id, track.title, track.artist });
}
