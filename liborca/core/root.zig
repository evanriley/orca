pub const artwork = @import("artwork.zig");
pub const control = @import("control.zig");
pub const handle = @import("handle.zig");
pub const job = @import("job.zig");
pub const listen_worker = @import("listen_worker.zig");
pub const object = @import("object.zig");
pub const queue = @import("queue.zig");
pub const runtime = @import("runtime.zig");
pub const track_details = @import("track_details.zig");
pub const track_source = @import("track_source.zig");
pub const work = @import("work.zig");

pub const OrcaRuntime = runtime.OrcaRuntime;
pub const LibraryHandle = runtime.LibraryHandle;
pub const PlayerHandle = runtime.PlayerHandle;
pub const ZoneHandle = runtime.ZoneHandle;
pub const JobHandle = runtime.JobHandle;
pub const WorkHandle = runtime.WorkHandle;

test {
    _ = @import("artwork.zig");
    _ = @import("control.zig");
    _ = @import("handle.zig");
    _ = @import("job.zig");
    _ = @import("listen_worker.zig");
    _ = @import("object.zig");
    _ = @import("queue.zig");
    _ = @import("runtime.zig");
    _ = @import("track_details.zig");
    _ = @import("track_source.zig");
    _ = @import("work.zig");
}
