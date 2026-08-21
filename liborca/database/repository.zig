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
