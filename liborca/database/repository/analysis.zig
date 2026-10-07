const std = @import("std");
const sqlite = @import("../sqlite.zig");
const quick_hash = @import("../../storage/quick_hash.zig");
const content_hash = @import("../../storage/content_hash.zig");
const digestColumn = @import("../columns.zig").digestColumn;
const max_supported_channels = @import("../../codec/decoder.zig").max_supported_channels;
const max_supported_channels_sql = std.fmt.comptimePrint("{d}", .{max_supported_channels});

/// Whether the `files` row named `file` records a channel count that analysis
/// and playback accept, so results stored for it count as a measurement. A
/// NULL count is unknown and does not count.
pub fn measurableChannels(comptime file: []const u8) []const u8 {
    return file ++ ".channels <= " ++ max_supported_channels_sql;
}

const StorageIdentityKey = @import("locations.zig").StorageIdentityKey;
const WriteLane = @import("write_lane.zig").WriteLane;

/// Which measurement a library-wide analysis is asking about.
///
/// Everything except the file and its identity: the caller supplies the
/// algorithm it would run and the parameters it would run under, so a
/// selection asks "which files lack *this* measurement" rather than "which
/// files lack any measurement".
pub const AnalysisSelector = struct {
    kind: u8,
    algorithm_id: []const u8,
    algorithm_version: u32,
    parameter_hash: [32]u8,
};

/// The measurements a library-wide analysis takes together, and the verdict
/// that excuses a file from them. A file owes the analysis while any
/// measurement is missing, so bumping any algorithm's version re-selects
/// every file, unless the decoders it would run have already refused its
/// bytes.
pub const AnalysisSelectors = struct {
    measurements: [3]AnalysisSelector,
    undecodable: AnalysisSelector,
};

/// The `files` rows that still owe a library-wide analysis.
///
/// One string, shared by `FileRepository.unanalyzedPage`, `unanalyzedCount`
/// and the plan test that proves neither is a table scan. Parameters ?3 to ?6,
/// ?7 to ?10 and ?11 to ?14 are the three measurements and ?15 to ?18 the
/// undecodable verdict; ?1 and ?2 stay the caller's cursor and limit, as they are for
/// every other page in this file.
///
/// This is an anti-join against `analysis_results`' own primary key rather
/// than a flag on `files`, because that key *is* the answer. It already
/// encodes all three reasons a stored measurement stops counting — the bytes
/// changed (`source_identity`), the algorithm changed (`algorithm_version`),
/// the parameters changed (`parameter_hash`) — and a duplicate marker on
/// `files` would be a second source of truth that could disagree with the
/// results it claims to describe. `analysis_results` is `WITHOUT ROWID` with
/// exactly those six columns as its primary key, so each row of `files` costs
/// one full-prefix B-tree probe and no index has to be invented for this.
///
/// `source_identity` is the content hash of the bytes a measurement was taken
/// from, and it counts only while it equals the content hash the *Library*
/// recorded for the file. A file with no recorded content hash, or whose
/// bytes changed so that a scan forgot it, is therefore selected: its stored
/// measurement no longer describes it. A result filed under a quick hash,
/// as a Library before content-hash keying filed them, never equals a content
/// hash and is selected the same way.
///
/// A file recorded with more than two channels, or with no channel count,
/// that still holds any result is selected too, so the pass discards results
/// stored before such files were refused and records a count it did not know.
///
/// A file whose recorded bytes the decoders refused, or analysis refused for
/// their channel count, is not selected while the verdict is keyed as a
/// measurement is: on those bytes, that decoder set and
/// that verdict version. A file nothing can decode is otherwise read again on
/// every run, for an answer that cannot change.
///
/// The *playback* lookup is stricter, and deliberately asymmetric: it keys on
/// the identity of the bytes it just opened, because adopting a correction for
/// audio a file no longer contains is a wrong answer, while re-selecting a
/// file for measurement is only wasted work.
pub const unanalyzed_predicate =
    \\(NOT EXISTS (SELECT 1 FROM analysis_results
    \\    WHERE analysis_results.file_id = files.id
    \\      AND analysis_results.kind = ?3
    \\      AND analysis_results.algorithm_id = ?4
    \\      AND analysis_results.algorithm_version = ?5
    \\      AND analysis_results.parameter_hash = ?6
    \\      AND analysis_results.source_identity = files.content_hash
    \\      AND files.content_hash_algorithm = 1)
    \\OR NOT EXISTS (SELECT 1 FROM analysis_results
    \\    WHERE analysis_results.file_id = files.id
    \\      AND analysis_results.kind = ?7
    \\      AND analysis_results.algorithm_id = ?8
    \\      AND analysis_results.algorithm_version = ?9
    \\      AND analysis_results.parameter_hash = ?10
    \\      AND analysis_results.source_identity = files.content_hash
    \\      AND files.content_hash_algorithm = 1)
    \\OR NOT EXISTS (SELECT 1 FROM analysis_results
    \\    WHERE analysis_results.file_id = files.id
    \\      AND analysis_results.kind = ?11
    \\      AND analysis_results.algorithm_id = ?12
    \\      AND analysis_results.algorithm_version = ?13
    \\      AND analysis_results.parameter_hash = ?14
    \\      AND analysis_results.source_identity = files.content_hash
    \\      AND files.content_hash_algorithm = 1)
    \\OR ((files.channels IS NULL OR files.channels >
++ max_supported_channels_sql ++
    \\) AND EXISTS (SELECT 1 FROM analysis_results WHERE analysis_results.file_id = files.id)))
    \\AND NOT EXISTS (SELECT 1 FROM analysis_results
    \\    WHERE analysis_results.file_id = files.id
    \\      AND analysis_results.kind = ?15
    \\      AND analysis_results.algorithm_id = ?16
    \\      AND analysis_results.algorithm_version = ?17
    \\      AND analysis_results.parameter_hash = ?18
    \\      AND analysis_results.source_identity = files.content_hash
    \\      AND files.content_hash_algorithm = 1)
;

/// One file that still owes an analysis, where to read it, and what the
/// Library believes its bytes are.
pub const AnalysisCandidate = struct {
    id: i64,
    /// Empty when no location on any known volume names this file.
    uri: []u8,
    /// Null when the Library has never fingerprinted this file, which is a row
    /// no measurement can be keyed against until a scan gives it an identity.
    quick_hash: ?quick_hash.Digest,
    /// The content hash the Library recorded for the file, which the bytes
    /// read must equal. Null when it recorded none.
    content_hash: ?content_hash.Digest = null,
    /// The location `uri` names, and the storage identity it recorded.
    location_id: ?i64 = null,
    recorded: ?StorageIdentityKey = null,
};

pub const AnalysisCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []AnalysisCandidate,

    pub fn deinit(self: AnalysisCandidatePage) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

/// What a reader saw of the bytes at one location: the quick hash it read and
/// the storage identity they had.
pub const ObservedBytes = struct {
    quick_hash: quick_hash.Digest,
    native_inode: i64,
    size_bytes: i64,
    modified_ns: i64,
};

/// Analysis is cached against `files.id` and the content hash of the bytes it
/// was taken from. Anything coarser, a quick hash included, can call bytes
/// equal that are not.
pub const AnalysisCacheKey = struct {
    file_id: i64,
    kind: u8,
    algorithm_id: []const u8,
    algorithm_version: u32,
    parameter_hash: [32]u8,
    source_identity: content_hash.Digest,
};

pub const ReleaseMember = struct {
    track_id: i64,
    /// Null when the Track resolves to no file.
    file_id: ?i64,
    /// The file's recorded duration, or the Track's when the file has none.
    duration_ms: ?i64,
    /// The stored result, valid only for the visit. Empty when none is stored
    /// under the identity the Library recorded for the file.
    result: []const u8,
};

pub const ReleaseVisit = enum {
    visited,
    no_release,
    /// The Release has more than `max_release_members` Tracks. Some were
    /// visited before the visit stopped.
    too_large,
};

pub const AnalysisCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub const max_release_members = 512;

    /// The full key, every column of it. `source_identity` is not optional
    /// here and never should be: a stored measurement that is returned for
    /// bytes it was not taken from is a wrong answer presented as a right one,
    /// and both readers below exist to hand that answer to something that will
    /// act on it.
    const by_key =
        \\SELECT result FROM analysis_results
        \\WHERE file_id=?1 AND kind=?2 AND algorithm_id=?3
        \\  AND algorithm_version=?4 AND parameter_hash=?5
        \\  AND source_identity=?6;
    ;

    pub fn get(
        self: *const AnalysisCacheRepository,
        allocator: std.mem.Allocator,
        key: AnalysisCacheKey,
    ) !?[]u8 {
        var statement = try self.db.prepare(by_key);
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnBlob(0));
    }

    /// The result stored under `key`, copied into a caller-owned buffer, or
    /// null when there is none.
    ///
    /// The buffer is the caller's because the one caller that needs this is
    /// loading a queue entry on the control lane and wants a fixed-size header
    /// out of a blob whose bulk is a waveform it will never read. The returned
    /// length is the row's full length and may exceed `buffer.len`, which is
    /// how a caller learns it saw only a prefix. A caller that wants the whole
    /// result uses `get`.
    pub fn resultInto(
        self: *const AnalysisCacheRepository,
        key: AnalysisCacheKey,
        buffer: []u8,
    ) !?usize {
        var statement = try self.db.prepare(by_key);
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        if (try statement.step() != .row) return null;
        const stored = statement.columnBlob(0);
        const copied = @min(stored.len, buffer.len);
        @memcpy(buffer[0..copied], stored[0..copied]);
        return stored.len;
    }

    /// The content hash `file_id` records for the bytes at `uri`, when that
    /// location still records the identity `observed` saw there and the file
    /// still records the quick hash it read: then they are the bytes the
    /// content hash describes. Null otherwise, and the bytes are unknown.
    pub fn vouchedContentHash(
        self: *const AnalysisCacheRepository,
        file_id: i64,
        uri: []const u8,
        observed: ObservedBytes,
    ) !?content_hash.Digest {
        var statement = try self.db.prepare(
            \\SELECT files.content_hash FROM files JOIN locations ON locations.file_id = files.id
            \\WHERE files.id = ?1 AND files.content_hash_algorithm = 1 AND files.quick_hash = ?2
            \\  AND locations.uri = ?3 AND locations.native_inode = ?4 AND locations.size_bytes = ?5
            \\  AND locations.modified_ns = ?6
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindBlob(2, &observed.quick_hash);
        try statement.bindText(3, uri);
        try statement.bindInt64(4, observed.native_inode);
        try statement.bindInt64(5, observed.size_bytes);
        try statement.bindInt64(6, observed.modified_ns);
        if (try statement.step() != .row) return null;
        return digestColumn(statement, 0);
    }

    /// A member's result is keyed on `files.content_hash`, the identity the
    /// Library recorded, as `unanalyzed_predicate` keys it. A member recorded
    /// with more than two channels, or with no channel count, reads as
    /// unmeasured whatever is stored for it, because playback and analysis
    /// refuse more than two channels. One statement over
    /// `tracks_release` and the primary key of `analysis_results`, at most
    /// `max_release_members` rows, and nothing allocated.
    pub fn visitReleaseMembers(
        self: *const AnalysisCacheRepository,
        track_id: i64,
        selector: *const AnalysisSelector,
        context: anytype,
    ) !ReleaseVisit {
        var statement = try self.db.prepare(
            \\SELECT member.id, files.id, COALESCE(files.duration_ms, member.duration_ms),
            \\       analysis_results.result
            \\FROM tracks AS entry
            \\JOIN tracks AS member ON member.release_id = entry.release_id
            \\LEFT JOIN files ON files.id = COALESCE(
            \\    member.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = member.recording_id ORDER BY id LIMIT 1)
            \\)
            \\LEFT JOIN analysis_results ON analysis_results.file_id = files.id
            \\    AND analysis_results.kind = ?3
            \\    AND analysis_results.algorithm_id = ?4
            \\    AND analysis_results.algorithm_version = ?5
            \\    AND analysis_results.parameter_hash = ?6
            \\    AND analysis_results.source_identity = files.content_hash
            \\    AND files.content_hash_algorithm = 1
            \\    AND files.channels <=
        ++ max_supported_channels_sql ++
            \\
            \\WHERE entry.id = ?1 AND entry.release_id IS NOT NULL
            \\ORDER BY member.id
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, max_release_members + 1);
        try bindAnalysisSelector(statement, selector);
        var visited: usize = 0;
        while (try statement.step() == .row) : (visited += 1) {
            if (visited == max_release_members) return .too_large;
            try context.visit(.{
                .track_id = statement.columnInt64(0),
                .file_id = if (statement.columnIsNull(1)) null else statement.columnInt64(1),
                .duration_ms = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
                .result = if (statement.columnIsNull(3)) &.{} else statement.columnBlob(3),
            });
        }
        return if (visited == 0) .no_release else .visited;
    }

    pub fn deleteFileLocked(self: *AnalysisCacheRepository, file_id: i64) !void {
        var statement = try self.db.prepare("DELETE FROM analysis_results WHERE file_id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn put(self: *AnalysisCacheRepository, key: AnalysisCacheKey, result: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.putLocked(key, result);
    }

    /// Stores `result` under `key` as the file's only row of the selector the
    /// key names.
    pub fn replace(self: *AnalysisCacheRepository, key: AnalysisCacheKey, result: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const selector: AnalysisSelector = .{
            .kind = key.kind,
            .algorithm_id = key.algorithm_id,
            .algorithm_version = key.algorithm_version,
            .parameter_hash = key.parameter_hash,
        };
        try self.forgetLocked(key.file_id, &selector);
        try self.putLocked(key, result);
        try self.db.exec("COMMIT;");
    }

    /// Removes the file's rows of `selector`, whatever bytes they describe.
    pub fn forget(self: *AnalysisCacheRepository, file_id: i64, selector: *const AnalysisSelector) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.forgetLocked(file_id, selector);
    }

    fn forgetLocked(self: *AnalysisCacheRepository, file_id: i64, selector: *const AnalysisSelector) !void {
        var statement = try self.db.prepare(
            \\DELETE FROM analysis_results
            \\WHERE file_id = ?1 AND kind = ?2 AND algorithm_id = ?3
            \\  AND algorithm_version = ?4 AND parameter_hash = ?5;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try bindAnalysisSelectorAt(statement, 2, selector);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The same write from inside a caller's transaction. A library-wide
    /// analysis commits a whole batch of files at once — results, identity and
    /// health together — so it holds the lane itself rather than taking it once
    /// per row.
    pub fn putLocked(
        self: *AnalysisCacheRepository,
        key: AnalysisCacheKey,
        result: []const u8,
    ) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO analysis_results(
            \\    file_id, kind, algorithm_id, algorithm_version, parameter_hash,
            \\    source_identity, result
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            \\ON CONFLICT DO UPDATE SET result=excluded.result, created_at=unixepoch();
        );
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        try statement.bindBlob(7, result);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

/// Binds ?3 to ?6. The cursor and limit stay ?1 and ?2 so the selector can be
/// appended to any paged query without renumbering.
pub fn bindAnalysisSelector(statement: sqlite.Statement, selector: *const AnalysisSelector) !void {
    try bindAnalysisSelectorAt(statement, 3, selector);
}

/// Binds ?3 to ?18 of `unanalyzed_predicate`.
pub fn bindAnalysisSelectors(statement: sqlite.Statement, selectors: *const AnalysisSelectors) !void {
    try bindAnalysisSelectorAt(statement, 3, &selectors.measurements[0]);
    try bindAnalysisSelectorAt(statement, 7, &selectors.measurements[1]);
    try bindAnalysisSelectorAt(statement, 11, &selectors.measurements[2]);
    try bindAnalysisSelectorAt(statement, 15, &selectors.undecodable);
}

pub fn bindAnalysisSelectorAt(statement: sqlite.Statement, first: c_int, selector: *const AnalysisSelector) !void {
    try statement.bindInt64(first, selector.kind);
    try statement.bindText(first + 1, selector.algorithm_id);
    try statement.bindInt64(first + 2, selector.algorithm_version);
    try statement.bindBlob(first + 3, &selector.parameter_hash);
}

fn bindAnalysisKey(statement: sqlite.Statement, key: *const AnalysisCacheKey) !void {
    try statement.bindInt64(1, key.file_id);
    try statement.bindInt64(2, key.kind);
    try statement.bindText(3, key.algorithm_id);
    try statement.bindInt64(4, key.algorithm_version);
    try statement.bindBlob(5, &key.parameter_hash);
    try statement.bindBlob(6, &key.source_identity);
}
