const std = @import("std");
const listen_worker = @import("listen_worker.zig");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const providers = @import("../providers/root.zig");
const job_worker = @import("job_worker.zig");
const runtime = @import("runtime.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_status = @import("runtime_status.zig");

const ClientIdentity = runtime.ClientIdentity;
const CredentialStore = runtime.CredentialStore;
const Feedback = runtime.Feedback;
const FeedbackChange = runtime.FeedbackChange;
const LibraryHandle = runtime.LibraryHandle;
const LibraryObject = runtime.LibraryObject;
const ConfidentMatchAcceptance = runtime.ConfidentMatchAcceptance;
const MatchAcceptance = runtime.MatchAcceptance;
const MatchProposalPage = runtime.MatchProposalPage;
const MatchReviewPage = runtime.MatchReviewPage;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayStats = runtime.PlayStats;
const PlayerObject = runtime.PlayerObject;
const ScrobblerStatus = runtime.ScrobblerStatus;

pub const StoredCounts = struct {
    pending: u64,
    feedback_pending: u64,
    delivered_total: u64,
    blocked_until: ?i64,
    read_at_ms: i64,
};

pub const stored_counts_reuse_ms: i64 = 1000;

/// How often the control lane samples bound Players for listens.
const listen_sample_interval_ms: i64 = 100;
/// The pump timeout a playing Player asks for. Its position hints already
/// wake the host about every `listen_sample_interval_ms`, and every pump
/// samples; this only covers a Player whose output stalls.
const listen_fallback_interval_ms: i64 = 1000;

pub fn setClientIdentity(self: *OrcaRuntime, identity: ClientIdentity) !void {
    try runtime.requireRunning(self);
    self.client_identity = try .init(identity);
    publishListenSettings(self);
}

pub fn setCredentialStore(self: *OrcaRuntime, store: CredentialStore) !void {
    try runtime.requireRunning(self);
    self.credential_store = store;
    publishListenSettings(self);
}

pub fn setListenBrainzServer(self: *OrcaRuntime, base_url: []const u8) !void {
    try runtime.requireRunning(self);
    try providers.url.validateServer(base_url);
    self.listenbrainz_server = base_url;
    publishListenSettings(self);
}

pub fn setMusicBrainzServer(self: *OrcaRuntime, base_url: []const u8) !void {
    try runtime.requireRunning(self);
    try providers.url.validateServer(base_url);
    self.musicbrainz_server = base_url;
}

pub fn setAcoustIdClientKey(self: *OrcaRuntime, key: []const u8) !void {
    try runtime.requireRunning(self);
    if (!job_worker.validAcoustIdKey(key)) return error.InvalidAcoustIdKey;
    self.acoustid_client_key = key;
}

pub fn setAcoustIdServer(self: *OrcaRuntime, base_url: []const u8) !void {
    try runtime.requireRunning(self);
    try providers.url.validateServer(base_url);
    self.acoustid_server = base_url;
}

pub fn setCoverArtArchiveServer(self: *OrcaRuntime, base_url: []const u8) !void {
    try runtime.requireRunning(self);
    try providers.url.validateServer(base_url);
    self.coverartarchive_server = base_url;
}

fn withListenSettings(self: *OrcaRuntime, config: listen_worker.Config) listen_worker.Config {
    var updated = config;
    updated.identity = self.client_identity;
    updated.credentials = self.credential_store;
    updated.server = self.listenbrainz_server;
    updated.settings = self.listen_settings;
    return updated;
}

fn publishListenSettings(self: *OrcaRuntime) void {
    self.listen_settings +%= 1;
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const listens = object_value.listens orelse continue;
        listens.configure(self.control_threaded.io(), withListenSettings(self, listens.loadConfig()));
    }
}

pub fn librarySetScrobbling(
    self: *OrcaRuntime,
    library: LibraryHandle,
    enabled: bool,
    offline: bool,
    now_playing: bool,
) !void {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    if (object_value.database == null) return error.LibraryHasNoDatabase;
    if (enabled) {
        if (self.client_identity == null) return error.ClientIdentityRequired;
        if (self.scrobbling_library) |other| {
            if (!other.eql(library)) return error.ScrobblingEnabledElsewhere;
        }
    }
    const listens = if (enabled)
        try startListenWorker(self, library)
    else
        try ensureListens(self, object_value);
    var config = listens.loadConfig();
    config.enabled = enabled;
    config.offline = offline;
    config.now_playing = now_playing;
    listens.configure(self.control_threaded.io(), config);
    if (enabled) {
        self.scrobbling_library = library;
    } else if (self.scrobbling_library) |scrobbling| {
        if (scrobbling.eql(library)) self.scrobbling_library = null;
    }
}

pub fn libraryScrobblerCredentialsChanged(self: *OrcaRuntime, library: LibraryHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    if (object_value.database == null) return error.LibraryHasNoDatabase;
    (try ensureListens(self, object_value)).credentialsChanged(self.control_threaded.io());
}

pub fn libraryScrobblerStatus(self: *OrcaRuntime, library: LibraryHandle) !ScrobblerStatus {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    const listens = object_value.listens;
    if (listens) |existing| {
        if (existing.worker != null) return existing.snapshot();
    }
    var status: ScrobblerStatus = if (listens) |existing| existing.snapshot() else .{ .state = .disabled };
    const counts = storedCounts(self, object_value) orelse return status;
    status.pending = counts.pending;
    status.feedback_pending = counts.feedback_pending;
    status.delivered_total = counts.delivered_total;
    status.blocked_until = counts.blocked_until;
    return status;
}

fn storedCounts(self: *OrcaRuntime, object_value: *LibraryObject) ?StoredCounts {
    const library_database = object_value.database orelse return null;
    const now = sampleTime(self);
    if (object_value.stored_counts) |counts| {
        if (now.mono_ms - counts.read_at_ms < stored_counts_reuse_ms) return counts;
    }
    const stored_state = library_database.provider_state.get(providers.listenbrainz.service) catch
        return object_value.stored_counts;
    const blocked_until_ms = if (stored_state) |stored| stored.blocked_until_ms else null;
    const counts: StoredCounts = .{
        .pending = library_database.scrobbles.pendingCount() catch return object_value.stored_counts,
        .feedback_pending = library_database.feedback.pendingSyncCount() catch return object_value.stored_counts,
        .delivered_total = library_database.scrobbles.deliveredCount(providers.listenbrainz.service) catch
            return object_value.stored_counts,
        .blocked_until = listen_worker.blockEnd(blocked_until_ms, now.wall_s),
        .read_at_ms = now.mono_ms,
    };
    object_value.stored_counts = counts;
    return counts;
}

pub fn libraryListensRecorded(self: *OrcaRuntime, library: LibraryHandle) !u64 {
    try runtime.requireRunning(self);
    const listens = (try self.libraries.get(library)).listens orelse return 0;
    return listens.recorded.load(.monotonic);
}

pub fn librarySetFeedback(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_ids: []const i64,
    feedback: Feedback,
) !FeedbackChange {
    const library_database = try runtime.libraryDatabase(self, library);
    const change = try library_database.feedback.set(track_ids, feedback);
    const listens = (try self.libraries.get(library)).listens orelse return change;
    if (change.updated == 0) return change;
    if (listens.loadConfig().enabled) _ = startListenWorker(self, library) catch {};
    listens.feedbackChanged(self.control_threaded.io());
    return change;
}

pub fn libraryMatchProposals(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_id: i64,
    limit: u32,
) !MatchProposalPage {
    return (try runtime.libraryDatabase(self, library)).identification_proposals.pendingForTrack(self.allocator, track_id, limit);
}

pub fn libraryAcceptMatch(self: *OrcaRuntime, library: LibraryHandle, proposal_id: i64) !MatchAcceptance {
    const library_database = try runtime.libraryDatabase(self, library);
    var written: std.ArrayList(i64) = .empty;
    defer written.deinit(self.allocator);
    const acceptance = try library_database.identification_proposals.acceptProposalInto(self.allocator, proposal_id, &written);
    if (acceptance.values_written == 0) return acceptance;
    try reproject(self, library_database, written.items);
    recordingIdsChanged(self, library);
    return acceptance;
}

pub fn libraryApplyMatchedRelease(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !u32 {
    const library_database = try runtime.libraryDatabase(self, library);
    const release = try library_database.releases.byId(self.allocator, release_id) orelse return error.UnknownRelease;
    release.deinit(self.allocator);
    var written: std.ArrayList(i64) = .empty;
    defer written.deinit(self.allocator);
    const values_written = try library_database.identification_proposals.applyReleaseConsensus(self.allocator, release_id, &written);
    if (values_written == 0) return 0;
    try reproject(self, library_database, written.items);
    recordingIdsChanged(self, library);
    return values_written;
}

fn reproject(self: *OrcaRuntime, library_database: *database.LibraryDatabase, file_ids: []const i64) !void {
    var pass: library_pass.Projection = .{
        .allocator = self.allocator,
        .library = library_database,
    };
    _ = try pass.run(.{ .files = file_ids });
}

pub fn libraryDismissMatch(self: *OrcaRuntime, library: LibraryHandle, proposal_id: i64) !void {
    try (try runtime.libraryDatabase(self, library)).identification_proposals.dismiss(proposal_id);
}

pub fn libraryMatchReviewPage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    limit: u32,
    offset: u32,
) !MatchReviewPage {
    return (try runtime.libraryDatabase(self, library)).identification_proposals.reviewPage(self.allocator, limit, offset);
}

pub fn libraryMatchReviewCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
    return (try runtime.libraryDatabase(self, library)).identification_proposals.reviewCount();
}

pub fn libraryUnidentifiedCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
    return (try runtime.libraryDatabase(self, library)).identification_proposals.unidentifiedCount(
        .library,
        runtime_jobs.acoustIdInScope(self, true),
        null,
    );
}

pub fn libraryConfidentMatchCount(self: *OrcaRuntime, library: LibraryHandle, minimum_confidence: f32) !u64 {
    return (try runtime.libraryDatabase(self, library)).identification_proposals.confidentCount(self.allocator, minimum_confidence);
}

pub fn libraryAcceptConfidentMatches(self: *OrcaRuntime, library: LibraryHandle, minimum_confidence: f32) !ConfidentMatchAcceptance {
    const library_database = try runtime.libraryDatabase(self, library);
    const acceptance = try library_database.identification_proposals.acceptConfident(self.allocator, minimum_confidence);
    defer acceptance.deinit();
    if (acceptance.values_written != 0) try reproject(self, library_database, acceptance.file_ids);
    if (acceptance.accepted != 0) recordingIdsChanged(self, library);
    return .{ .accepted = acceptance.accepted, .values_written = acceptance.values_written };
}

pub fn recordingIdsChanged(self: *OrcaRuntime, library: LibraryHandle) void {
    const object_value = self.libraries.get(library) catch return;
    object_value.stored_counts = null;
    const listens = object_value.listens orelse return;
    if (listens.loadConfig().enabled) _ = startListenWorker(self, library) catch {};
    listens.feedbackChanged(self.control_threaded.io());
}

pub fn libraryTrackFeedback(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !Feedback {
    return (try runtime.libraryDatabase(self, library)).feedback.forTrack(track_id);
}

pub fn libraryTrackPlayStats(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !PlayStats {
    return (try runtime.libraryDatabase(self, library)).listens.trackPlayStats(track_id);
}

fn ensureListens(self: *OrcaRuntime, object_value: *LibraryObject) !*listen_worker.Listens {
    if (object_value.listens) |existing| return existing;
    const created = try self.allocator.create(listen_worker.Listens);
    created.* = .{ .host_signal = &self.host_signal };
    created.configure(self.control_threaded.io(), withListenSettings(self, .{}));
    object_value.listens = created;
    return created;
}

/// Starts the Library's listen worker unless it is running.
pub fn startListenWorker(self: *OrcaRuntime, library: LibraryHandle) !*listen_worker.Listens {
    const object_value = try self.libraries.get(library);
    const library_database = object_value.database orelse return error.LibraryHasNoDatabase;
    const listens = try ensureListens(self, object_value);
    if (listens.worker != null) return listens;
    const io = try networkIo(self);
    const worker = try self.allocator.create(listen_worker.Worker);
    errdefer self.allocator.destroy(worker);
    const work_handle = try self.work_registry.begin(runtime.libraryOwnerTag(library));
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    errdefer {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
    }
    worker.* = .{
        .allocator = self.allocator,
        .io = io,
        .database = library_database,
        .listens = listens,
        .registration = registration,
        .hooks = self.listen_hooks,
    };
    registration.thread = try std.Thread.spawn(.{}, listen_worker.Worker.run, .{worker});
    listens.worker = worker;
    return listens;
}

pub fn networkIo(self: *OrcaRuntime) !std.Io {
    const threaded = self.network_threaded orelse created: {
        const created = try self.allocator.create(std.Io.Threaded);
        created.* = .init(self.allocator, .{});
        self.network_threaded = created;
        break :created created;
    };
    return threaded.io();
}

/// A full drain also joins the scrobbling Library's worker, and its queue
/// may be waiting on a retry time that no listen will come to restart it
/// for.
pub fn restartScrobblingListenWorker(self: *OrcaRuntime) void {
    const library = self.scrobbling_library orelse return;
    const object_value = self.libraries.get(library) catch return;
    const listens = object_value.listens orelse return;
    if (!listens.loadConfig().enabled) return;
    _ = startListenWorker(self, library) catch {};
}

/// Control lane, immediately after `work_registry.drain()`: each worker
/// recorded its ring before finishing, so it is released here and
/// restarts on its Library's next listen.
pub fn releaseDrainedListenWorkers(self: *OrcaRuntime) void {
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const listens = object_value.listens orelse continue;
        const worker = listens.worker orelse continue;
        self.allocator.destroy(worker);
        listens.worker = null;
    }
}

/// Between `requestCancellation` and `drain`, so a sleeping worker sees
/// the cancellation now rather than at the end of its poll.
pub fn wakeListenWorkers(self: *OrcaRuntime) void {
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const listens = object_value.listens orelse continue;
        listens.wake(self.control_threaded.io());
    }
}

pub fn freeListens(self: *OrcaRuntime, library: *LibraryObject) void {
    const listens = library.listens orelse return;
    std.debug.assert(listens.worker == null);
    self.allocator.destroy(listens);
    library.listens = null;
}

fn sampleTime(self: *OrcaRuntime) listen_worker.SampleTime {
    if (self.listen_hooks.sample_clock) |clock| return clock.now();
    const io = self.control_threaded.io();
    return .{
        .mono_ms = std.Io.Clock.awake.now(io).toMilliseconds(),
        .wall_s = std.Io.Clock.real.now(io).toSeconds(),
    };
}

/// One lock-free status read per bound Player, turned into listens and
/// handed to the Library's worker. No SQLite, I/O or allocation here,
/// except restarting a worker a drain released.
pub fn sampleListens(self: *OrcaRuntime) void {
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        if (object_value.opener != null) break;
    } else return;
    const now = sampleTime(self);
    if (self.last_listen_sample_ms) |last| {
        if (now.mono_ms - last < listen_sample_interval_ms) return;
    }
    self.last_listen_sample_ms = now.mono_ms;
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const opener = object_value.opener orelse continue;
        const read = runtime_status.readStatus(object_value);
        // A queue entry from a Library this Player was bound to before
        // names a Track id of that Library, not of this one.
        const track_id: ?i64 = if (read.audible) |ref|
            (if (ref.library.eql(opener.library)) ref.track_id else null)
        else
            null;
        const emission = object_value.listens.observe(.{
            .entry_serial = read.status.entry_serial,
            .track_id = track_id,
            .epoch = read.status.epoch,
            .playing = read.status.transport == .playing,
            .drained = object_value.player.drained.load(.acquire),
            .position_ms = read.status.position_ms,
            .duration_ms = read.status.duration_ms,
            .mono_ms = now.mono_ms,
            .wall_s = now.wall_s,
        });
        queueListen(self, opener.library, emission, now.mono_ms);
    }
}

/// Milliseconds until a listen sample is owed if no position hint pumps
/// first, or null while no bound Player is playing. A Player whose queue has played out still reports
/// playing, and counts until a sample has ended its listen.
pub fn listenSampleDueMs(self: *OrcaRuntime) ?u64 {
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        if (object_value.opener == null) continue;
        if (object_value.player.state.load(.acquire) != .playing) continue;
        if (object_value.player.drained.load(.acquire) and object_value.listens.open == null) continue;
        break;
    } else return null;
    const last = self.last_listen_sample_ms orelse return 0;
    const remaining = listen_fallback_interval_ms - (sampleTime(self).mono_ms - last);
    return @intCast(std.math.clamp(remaining, 0, listen_fallback_interval_ms));
}

/// Ends the listen a Player is in and hands its final time to `library`'s
/// worker, before the Player stops resolving through that Library.
pub fn endListen(self: *OrcaRuntime, object_value: *PlayerObject, library: LibraryHandle) void {
    const emission = object_value.listens.end();
    object_value.listens = .{};
    queueListen(self, library, emission, sampleTime(self).mono_ms);
}

/// `endListen` for every Player bound to `library`, or to any Library.
pub fn endListens(self: *OrcaRuntime, library: ?LibraryHandle) void {
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const opener = object_value.opener orelse continue;
        if (library) |only| {
            if (!opener.library.eql(only)) continue;
        }
        endListen(self, object_value, opener.library);
    }
}

fn announcesNowPlaying(self: *OrcaRuntime, library: LibraryHandle) bool {
    const object_value = self.libraries.get(library) catch return false;
    const listens = object_value.listens orelse return false;
    const config = listens.loadConfig();
    return config.enabled and config.now_playing;
}

fn queueListen(self: *OrcaRuntime, library: LibraryHandle, emission: providers.listens.Emission, mono_ms: i64) void {
    const entry: listen_worker.Entry = switch (emission) {
        .none => return,
        .started => |listen| .{ .kind = .now_playing, .listen = listen, .mono_ms = mono_ms },
        .eligible => |listen| .{ .kind = .eligible, .listen = listen },
        .finished => |listen| .{ .kind = .finished, .listen = listen },
    };
    if (entry.kind == .now_playing and !announcesNowPlaying(self, library)) return;
    _ = startListenWorker(self, library) catch {};
    const object_value = self.libraries.get(library) catch return;
    const listens = object_value.listens orelse return;
    listens.push(self.control_threaded.io(), entry);
}
