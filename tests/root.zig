const std = @import("std");
const liborca = @import("liborca");

test "public module identifies the host platform" {
    try std.testing.expect(liborca.platform.current.supported);
    try std.testing.expect(liborca.platform.current.name.len > 0);
}

test "registered lossless and lossy codecs share SourceSession pipeline" {
    const paths = [_][]const u8{
        "fixtures/audio/generated-reference.flac",
        "fixtures/audio/generated-reference.qoa",
    };
    const codecs = liborca.codec.CodecRegistry.builtins();
    for (paths) |path| {
        var local = try liborca.storage.LocalFileSource.open(std.testing.io, path);
        defer local.close();
        var source = liborca.audio.source_session.SourceSession.init(
            try codecs.openDetected(std.testing.allocator, local.readable()),
        );
        defer source.deinit();
        const frames: usize = @intCast(source.decoder.frame_count.?);
        const channels = source.decoder.format.channels;
        var pool = try liborca.audio.buffer.BlockPool.init(
            std.testing.allocator,
            2,
            1024,
            channels,
        );
        defer pool.deinit();
        var pipe: liborca.audio.render.RenderPipe(2) = .{};
        try std.testing.expectEqual(@as(usize, 1), try source.prime(2, &pipe, &pool, 1, 1));
        const output = try std.testing.allocator.alloc(f32, frames * channels);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqual(frames, pipe.render(&pool, channels, 1, output));
    }
}
