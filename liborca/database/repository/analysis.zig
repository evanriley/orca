const std = @import("std");
const sqlite = @import("../sqlite.zig");
const quick_hash = @import("../../storage/quick_hash.zig");

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

/// The `files` rows that still owe a library-wide analysis.
///
/// One string, shared by `FileRepository.unanalyzedPage`, `unanalyzedCount`
/// and the plan test that proves neither is a table scan. Parameters ?3 to ?6
/// are the `AnalysisSelector`; ?1 and ?2 stay the caller's cursor and limit,
/// as they are for every other page in this file.
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
/// `source_identity = files.quick_hash` compares the measurement against the
/// identity the *Library* recorded, not against the bytes on disk. A file
/// whose bytes moved without a rescan therefore keeps being selected: that is
/// correct — its stored measurement no longer describes it — and the pass
/// declines to measure it until a scan has caught up, rather than filing a new
/// measurement the selection would go on missing for ever.
///
/// The *playback* lookup is stricter, and deliberately asymmetric: it keys on
/// the identity of the bytes it just opened, because adopting a correction for
/// audio a file no longer contains is a wrong answer, while re-selecting a
/// file for measurement is only wasted work.
pub const unanalyzed_predicate =
    \\NOT EXISTS (SELECT 1 FROM analysis_results
    \\    WHERE analysis_results.file_id = files.id
    \\      AND analysis_results.kind = ?3
    \\      AND analysis_results.algorithm_id = ?4
    \\      AND analysis_results.algorithm_version = ?5
    \\      AND analysis_results.parameter_hash = ?6
    \\      AND analysis_results.source_identity = files.quick_hash)
;

/// One file that still owes an analysis, where to read it, and what the
/// Library believes its bytes are.
pub const AnalysisCandidate = struct {
    id: i64,
    /// Empty when no location on any known volume names this file.
    uri: []u8,
    /// Null when the Library has never fingerprinted this file, which is a row
    /// no measurement can be keyed against until a scan gives it an identity.
    source_identity: ?quick_hash.Digest,
};

pub const AnalysisCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []AnalysisCandidate,

    pub fn deinit(self: AnalysisCandidatePage) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

/// Analysis is cached against `files.id` and the file's quick hash, not its
/// size and modification time: writing a tag changes both of those and must not
/// invalidate a loudness measurement of audio that did not change.
pub const AnalysisCacheKey = struct {
    file_id: i64,
    kind: u8,
    algorithm_id: []const u8,
    algorithm_version: u32,
    parameter_hash: [32]u8,
    source_identity: quick_hash.Digest,
};

pub const AnalysisCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

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

    pub fn put(self: *AnalysisCacheRepository, key: AnalysisCacheKey, result: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.putLocked(key, result);
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

/// Binds ?3 to ?6 of `unanalyzed_predicate`. The cursor and limit stay ?1 and
/// ?2 so the selector can be appended to any paged query without renumbering.
pub fn bindAnalysisSelector(statement: sqlite.Statement, selector: *const AnalysisSelector) !void {
    try statement.bindInt64(3, selector.kind);
    try statement.bindText(4, selector.algorithm_id);
    try statement.bindInt64(5, selector.algorithm_version);
    try statement.bindBlob(6, &selector.parameter_hash);
}

fn bindAnalysisKey(statement: sqlite.Statement, key: *const AnalysisCacheKey) !void {
    try statement.bindInt64(1, key.file_id);
    try statement.bindInt64(2, key.kind);
    try statement.bindText(3, key.algorithm_id);
    try statement.bindInt64(4, key.algorithm_version);
    try statement.bindBlob(5, &key.parameter_hash);
    try statement.bindBlob(6, &key.source_identity);
}
