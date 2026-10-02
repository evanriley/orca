const std = @import("std");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const providers = @import("../providers/root.zig");
const runtime = @import("runtime.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_listens = @import("runtime_listens.zig");

const JobHandle = runtime.JobHandle;
const JobWorker = job_worker.JobWorker;
const LibraryHandle = runtime.LibraryHandle;
const LibraryObject = runtime.LibraryObject;
const MatchStats = job_worker.MatchStats;
const OrcaRuntime = runtime.OrcaRuntime;

const loose_unit_tracks: u32 = 20;
const unit_batch_size: usize = 64;

pub const MaintenanceOptions = struct {
    enabled: bool,
    /// The time between one unit's end and the next one's start.
    interval_ms: u32 = 5 * 60 * 1000,
};

pub const MaintenanceState = enum {
    off,
    /// Enabled; the next unit is due in `next_due_ms`.
    waiting,
    running,
    /// Enabled, but the last unit could not start or stopped for `blocked`.
    blocked,
};

pub const MaintenanceBlock = enum {
    client_identity_required,
    acoustid_required,
    /// A provider's backoff is recorded, or another Orca process holds it.
    provider_busy,
};

pub const MaintenanceUnit = struct {
    /// Null for a unit that verified Tracks on no Release.
    release_id: ?i64,
    state: job.State,
    stats: MatchStats,
};

pub const MaintenanceStatus = struct {
    enabled: bool,
    state: MaintenanceState,
    blocked: ?MaintenanceBlock = null,
    /// From now; null while off or running.
    next_due_ms: ?u64 = null,
    units_run: u64 = 0,
    last: ?MaintenanceUnit = null,
};

pub const ActiveUnit = struct {
    job: JobHandle,
    release_id: ?i64,
};

/// One Library's maintenance schedule. Control lane only; it holds no
/// pointer, so it survives drains as it is.
pub const LibraryMaintenance = struct {
    options: MaintenanceOptions,
    next_due_ms: i64,
    release_cursor: i64 = 0,
    active: ?ActiveUnit = null,
    blocked: ?MaintenanceBlock = null,
    units_run: u64 = 0,
    last: ?MaintenanceUnit = null,
};

const Unit = struct {
    scope: database.MatchScope,
    limit: ?u32,
    release_id: ?i64,
};

pub fn libraryMaintenance(self: *OrcaRuntime, library: LibraryHandle, options: MaintenanceOptions) !void {
    try runtime.requireRunning(self);
    if (options.interval_ms == 0) return error.InvalidMaintenanceOptions;
    const object_value = try self.libraries.get(library);
    if (object_value.database == null) return error.LibraryHasNoDatabase;
    if (!options.enabled) {
        preemptUnit(self, library);
        object_value.maintenance = null;
        return;
    }
    const now_ms = runtime_listens.sampleTime(self).mono_ms;
    if (object_value.maintenance) |*record| {
        record.options = options;
        record.next_due_ms = now_ms;
        return;
    }
    object_value.maintenance = .{ .options = options, .next_due_ms = now_ms };
}

pub fn libraryMaintenanceStatus(self: *OrcaRuntime, library: LibraryHandle) !MaintenanceStatus {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    const record = object_value.maintenance orelse return .{ .enabled = false, .state = .off };
    var status: MaintenanceStatus = .{
        .enabled = true,
        .state = .waiting,
        .blocked = record.blocked,
        .units_run = record.units_run,
        .last = record.last,
    };
    if (record.active != null) {
        status.state = .running;
        return status;
    }
    if (record.blocked != null) status.state = .blocked;
    status.next_due_ms = remainingMs(&record, runtime_listens.sampleTime(self).mono_ms);
    return status;
}

pub fn preemptUnit(self: *OrcaRuntime, library: LibraryHandle) void {
    const unit = runtime_jobs.maintenanceUnitRunning(self) orelse return;
    if (!unit.library.eql(library)) return;
    unit.token.cancel();
    unit.registration.requestCancellation();
}

pub fn pumpMaintenance(self: *OrcaRuntime) void {
    if (self.state.load(.acquire) != .running) return;
    if (runtime_jobs.maintenanceUnitRunning(self) != null) return;
    var now: ?i64 = null;
    for (self.libraries.slots.items, 0..) |*slot, index| {
        const object_value = if (slot.value) |*value| value else continue;
        const record = if (object_value.maintenance) |*value| value else continue;
        const now_ms = now orelse sampled: {
            now = runtime_listens.sampleTime(self).mono_ms;
            break :sampled now.?;
        };
        if (now_ms < record.next_due_ms) continue;
        const library: LibraryHandle = .{ .index = @intCast(index), .generation = slot.generation };
        if (startUnit(self, library, object_value, record)) return;
        record.next_due_ms = now_ms + record.options.interval_ms;
    }
}

fn startUnit(self: *OrcaRuntime, library: LibraryHandle, object_value: *LibraryObject, record: *LibraryMaintenance) bool {
    const library_database = object_value.database orelse return false;
    const identity = self.client_identity orelse {
        record.blocked = .client_identity_required;
        return false;
    };
    if (!runtime_jobs.acoustIdInScope(self, true)) {
        record.blocked = .acoustid_required;
        return false;
    }
    if (!runtime_listens.playersIdle(self) or runtime_jobs.hostWorkLive(self)) {
        record.blocked = null;
        return false;
    }
    const wall_ms = runtime_listens.sampleTime(self).wall_s * std.time.ms_per_s;
    if (providerBlocked(library_database, wall_ms) catch return false) {
        record.blocked = .provider_busy;
        return false;
    }
    const unit = nextUnit(record, library_database) catch return false;
    const chosen = unit orelse {
        record.blocked = null;
        record.release_cursor = 0;
        return false;
    };
    const job_handle = runtime_jobs.spawnJobWorker(self, library, .{ .metadata_lookup = .{
        .batch_size = unit_batch_size,
        .limit = chosen.limit,
        .setup = .{
            .io = runtime_listens.networkIo(self) catch return false,
            .server = self.musicbrainz_server,
            .identity = identity,
            .hooks = self.matching_hooks,
            .scope = chosen.scope,
            .mode = .verify,
            .acoustid = runtime_jobs.acoustIdSetup(self),
            .cover_art_server = self.coverartarchive_server,
        },
    } }, .maintenance) catch return false;
    record.active = .{ .job = job_handle, .release_id = chosen.release_id };
    record.blocked = null;
    record.release_cursor = chosen.release_id orelse 0;
    return true;
}

fn providerBlocked(library_database: *database.LibraryDatabase, wall_ms: i64) !bool {
    for ([_][]const u8{ providers.acoustid.service, providers.musicbrainz.service }) |service| {
        const state = try library_database.provider_state.get(service) orelse continue;
        const blocked_until_ms = state.blocked_until_ms orelse continue;
        if (blocked_until_ms > wall_ms) return true;
    }
    return false;
}

fn nextUnit(record: *const LibraryMaintenance, library_database: *database.LibraryDatabase) !?Unit {
    const verifications = &library_database.recording_verifications;
    var buffer: [1]i64 = undefined;
    var found = try verifications.releasesToVerify(record.release_cursor, &buffer);
    if (found.len == 0 and record.release_cursor != 0) found = try verifications.releasesToVerify(0, &buffer);
    if (found.len != 0) return .{ .scope = .{ .release = found[0] }, .limit = null, .release_id = found[0] };
    if (try verifications.verifiableCount(.library, 1) == 0) return null;
    return .{ .scope = .library, .limit = loose_unit_tracks, .release_id = null };
}

/// Called for every job worker as it is finalized, on every path.
pub fn jobFinalized(self: *OrcaRuntime, worker: *JobWorker, state: job.State) void {
    if (worker.origin != .maintenance) return;
    const object_value = self.libraries.get(worker.library) catch return;
    const record = if (object_value.maintenance) |*value| value else return;
    const active = record.active orelse return;
    if (!active.job.eql(worker.job)) return;
    const stats = worker.matchStats();
    record.active = null;
    record.units_run += 1;
    record.last = .{ .release_id = active.release_id, .state = state, .stats = stats };
    record.blocked = if (stats.busy != .none)
        .provider_busy
    else switch (stats.acoustid) {
        .no_client_key, .invalid_client_key => .acoustid_required,
        .searched, .off => null,
    };
    record.next_due_ms = runtime_listens.sampleTime(self).mono_ms + record.options.interval_ms;
}

/// The time to the first Library's next unit, 0 when one is due; null
/// while a unit runs, whose worker's own pump timeout covers it, or when no
/// Library has maintenance enabled.
pub fn maintenancePumpDueMs(self: *OrcaRuntime) ?u64 {
    if (runtime_jobs.maintenanceUnitRunning(self) != null) return null;
    var due: ?u64 = null;
    var now: ?i64 = null;
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const record = if (object_value.maintenance) |*value| value else continue;
        const now_ms = now orelse sampled: {
            now = runtime_listens.sampleTime(self).mono_ms;
            break :sampled now.?;
        };
        const remaining = remainingMs(record, now_ms);
        due = if (due) |current| @min(current, remaining) else remaining;
    }
    return due;
}

fn remainingMs(record: *const LibraryMaintenance, now_ms: i64) u64 {
    return @intCast(@max(record.next_due_ms - now_ms, 0));
}
