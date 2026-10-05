//! Fails when a compiled Chromaprint source carries a GPL or LGPL notice.
//!
//! Usage: licence_check NAME PATH [NAME PATH]...

const std = @import("std");

/// Text that appears in every GPL and LGPL notice, in either the long form or
/// an SPDX identifier.
const copyleft_markers = [_][]const u8{ "General Public", "GPL" };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or args.len % 2 != 1) {
        std.process.fatal("usage: {s} NAME PATH [NAME PATH]...", .{args[0]});
    }
    var pair: usize = 1;
    while (pair < args.len) : (pair += 2) {
        const name = args[pair];
        const path = args[pair + 1];
        const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 20)) catch |err|
            std.process.fatal("unable to read Chromaprint source {s} at {s}: {t}", .{ name, path, err });
        for (copyleft_markers) |marker| {
            if (std.mem.indexOf(u8, text, marker) != null) std.process.fatal(
                "Chromaprint source {s} contains \"{s}\"; liborca may only compile permissively licensed code. Remove it from build/chromaprint.zig.",
                .{ name, marker },
            );
        }
    }
}
