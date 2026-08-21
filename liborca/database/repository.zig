const std = @import("std");
const sqlite = @import("sqlite.zig");
const metadata = @import("../metadata/model.zig");

pub const WriteLane = struct {
    lock: std.atomic.Mutex = .unlocked,

    pub fn acquire(self: *WriteLane) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn release(self: *WriteLane) void {
        self.lock.unlock();
    }
};

pub const TrackInput = struct {
    title: []const u8,
    album: []const u8 = "",
    album_artist: []const u8 = "",
    duration_ms: ?i64 = null,
    track_number: ?i64 = null,
    disc_number: ?i64 = null,
};

pub const ObservedFileInput = struct {
    path: []const u8,
    inode: i64,
    size_bytes: i64,
    modified_ns: i64,
    audio_format: u8,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track_number: ?i64 = null,
};

pub const OrcaMetadataInput = struct {
    path: []const u8,
    field: metadata.Field,
    value: []const u8,
    provenance: metadata.Provenance,
    locked: bool = false,
};

pub const StoredMetadataValue = struct {
    text: []u8,
    provenance: metadata.Provenance,
    locked: bool,

    pub fn deinit(self: StoredMetadataValue, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const MutationKind = enum { write_tags, move };

pub const MutationState = enum {
    planned,
    staged,
    committed,
    rolled_back,
    failed,
    needs_reconciliation,
};

pub const MutationOperationInput = struct {
    plan_id: u64,
    group_id: u64,
    action_index: u32,
    kind: MutationKind,
    source_path: []const u8,
    destination_path: ?[]const u8 = null,
    stage_path: ?[]const u8 = null,
    backup_path: ?[]const u8 = null,
    expected_size: u64,
    expected_modified_ns: i64,
};

pub const MutationOperation = struct {
    allocator: std.mem.Allocator,
    id: i64,
    kind: MutationKind,
    source_path: []u8,
    destination_path: ?[]u8,
    stage_path: ?[]u8,
    backup_path: ?[]u8,
    expected_size: u64,
    expected_modified_ns: i64,
    committed_size: ?u64,
    committed_modified_ns: ?i64,
    state: MutationState,

    pub fn deinit(self: MutationOperation) void {
        self.allocator.free(self.source_path);
        if (self.destination_path) |value| self.allocator.free(value);
        if (self.stage_path) |value| self.allocator.free(value);
        if (self.backup_path) |value| self.allocator.free(value);
    }
};

pub const AnalysisCacheKey = struct {
    path: []const u8,
    kind: u8,
    algorithm_id: []const u8,
    algorithm_version: u32,
    parameter_hash: [32]u8,
    source_size: u64,
    source_modified_ns: i64,
};

pub const HealthIssueKind = enum(u8) {
    missing_metadata,
    missing_track_number,
    album_artist_anomaly,
    artwork_problem,
    missing_analysis,
    clipping,
    excessive_silence,
    technical_anomaly,
    corrupt_audio,
    exact_duplicate,
    likely_duplicate,
};

pub const HealthSeverity = enum(u8) { information, warning, error_severity };

pub const HealthIssueInput = struct {
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []const u8 = "",
};

pub const HealthIssue = struct {
    path: []u8,
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []u8,

    pub fn deinit(self: HealthIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.details);
    }
};

pub const HealthIssuePage = struct {
    allocator: std.mem.Allocator,
    items: []HealthIssue,

    pub fn deinit(self: HealthIssuePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ProviderCacheEntry = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,
    expires_at: i64,

    pub fn deinit(self: ProviderCacheEntry) void {
        self.allocator.free(self.body);
    }
};

pub const ScrobbleQueueEntry = struct {
    allocator: std.mem.Allocator,
    id: i64,
    service: []u8,
    event_key: []u8,
    payload: []u8,
    attempt_count: u32,

    pub fn deinit(self: ScrobbleQueueEntry) void {
        self.allocator.free(self.service);
        self.allocator.free(self.event_key);
        self.allocator.free(self.payload);
    }
};

pub const ProposalState = enum(u8) { pending, accepted, dismissed };

pub const IdentificationProposalInput = struct {
    path: []const u8,
    provider: []const u8,
    provider_id: []const u8,
    confidence: f32,
    payload: []const u8,
};

pub const IdentificationProposal = struct {
    allocator: std.mem.Allocator,
    id: i64,
    provider: []u8,
    provider_id: []u8,
    confidence: f32,
    payload: []u8,

    pub fn deinit(self: IdentificationProposal) void {
        self.allocator.free(self.provider);
        self.allocator.free(self.provider_id);
        self.allocator.free(self.payload);
    }
};

pub const TrackSummary = struct {
    id: i64,
    title: []u8,
    album: []u8,
    album_artist: []u8,

    pub fn deinit(self: TrackSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.album);
        allocator.free(self.album_artist);
    }
};

pub const TrackPage = struct {
    allocator: std.mem.Allocator,
    items: []TrackSummary,

    pub fn deinit(self: TrackPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const TrackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn insertBatch(self: *TrackRepository, tracks: []const TrackInput) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        var statement = try self.db.prepare(
            \\INSERT INTO tracks(
            \\    title, album, album_artist, duration_ms, track_number, disc_number
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        );
        defer statement.deinit();
        for (tracks) |track| {
            try statement.bindText(1, track.title);
            try statement.bindText(2, track.album);
            try statement.bindText(3, track.album_artist);
            try statement.bindOptionalInt64(4, track.duration_ms);
            try statement.bindOptionalInt64(5, track.track_number);
            try statement.bindOptionalInt64(6, track.disc_number);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn setRatings(self: *TrackRepository, ids: []const i64, rating: u8) !void {
        if (rating > 100) return error.InvalidRating;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare("UPDATE tracks SET rating=?1 WHERE id=?2;");
        defer statement.deinit();
        for (ids) |id| {
            try statement.bindInt64(1, rating);
            try statement.bindInt64(2, id);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn search(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: u32,
        offset: u32,
    ) !TrackPage {
        var statement = try self.db.prepare(
            \\SELECT tracks.id, tracks.title, tracks.album, tracks.album_artist
            \\FROM track_search
            \\JOIN tracks ON tracks.id = track_search.rowid
            \\WHERE track_search MATCH ?1
            \\ORDER BY rank
            \\LIMIT ?2 OFFSET ?3;
        );
        defer statement.deinit();
        try statement.bindText(1, query);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);
        return collectTrackPage(allocator, statement);
    }

    pub fn page(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !TrackPage {
        var statement = try self.db.prepare(
            \\SELECT id, title, album, album_artist FROM tracks
            \\ORDER BY id LIMIT ?1 OFFSET ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        return collectTrackPage(allocator, statement);
    }

    pub fn count(self: *const TrackRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn countWithRating(self: *const TrackRepository, rating: u8) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks WHERE rating=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, rating);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

fn collectTrackPage(allocator: std.mem.Allocator, statement: sqlite.Statement) !TrackPage {
    var results: std.ArrayList(TrackSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const title = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(title);
        const album = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(album);
        const album_artist = try allocator.dupe(u8, statement.columnText(3));
        errdefer allocator.free(album_artist);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .title = title,
            .album = album,
            .album_artist = album_artist,
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

pub const ObservedFileRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn isUnchanged(self: *const ObservedFileRepository, input: ObservedFileInput) !bool {
        var statement = try self.db.prepare(
            \\SELECT EXISTS(
            \\    SELECT 1 FROM observed_files
            \\    WHERE path=?1 AND inode=?2 AND size_bytes=?3 AND modified_ns=?4
            \\);
        );
        defer statement.deinit();
        try bindIdentity(statement, input);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0) != 0;
    }

    pub fn upsertBatch(self: *ObservedFileRepository, files: []const ObservedFileInput) !void {
        if (files.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO observed_files(
            \\    path, inode, size_bytes, modified_ns, audio_format, observed_at
            \\) VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(path) DO UPDATE SET
            \\    inode=excluded.inode,
            \\    size_bytes=excluded.size_bytes,
            \\    modified_ns=excluded.modified_ns,
            \\    audio_format=excluded.audio_format,
            \\    observed_at=excluded.observed_at;
        );
        defer statement.deinit();
        var metadata_statement = try self.db.prepare(
            \\INSERT INTO observed_file_metadata(path, title, artist, album, track_number)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
            \\ON CONFLICT(path) DO UPDATE SET
            \\    title=excluded.title,
            \\    artist=excluded.artist,
            \\    album=excluded.album,
            \\    track_number=excluded.track_number;
        );
        defer metadata_statement.deinit();
        for (files) |file| {
            try bindIdentity(statement, file);
            try statement.bindInt64(5, file.audio_format);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
            try metadata_statement.bindText(1, file.path);
            try metadata_statement.bindOptionalText(2, file.title);
            try metadata_statement.bindOptionalText(3, file.artist);
            try metadata_statement.bindOptionalText(4, file.album);
            try metadata_statement.bindOptionalInt64(5, file.track_number);
            if (try metadata_statement.step() != .done) return error.SqlFailed;
            try metadata_statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn count(self: *const ObservedFileRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM observed_files;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn title(
        self: *const ObservedFileRepository,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            "SELECT title FROM observed_file_metadata WHERE path=?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }

    fn bindIdentity(statement: sqlite.Statement, input: ObservedFileInput) !void {
        try statement.bindText(1, input.path);
        try statement.bindInt64(2, input.inode);
        try statement.bindInt64(3, input.size_bytes);
        try statement.bindInt64(4, input.modified_ns);
    }
};

pub const OrcaMetadataRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *OrcaMetadataRepository, input: OrcaMetadataInput) !void {
        if (input.path.len == 0 or input.value.len == 0 or input.provenance == .observed_file)
            return error.InvalidOrcaMetadata;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(path, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(path, field) DO UPDATE SET
            \\    value=excluded.value,
            \\    provenance=excluded.provenance,
            \\    locked=excluded.locked,
            \\    updated_at=excluded.updated_at
            \\WHERE orca_metadata_values.locked=0 OR excluded.provenance=?6;
        );
        defer statement.deinit();
        try statement.bindText(1, input.path);
        try statement.bindInt64(2, @backingInt(input.field));
        try statement.bindText(3, input.value);
        try statement.bindInt64(4, @backingInt(input.provenance));
        try statement.bindInt64(5, @intFromBool(input.locked));
        try statement.bindInt64(6, @backingInt(metadata.Provenance.user));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn get(
        self: *const OrcaMetadataRepository,
        allocator: std.mem.Allocator,
        path: []const u8,
        field: metadata.Field,
    ) !?StoredMetadataValue {
        var statement = try self.db.prepare(
            "SELECT value, provenance, locked FROM orca_metadata_values WHERE path=?1 AND field=?2;",
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        try statement.bindInt64(2, @backingInt(field));
        if (try statement.step() != .row) return null;
        const provenance = std.enums.fromInt(
            metadata.Provenance,
            statement.columnInt64(1),
        ) orelse return error.InvalidStoredProvenance;
        return .{
            .text = try allocator.dupe(u8, statement.columnText(0)),
            .provenance = provenance,
            .locked = statement.columnInt64(2) != 0,
        };
    }
};

pub const MutationJournalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn prepare(self: *MutationJournalRepository, input: MutationOperationInput) !i64 {
        if (input.plan_id == 0 or input.group_id == 0 or input.source_path.len == 0)
            return error.InvalidMutationOperation;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO mutation_operations(
            \\    plan_id, group_id, action_index, kind, source_path, destination_path,
            \\    stage_path, backup_path, expected_size, expected_modified_ns, state
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(input.plan_id));
        try statement.bindInt64(2, @intCast(input.group_id));
        try statement.bindInt64(3, input.action_index);
        try statement.bindInt64(4, @backingInt(input.kind));
        try statement.bindText(5, input.source_path);
        try statement.bindOptionalText(6, input.destination_path);
        try statement.bindOptionalText(7, input.stage_path);
        try statement.bindOptionalText(8, input.backup_path);
        try statement.bindInt64(9, @intCast(input.expected_size));
        try statement.bindInt64(10, input.expected_modified_ns);
        try statement.bindInt64(11, @backingInt(MutationState.planned));
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.lastInsertRowId();
    }

    pub fn transition(
        self: *MutationJournalRepository,
        operation_id: i64,
        expected: MutationState,
        next: MutationState,
        message: ?[]const u8,
    ) !void {
        if (!validMutationTransition(expected, next)) return error.InvalidMutationTransition;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, error=?2, updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @backingInt(next));
        try statement.bindOptionalText(2, message);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @backingInt(expected));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn state(self: *const MutationJournalRepository, operation_id: i64) !MutationState {
        var statement = try self.db.prepare(
            "SELECT state FROM mutation_operations WHERE id=?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        return std.enums.fromInt(MutationState, statement.columnInt64(0)) orelse
            error.InvalidStoredMutationState;
    }

    pub fn commit(
        self: *MutationJournalRepository,
        operation_id: i64,
        committed_size: u64,
        committed_modified_ns: i64,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, committed_size=?2, committed_modified_ns=?3, updated_at=unixepoch()
            \\WHERE id=?4 AND state=?5;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @backingInt(MutationState.committed));
        try statement.bindInt64(2, @intCast(committed_size));
        try statement.bindInt64(3, committed_modified_ns);
        try statement.bindInt64(4, operation_id);
        try statement.bindInt64(5, @backingInt(MutationState.staged));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn recordResultIdentity(
        self: *MutationJournalRepository,
        operation_id: i64,
        expected_state: MutationState,
        size: u64,
        modified_ns: i64,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET committed_size=?1, committed_modified_ns=?2, updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(size));
        try statement.bindInt64(2, modified_ns);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @backingInt(expected_state));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn get(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        operation_id: i64,
    ) !MutationOperation {
        var statement = try self.db.prepare(
            \\SELECT kind, source_path, destination_path, stage_path, backup_path,
            \\       expected_size, expected_modified_ns,
            \\       committed_size, committed_modified_ns, state
            \\FROM mutation_operations WHERE id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        const kind = std.enums.fromInt(MutationKind, statement.columnInt64(0)) orelse
            return error.InvalidStoredMutationKind;
        const source_path = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(source_path);
        const destination_path = try duplicateNullableColumn(allocator, statement, 2);
        errdefer if (destination_path) |value| allocator.free(value);
        const stage_path = try duplicateNullableColumn(allocator, statement, 3);
        errdefer if (stage_path) |value| allocator.free(value);
        const backup_path = try duplicateNullableColumn(allocator, statement, 4);
        errdefer if (backup_path) |value| allocator.free(value);
        const state_value = std.enums.fromInt(MutationState, statement.columnInt64(9)) orelse
            return error.InvalidStoredMutationState;
        return .{
            .allocator = allocator,
            .id = operation_id,
            .kind = kind,
            .source_path = source_path,
            .destination_path = destination_path,
            .stage_path = stage_path,
            .backup_path = backup_path,
            .expected_size = @intCast(statement.columnInt64(5)),
            .expected_modified_ns = statement.columnInt64(6),
            .committed_size = if (statement.columnIsNull(7)) null else @intCast(statement.columnInt64(7)),
            .committed_modified_ns = if (statement.columnIsNull(8)) null else statement.columnInt64(8),
            .state = state_value,
        };
    }

    pub fn groupOperationIds(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        group_id: u64,
    ) ![]i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM mutation_operations
            \\WHERE group_id=?1 ORDER BY action_index DESC;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(group_id));
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }
};

pub const AnalysisCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(
        self: *const AnalysisCacheRepository,
        allocator: std.mem.Allocator,
        key: AnalysisCacheKey,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            \\SELECT result FROM analysis_results
            \\WHERE path=?1 AND kind=?2 AND algorithm_id=?3
            \\  AND algorithm_version=?4 AND parameter_hash=?5
            \\  AND source_size=?6 AND source_modified_ns=?7;
        );
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnBlob(0));
    }

    pub fn put(self: *AnalysisCacheRepository, key: AnalysisCacheKey, result: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO analysis_results(
            \\    path, kind, algorithm_id, algorithm_version, parameter_hash,
            \\    source_size, source_modified_ns, result
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            \\ON CONFLICT DO UPDATE SET result=excluded.result, created_at=unixepoch();
        );
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        try statement.bindBlob(8, result);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

pub const HealthIssueRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Replaces all derived health state for one path in a single transaction.
    /// An empty issue list marks the path healthy.
    pub fn replacePath(
        self: *HealthIssueRepository,
        path: []const u8,
        issues: []const HealthIssueInput,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var delete = try self.db.prepare("DELETE FROM library_health_issues WHERE path=?1;");
        defer delete.deinit();
        try delete.bindText(1, path);
        if (try delete.step() != .done) return error.SqlFailed;
        var insert = try self.db.prepare(
            \\INSERT INTO library_health_issues(path, kind, severity, details, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, unixepoch());
        );
        defer insert.deinit();
        for (issues) |issue| {
            try insert.bindText(1, path);
            try insert.bindInt64(2, @backingInt(issue.kind));
            try insert.bindInt64(3, @backingInt(issue.severity));
            try insert.bindText(4, issue.details);
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn page(
        self: *const HealthIssueRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !HealthIssuePage {
        var statement = try self.db.prepare(
            \\SELECT path, kind, severity, details FROM library_health_issues
            \\ORDER BY severity DESC, kind, path LIMIT ?1 OFFSET ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var issues: std.ArrayList(HealthIssue) = .empty;
        errdefer {
            for (issues.items) |issue| issue.deinit(allocator);
            issues.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(0));
            errdefer allocator.free(path);
            const details = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(details);
            try issues.append(allocator, .{
                .path = path,
                .kind = std.enums.fromInt(HealthIssueKind, statement.columnInt64(1)) orelse
                    return error.InvalidStoredHealthIssue,
                .severity = std.enums.fromInt(HealthSeverity, statement.columnInt64(2)) orelse
                    return error.InvalidStoredHealthSeverity,
                .details = details,
            });
        }
        return .{ .allocator = allocator, .items = try issues.toOwnedSlice(allocator) };
    }

    pub fn count(self: *const HealthIssueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM library_health_issues;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

pub const ProviderCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(
        self: *const ProviderCacheRepository,
        allocator: std.mem.Allocator,
        provider: []const u8,
        request_key: []const u8,
        now: i64,
        allow_stale: bool,
    ) !?ProviderCacheEntry {
        var statement = try self.db.prepare(
            \\SELECT status, body, expires_at FROM provider_cache
            \\WHERE provider=?1 AND request_key=?2
            \\  AND (?3 OR expires_at>?4);
        );
        defer statement.deinit();
        try statement.bindText(1, provider);
        try statement.bindText(2, request_key);
        try statement.bindInt64(3, @intFromBool(allow_stale));
        try statement.bindInt64(4, now);
        if (try statement.step() != .row) return null;
        return .{
            .allocator = allocator,
            .status = std.math.cast(u16, statement.columnInt64(0)) orelse
                return error.InvalidStoredHttpStatus,
            .body = try allocator.dupe(u8, statement.columnBlob(1)),
            .expires_at = statement.columnInt64(2),
        };
    }

    pub fn put(
        self: *ProviderCacheRepository,
        provider: []const u8,
        request_key: []const u8,
        status: u16,
        body: []const u8,
        expires_at: i64,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO provider_cache(provider, request_key, status, body, expires_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(provider, request_key) DO UPDATE SET
            \\    status=excluded.status, body=excluded.body,
            \\    expires_at=excluded.expires_at, updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindText(1, provider);
        try statement.bindText(2, request_key);
        try statement.bindInt64(3, status);
        try statement.bindBlob(4, body);
        try statement.bindInt64(5, expires_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

pub const ScrobbleQueueRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn enqueue(
        self: *ScrobbleQueueRepository,
        service: []const u8,
        event_key: []const u8,
        payload: []const u8,
    ) !void {
        if (service.len == 0 or event_key.len == 0 or payload.len == 0)
            return error.InvalidScrobbleEvent;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO scrobble_queue(service, event_key, payload)
            \\VALUES (?1, ?2, ?3) ON CONFLICT(service, event_key) DO NOTHING;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindText(2, event_key);
        try statement.bindBlob(3, payload);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn ready(
        self: *const ScrobbleQueueRepository,
        allocator: std.mem.Allocator,
        service: []const u8,
        now: i64,
        limit: u32,
    ) ![]ScrobbleQueueEntry {
        var statement = try self.db.prepare(
            \\SELECT id, service, event_key, payload, attempt_count FROM scrobble_queue
            \\WHERE service=?1 AND state=0 AND next_attempt_at<=?2 ORDER BY id LIMIT ?3;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindInt64(2, now);
        try statement.bindInt64(3, limit);
        var entries: std.ArrayList(ScrobbleQueueEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit();
            entries.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const owned_service = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(owned_service);
            const event_key = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(event_key);
            const payload = try allocator.dupe(u8, statement.columnBlob(3));
            errdefer allocator.free(payload);
            try entries.append(allocator, .{
                .allocator = allocator,
                .id = statement.columnInt64(0),
                .service = owned_service,
                .event_key = event_key,
                .payload = payload,
                .attempt_count = @intCast(statement.columnInt64(4)),
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    pub fn markSucceeded(self: *ScrobbleQueueRepository, id: i64) !void {
        try self.setResult(id, 2, 0, "");
    }

    pub fn markRetry(
        self: *ScrobbleQueueRepository,
        id: i64,
        next_attempt_at: i64,
        details: []const u8,
    ) !void {
        try self.setResult(id, 0, next_attempt_at, details);
    }

    pub fn pendingCount(self: *const ScrobbleQueueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM scrobble_queue WHERE state=0;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    fn setResult(
        self: *ScrobbleQueueRepository,
        id: i64,
        state: u8,
        next_attempt_at: i64,
        details: []const u8,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scrobble_queue SET state=?1, attempt_count=attempt_count+1,
            \\    next_attempt_at=?2, last_error=?3, updated_at=unixepoch()
            \\WHERE id=?4 AND state=0;
        );
        defer statement.deinit();
        try statement.bindInt64(1, state);
        try statement.bindInt64(2, next_attempt_at);
        try statement.bindText(3, details);
        try statement.bindInt64(4, id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleScrobbleEvent;
    }
};

pub const IdentificationProposalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn put(self: *IdentificationProposalRepository, input: IdentificationProposalInput) !void {
        if (input.path.len == 0 or input.provider.len == 0 or input.provider_id.len == 0 or
            input.payload.len == 0 or !std.math.isFinite(input.confidence) or
            input.confidence < 0 or input.confidence > 1) return error.InvalidIdentificationProposal;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO identification_proposals(
            \\    path, provider, provider_id, confidence, payload, state, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 0, unixepoch())
            \\ON CONFLICT(path, provider, provider_id) DO UPDATE SET
            \\    confidence=excluded.confidence, payload=excluded.payload,
            \\    updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindText(1, input.path);
        try statement.bindText(2, input.provider);
        try statement.bindText(3, input.provider_id);
        try statement.bindDouble(4, input.confidence);
        try statement.bindBlob(5, input.payload);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn pending(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        path: []const u8,
        limit: u32,
    ) ![]IdentificationProposal {
        var statement = try self.db.prepare(
            \\SELECT id, provider, provider_id, confidence, payload
            \\FROM identification_proposals WHERE path=?1 AND state=0
            \\ORDER BY confidence DESC, id LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        try statement.bindInt64(2, limit);
        var proposals: std.ArrayList(IdentificationProposal) = .empty;
        errdefer {
            for (proposals.items) |proposal| proposal.deinit();
            proposals.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const provider = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(provider);
            const provider_id = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(provider_id);
            const payload = try allocator.dupe(u8, statement.columnBlob(4));
            errdefer allocator.free(payload);
            try proposals.append(allocator, .{
                .allocator = allocator,
                .id = statement.columnInt64(0),
                .provider = provider,
                .provider_id = provider_id,
                .confidence = @floatCast(statement.columnDouble(3)),
                .payload = payload,
            });
        }
        return proposals.toOwnedSlice(allocator);
    }

    /// Accepts a proposal into Orca metadata only. Locked values survive, and
    /// writing those values back to a media file remains a separate mutation.
    pub fn accept(
        self: *IdentificationProposalRepository,
        proposal_id: i64,
        path: []const u8,
        values: []const OrcaMetadataInput,
    ) !void {
        for (values) |value| {
            if (!std.mem.eql(u8, value.path, path) or value.provenance != .provider or
                value.value.len == 0) return error.InvalidProviderMetadata;
        }
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var update = try self.db.prepare(
            \\UPDATE identification_proposals SET state=1, updated_at=unixepoch()
            \\WHERE id=?1 AND path=?2 AND state=0;
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindText(2, path);
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleIdentificationProposal;
        var metadata_statement = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(path, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, 0, unixepoch())
            \\ON CONFLICT(path, field) DO UPDATE SET value=excluded.value,
            \\    provenance=excluded.provenance, updated_at=excluded.updated_at
            \\WHERE orca_metadata_values.locked=0;
        );
        defer metadata_statement.deinit();
        for (values) |value| {
            try metadata_statement.bindText(1, path);
            try metadata_statement.bindInt64(2, @backingInt(value.field));
            try metadata_statement.bindText(3, value.value);
            try metadata_statement.bindInt64(4, @backingInt(metadata.Provenance.provider));
            if (try metadata_statement.step() != .done) return error.SqlFailed;
            try metadata_statement.reset();
        }
        try self.db.exec("COMMIT;");
    }
};

fn bindAnalysisKey(statement: sqlite.Statement, key: *const AnalysisCacheKey) !void {
    try statement.bindText(1, key.path);
    try statement.bindInt64(2, key.kind);
    try statement.bindText(3, key.algorithm_id);
    try statement.bindInt64(4, key.algorithm_version);
    try statement.bindBlob(5, &key.parameter_hash);
    try statement.bindInt64(6, @intCast(key.source_size));
    try statement.bindInt64(7, key.source_modified_ns);
}

fn duplicateNullableColumn(
    allocator: std.mem.Allocator,
    statement: sqlite.Statement,
    column: c_int,
) !?[]u8 {
    if (statement.columnIsNull(column)) return null;
    return try allocator.dupe(u8, statement.columnText(column));
}

fn validMutationTransition(from: MutationState, to: MutationState) bool {
    if (to == .needs_reconciliation) return from != .rolled_back and
        from != .needs_reconciliation;
    return switch (from) {
        .planned => to == .staged or to == .failed,
        .staged => to == .committed or to == .rolled_back or to == .failed,
        .failed => to == .rolled_back,
        .committed => to == .rolled_back,
        .rolled_back, .needs_reconciliation => false,
    };
}
