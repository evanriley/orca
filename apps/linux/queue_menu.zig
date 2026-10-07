const std = @import("std");

pub const Item = struct {
    label: [:0]const u8,
    action: [:0]const u8,
    accel: ?[:0]const u8 = null,
};

pub const Entry = struct {
    in_library: bool,
    loved: bool = false,
    has_release: bool = false,
    has_artist: bool = false,
};

const section_capacity = 3;

pub const Section = struct {
    buffer: [section_capacity]Item = undefined,
    len: usize = 0,

    fn add(self: *Section, item: Item) void {
        self.buffer[self.len] = item;
        self.len += 1;
    }

    pub fn items(self: *const Section) []const Item {
        return self.buffer[0..self.len];
    }
};

pub const section_count = 3;

pub fn sections(entry: Entry) [section_count]Section {
    var queueing: Section = .{};
    var track: Section = .{};
    var queue: Section = .{};
    if (entry.in_library) {
        queueing.add(.{ .label = "Play Next", .action = "queue.play-next", .accel = "<Shift>Return" });
        queueing.add(.{ .label = "Play Later", .action = "queue.play-later" });
        if (entry.loved)
            track.add(.{ .label = "Remove Love", .action = "app.ctx-remove-love", .accel = "l" })
        else
            track.add(.{ .label = "Love", .action = "app.ctx-love", .accel = "l" });
        if (entry.has_release) track.add(.{ .label = "Go to Album", .action = "app.ctx-show-album" });
        if (entry.has_artist) track.add(.{ .label = "Go to Artist", .action = "app.ctx-show-artist" });
    }
    queue.add(.{ .label = "Remove from Queue", .action = "app.ctx-remove", .accel = "Delete" });
    queue.add(.{ .label = "Save Queue as Playlist…", .action = "queue.save" });
    return .{ queueing, track, queue };
}

fn expectLabels(expected: []const []const []const u8, actual: [section_count]Section) !void {
    try std.testing.expectEqual(section_count, expected.len);
    for (expected, &actual) |labels, *section| {
        try std.testing.expectEqual(labels.len, section.len);
        for (labels, section.items()) |label, item| try std.testing.expectEqualStrings(label, item.label);
    }
}

test "an entry in the Library offers moving, loving, navigating and removing it" {
    try expectLabels(&.{
        &.{ "Play Next", "Play Later" },
        &.{ "Love", "Go to Album", "Go to Artist" },
        &.{ "Remove from Queue", "Save Queue as Playlist…" },
    }, sections(.{ .in_library = true, .has_release = true, .has_artist = true }));
}

test "a loved entry offers removing its love" {
    const offered = sections(.{ .in_library = true, .loved = true });
    try expectLabels(&.{
        &.{ "Play Next", "Play Later" },
        &.{"Remove Love"},
        &.{ "Remove from Queue", "Save Queue as Playlist…" },
    }, offered);
    try std.testing.expectEqualStrings("app.ctx-remove-love", offered[1].items()[0].action);
}

test "an entry whose Track left the Library offers only removing it and saving the queue" {
    const offered = sections(.{ .in_library = false, .loved = true, .has_release = true, .has_artist = true });
    try expectLabels(&.{
        &.{},
        &.{},
        &.{ "Remove from Queue", "Save Queue as Playlist…" },
    }, offered);
    try std.testing.expectEqualStrings("app.ctx-remove", offered[2].items()[0].action);
    try std.testing.expectEqualStrings("queue.save", offered[2].items()[1].action);
}
