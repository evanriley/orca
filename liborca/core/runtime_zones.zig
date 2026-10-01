const audio = @import("../audio/root.zig");
const runtime = @import("runtime.zig");
const runtime_queue = @import("runtime_queue.zig");

const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const ZoneHandle = runtime.ZoneHandle;
const ZoneObject = runtime.ZoneObject;
const ZoneStats = runtime.ZoneStats;

pub fn createZone(self: *OrcaRuntime) !ZoneHandle {
    try runtime.requireRunning(self);
    const zone = try audio.zone_runtime.ZoneRuntime.create(self.allocator);
    errdefer zone.destroy();
    return self.zones.insert(.{ .zone = zone });
}

pub fn destroyZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    const attached = object_value.attached_player;
    object_value.attached_player = null;
    if (attached) |player| try runtime_queue.republishZones(self, player);
    const removed = try self.zones.remove(zone);
    removed.zone.destroy();
}

pub fn attachZone(self: *OrcaRuntime, zone: ZoneHandle, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    _ = try self.players.get(player);
    const object_value = try self.zones.get(zone);
    const previous = object_value.attached_player;
    if (previous) |old| {
        if (old.eql(player)) return;
        object_value.attached_player = null;
        runtime_queue.republishZones(self, old) catch |err| {
            object_value.attached_player = old;
            return err;
        };
        object_value.zone.retire();
    }
    object_value.attached_player = player;
    runtime_queue.republishZones(self, player) catch |err| {
        object_value.attached_player = previous;
        if (previous) |old| try runtime_queue.republishZones(self, old);
        return err;
    };
}

pub fn detachZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    const attached = object_value.attached_player orelse return;
    object_value.attached_player = null;
    try runtime_queue.republishZones(self, attached);
    const detached = try self.zones.get(zone);
    detached.zone.output_requested.store(false, .release);
    detached.zone.retire();
}

pub fn zoneRequestOutput(self: *OrcaRuntime, zone: ZoneHandle, device_id: u64) !void {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    object_value.zone.requested_device_id.store(device_id, .release);
    object_value.zone.output_requested.store(true, .release);
    if (object_value.attached_player) |player| {
        if ((try self.players.get(player)).engine) |engine| engine.wakeUp();
    }
}

pub fn zoneCloseOutput(self: *OrcaRuntime, zone: ZoneHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    object_value.zone.output_requested.store(false, .release);
    if (object_value.attached_player) |player| {
        if ((try self.players.get(player)).engine) |engine| {
            engine.wakeUp();
            return;
        }
    }
    object_value.zone.closeOutput();
    object_value.zone.resetPipe();
    object_value.zone.zone.close();
    object_value.zone.publishState();
}

pub fn enumerateOutputDevices(
    self: *OrcaRuntime,
    devices: []audio.backend.Device,
) !usize {
    try runtime.requireRunning(self);
    const factory = runtime.outputFactory(self) orelse return 0;
    return factory.discover(devices);
}

pub fn setZonePolicy(
    self: *OrcaRuntime,
    zone: ZoneHandle,
    policy: audio.zone.RenderPolicy,
) !void {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    try requireZoneIdle(self, object_value);
    object_value.zone.zone.policy = policy;
}

pub fn zoneRenderStrategy(
    self: *OrcaRuntime,
    zone: ZoneHandle,
) !audio.zone.RenderStrategy {
    try runtime.requireRunning(self);
    return (try self.zones.get(zone)).zone.zone.renderStrategy();
}

pub fn zoneOutputState(self: *OrcaRuntime, zone: ZoneHandle) !audio.zone.OutputState {
    try runtime.requireRunning(self);
    return (try self.zones.get(zone)).zone.outputState();
}

pub fn zoneStats(self: *OrcaRuntime, zone: ZoneHandle) !ZoneStats {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    return .{
        .output_state = object_value.zone.outputState(),
        .recovery_attempts = object_value.zone.published_recovery_attempts.load(.acquire),
        .underruns = object_value.zone.pipe.underruns.load(.monotonic),
        .dropped_returns = object_value.zone.pipe.dropped_returns.load(.monotonic),
        .backend_quantum_frames = object_value.zone.published_quantum_frames.load(.acquire),
        .rendered_entry_serial = object_value.zone.rendered_entry_serial.load(.monotonic),
    };
}

/// Output state belongs to whichever lane currently owns the Zone. Once an
/// engine holds it, only the engine may mutate it.
pub fn requireZoneIdle(self: *OrcaRuntime, object_value: *ZoneObject) !void {
    const player = object_value.attached_player orelse return;
    if ((try self.players.get(player)).engine != null)
        return error.ZoneOwnedByEngine;
}

pub fn zoneOpenOutput(
    self: *OrcaRuntime,
    zone: ZoneHandle,
    device_id: u64,
    policy: audio.zone.RenderPolicy,
    latency_frames: u32,
) !void {
    try runtime.requireRunning(self);
    const object_value = try self.zones.get(zone);
    try requireZoneIdle(self, object_value);
    object_value.zone.zone.policy = policy;
    object_value.zone.zone.latency.requested_frames = latency_frames;
    return self.zoneRequestOutput(zone, device_id);
}

pub fn playerOpenDefaultOutput(
    self: *OrcaRuntime,
    player: PlayerHandle,
    device_id: u64,
) !ZoneHandle {
    try runtime.requireRunning(self);
    _ = try self.players.get(player);
    const zone = try self.createZone();
    errdefer self.destroyZone(zone) catch {};
    try self.attachZone(zone, player);
    try self.zoneRequestOutput(zone, device_id);
    return zone;
}

pub fn playerHasZone(self: *OrcaRuntime, player: PlayerHandle) bool {
    for (self.zones.slots.items) |*slot| {
        if (slot.value) |zone| {
            const attached = zone.attached_player orelse continue;
            if (attached.eql(player)) return true;
        }
    }
    return false;
}
