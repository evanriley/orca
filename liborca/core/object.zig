const handle = @import("handle.zig");

pub const LibraryTag = struct {};
pub const PlayerTag = struct {};
pub const ZoneTag = struct {};
pub const JobTag = struct {};

pub const LibraryHandle = handle.Handle(LibraryTag);
pub const PlayerHandle = handle.Handle(PlayerTag);
pub const ZoneHandle = handle.Handle(ZoneTag);
pub const JobHandle = handle.Handle(JobTag);
