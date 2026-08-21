const std = @import("std");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const track_count = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        500_000;
    const path = if (args.len > 2)
        try allocator.dupeSentinel(u8, args[2], 0)
    else
        try allocator.dupeSentinel(u8, "file:orca-benchmark?mode=memory&cache=shared", 0);

    var library = try liborca.database.LibraryDatabase.open(allocator, path);
    defer library.close();
    try library.database.exec("DELETE FROM tracks;");

    var batch: [1000]liborca.database.TrackInput = undefined;
    for (&batch, 0..) |*track, index| track.* = .{
        .title = "Synthetic benchmark track",
        .album = "Synthetic benchmark album",
        .album_artist = "Orca benchmark",
        .duration_ms = 180_000,
        .track_number = @intCast(index + 1),
        .disc_number = 1,
    };

    const insert_start = std.Io.Clock.awake.now(init.io);
    var inserted: usize = 0;
    while (inserted < track_count) {
        const count = @min(batch.len, track_count - inserted);
        try library.tracks.insertBatch(batch[0..count]);
        inserted += count;
    }
    const insert_ns = insert_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;

    var open_ns: i96 = 0;
    if (args.len > 2) {
        library.close();
        const open_start = std.Io.Clock.awake.now(init.io);
        library = try liborca.database.LibraryDatabase.open(allocator, path);
        open_ns = open_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    }

    const search_start = std.Io.Clock.awake.now(init.io);
    var page = try library.tracks.search(allocator, "Synthetic", 100, 0);
    defer page.deinit();
    const search_ns = search_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;

    std.debug.print(
        "Orca {f} SQLite/FTS benchmark: {d} tracks, insert {d} ms, open {d} ms, search {d} ms, {d} results\n",
        .{
            liborca.version,
            track_count,
            @divTrunc(insert_ns, std.time.ns_per_ms),
            @divTrunc(open_ns, std.time.ns_per_ms),
            @divTrunc(search_ns, std.time.ns_per_ms),
            page.items.len,
        },
    );
}
